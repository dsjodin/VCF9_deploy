#Author: Daniel Sjödin
#If you need to redeploy WLD domain.

param (
    [string]$EnvConfigFile
)

# Validate that the file exists
if ($EnvConfigFile -and (Test-Path $EnvConfigFile)) {
    . $EnvConfigFile  # Dot-sourcing the config file
} else {
    Write-Host -ForegroundColor Red "`nNo valid deployment configuration file was provided or file was not found.`n"
    exit
}

$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------
# Load config
# -------------------------------------------------------------------
if (!(Test-Path $EnvConfigFile)) {
    Write-Host -ForegroundColor Red "`nConfig file not found: $EnvConfigFile`n"
    exit 1
}

. $EnvConfigFile   # dot-source the same config you posted

# -------------------------------------------------------------------
# Helper + logging
# -------------------------------------------------------------------
$random_string = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
$verboseLogFile = "wld-esxi-deployment-$random_string.log"

Function My-Logger {
    param(
        [Parameter(Mandatory = $true)][string]$message,
        [Parameter(Mandatory = $false)][string]$color = "Green"
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_HH:mm:ss"
    Write-Host -NoNewline -ForegroundColor White "[$timeStamp]"
    Write-Host -ForegroundColor $color " $message"
    "[$timeStamp] $message" | Out-File -Append -LiteralPath $verboseLogFile
}

Function Deploy-NestedESXiVMsParallel {
    param(
        [Parameter(Mandatory=$true)][hashtable]$HostnameToIPs,
        [Parameter(Mandatory=$true)][string]$DomainType,
        [Parameter(Mandatory=$true)][string]$OVAPath,
        [Parameter(Mandatory=$true)][hashtable]$NetworkConfig,
        [Parameter(Mandatory=$true)][hashtable]$ResourceConfig,
        [Parameter(Mandatory=$true)][hashtable]$vCenterConfig,
        [Parameter(Mandatory=$false)][int]$MaxConcurrent = 4
    )

    My-Logger "`n========================================" "cyan"
    My-Logger "  PARALLEL $DomainType ESXi DEPLOYMENT" "cyan"
    My-Logger "  Total hosts: $($HostnameToIPs.Count)" "cyan"
    My-Logger "  Max concurrent: $MaxConcurrent" "cyan"
    My-Logger "========================================`n" "cyan"

    $deploymentJobs = @()
    $deploymentResults = @{}
    $jobCounter = 0

    $HostnameToIPs.GetEnumerator() | Sort-Object -Property Value | ForEach-Object {
        $VMName = $_.Key
        $VMIPAddress = $_.Value
        $jobCounter++

        # Wait if we've hit max concurrent deployments
        while (($deploymentJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxConcurrent) {
            Start-Sleep -Seconds 3
            
            # Process completed jobs
            $deploymentJobs | Where-Object { $_.State -eq 'Completed' } | ForEach-Object {
                $result = Receive-Job -Job $_
                $deploymentResults[$result.VMName] = $result.Success
                
                if ($result.Success) {
                    My-Logger "  ✓ [$($result.VMName)] Deployment completed in $($result.Duration) min" "green"
                } else {
                    My-Logger "  ✗ [$($result.VMName)] Deployment FAILED: $($result.Error)" "red"
                }
                Remove-Job -Job $_
            }
            
            # Remove failed jobs
            $deploymentJobs | Where-Object { $_.State -eq 'Failed' } | ForEach-Object {
                My-Logger "  ✗ Job failed for $($_.Name)" "red"
                Remove-Job -Job $_
            }
        }

        My-Logger "[$jobCounter/$($HostnameToIPs.Count)] Starting deployment: $VMName ($VMIPAddress)" "cyan"

        # Start deployment job
        $job = Start-Job -Name "Deploy-$VMName" -ScriptBlock {
            param($config)
            
            $result = @{
                VMName = $config.VMName
                Success = $false
                Error = $null
                StartTime = Get-Date
            }

            try {
                # Import VMware module (required in job context)
                Import-Module VMware.VimAutomation.Core -ErrorAction Stop

                # Connect to vCenter (each job needs its own connection)
                $viConn = Connect-VIServer -Server $config.VIServer `
                    -User $config.VIUsername `
                    -Password $config.VIPassword `
                    -WarningAction SilentlyContinue `
                    -ErrorAction Stop

                $datastore = Get-Datastore -Server $viConn -Name $config.VMDatastore | Select-Object -First 1
                $cluster = Get-Cluster -Server $viConn -Name $config.VMCluster
                $vmhost = $cluster | Get-VMHost | Get-Random -Count 1

                # Check if VM already exists
                $existingVM = Get-VM -Server $viConn -Name $config.VMName -ErrorAction SilentlyContinue
                if ($existingVM) {
                    throw "VM $($config.VMName) already exists"
                }

                # Configure OVF
                $ovfconfig = Get-OvfConfiguration $config.OVAPath
                $networkMapLabel = ($ovfconfig.ToHashTable().keys | 
                    Where-Object { $_ -match "NetworkMapping" }).replace("NetworkMapping.","").replace("-","_").replace(" ","_")

                $ovfconfig.NetworkMapping.$networkMapLabel.value = $config.VMNetwork
                $ovfconfig.common.guestinfo.hostname.value = "$($config.VMName).$($config.VMDomain)"
                $ovfconfig.common.guestinfo.ipaddress.value = $config.VMIPAddress
                $ovfconfig.common.guestinfo.netmask.value = $config.VMNetmask
                $ovfconfig.common.guestinfo.gateway.value = $config.Gateway
                $ovfconfig.common.guestinfo.vlan.value = $config.VLAN
                $ovfconfig.common.guestinfo.dns.value = $config.VMDNS
                $ovfconfig.common.guestinfo.domain.value = $config.VMDomain
                $ovfconfig.common.guestinfo.ntp.value = $config.VMNTP
                $ovfconfig.common.guestinfo.syslog.value = $config.VMSyslog
                $ovfconfig.common.guestinfo.password.value = $config.VMPassword
                $ovfconfig.common.guestinfo.ssh.value = $true

                # Deploy VM
                $null = Import-VApp -Server $viConn `
                    -Source $config.OVAPath `
                    -OvfConfiguration $ovfconfig `
                    -Name $config.VMName `
                    -Location $cluster `
                    -VMHost $vmhost `
                    -Datastore $datastore `
                    -DiskStorageFormat Thin `
                    -ErrorAction Stop

                $vm = Get-VM -Server $viConn -Name $config.VMName

                # Update compute resources
                $null = Set-VM -Server $viConn -VM $vm `
                    -NumCpu $config.vCPU `
                    -CoresPerSocket $config.vCPU `
                    -MemoryGB $config.vMEM `
                    -Confirm:$false `
                    -ErrorAction Stop

                # Storage configuration
                # Resize boot disk
                $null = Get-HardDisk -Server $viConn -VM $vm -Name "Hard disk 1" | 
                    Set-HardDisk -CapacityGB $config.BootDisk -Confirm:$false -ErrorAction Stop

                # Remove cache disk (Hard disk 2) for vSAN ESA
                $null = Get-HardDisk -Server $viConn -VM $vm -Name "Hard disk 2" | 
                    Remove-HardDisk -Confirm:$false -ErrorAction Stop

                # Resize capacity disk (now becomes Hard disk 2 after removal)
                $null = Get-HardDisk -Server $viConn -VM $vm -Name "Hard disk 2" | 
                    Set-HardDisk -CapacityGB $config.CapacityDisk -Confirm:$false -ErrorAction Stop

                # Add additional network adapters (vmnic2/vmnic3)
                $vmPortGroup = Get-VirtualNetwork -Name $config.VMNetwork -Location ($cluster | Get-Datacenter)
                
                if ($vmPortGroup.NetworkType -eq "Distributed") {
                    $vmPortGroup = Get-VDPortgroup -Name $config.VMNetwork
                    $null = New-NetworkAdapter -VM $vm -Type Vmxnet3 -Portgroup $vmPortGroup -StartConnected -Confirm:$false -ErrorAction Stop
                    $null = New-NetworkAdapter -VM $vm -Type Vmxnet3 -Portgroup $vmPortGroup -StartConnected -Confirm:$false -ErrorAction Stop
                } else {
                    $null = New-NetworkAdapter -VM $vm -Type Vmxnet3 -NetworkName $vmPortGroup -StartConnected -Confirm:$false -ErrorAction Stop
                    $null = New-NetworkAdapter -VM $vm -Type Vmxnet3 -NetworkName $vmPortGroup -StartConnected -Confirm:$false -ErrorAction Stop
                }

                # Configure dvfilter MAC learning for vmnic2/vmnic3
                $null = $vm | New-AdvancedSetting -Name "ethernet2.filter4.name" -Value "dvfilter-maclearn" -Confirm:$false -ErrorAction SilentlyContinue
                $null = $vm | New-AdvancedSetting -Name "ethernet2.filter4.onFailure" -Value "failOpen" -Confirm:$false -ErrorAction SilentlyContinue
                $null = $vm | New-AdvancedSetting -Name "ethernet3.filter4.name" -Value "dvfilter-maclearn" -Confirm:$false -ErrorAction SilentlyContinue
                $null = $vm | New-AdvancedSetting -Name "ethernet3.filter4.onFailure" -Value "failOpen" -Confirm:$false -ErrorAction SilentlyContinue

                # Power on VM
                $null = $vm | Start-VM -RunAsync -ErrorAction Stop

                $result.Success = $true
                $result.EndTime = Get-Date
                $result.Duration = [math]::Round((New-TimeSpan -Start $result.StartTime -End $result.EndTime).TotalMinutes, 2)

            } catch {
                $result.Error = $_.Exception.Message
            } finally {
                # Always disconnect
                if ($viConn) {
                    Disconnect-VIServer -Server $viConn -Confirm:$false -ErrorAction SilentlyContinue
                }
            }

            return $result

        } -ArgumentList @{
            # vCenter connection details
            VIServer = $vCenterConfig.Server
            VIUsername = $vCenterConfig.Username
            VIPassword = $vCenterConfig.Password
            VMDatastore = $vCenterConfig.Datastore
            VMCluster = $vCenterConfig.Cluster
            VMNetwork = $vCenterConfig.Network
            
            # VM specific
            VMName = $VMName
            VMIPAddress = $VMIPAddress
            OVAPath = $OVAPath
            
            # Network configuration
            VMNetmask = $NetworkConfig.Netmask
            Gateway = $NetworkConfig.Gateway
            VLAN = $NetworkConfig.VLAN
            VMDNS = $NetworkConfig.DNS
            VMDomain = $NetworkConfig.Domain
            VMNTP = $NetworkConfig.NTP
            VMSyslog = $NetworkConfig.Syslog
            VMPassword = $NetworkConfig.Password
            
            # Resource configuration
            vCPU = $ResourceConfig.vCPU
            vMEM = $ResourceConfig.vMEM
            BootDisk = $ResourceConfig.BootDisk
            CapacityDisk = $ResourceConfig.CapacityDisk
        }

        $deploymentJobs += $job
    }

    # Wait for all remaining jobs to complete
    My-Logger "`nWaiting for remaining deployments to complete..." "yellow"
    $remainingJobs = $deploymentJobs | Where-Object { $_.State -eq 'Running' }
    
    if ($remainingJobs) {
        My-Logger "  $($remainingJobs.Count) deployment(s) still in progress..." "yellow"
        
        $remainingJobs | Wait-Job -Timeout 1800 | ForEach-Object {  # 30 min timeout per job
            $result = Receive-Job -Job $_
            $deploymentResults[$result.VMName] = $result.Success
            
            if ($result.Success) {
                My-Logger "  ✓ [$($result.VMName)] Completed in $($result.Duration) min" "green"
            } else {
                My-Logger "  ✗ [$($result.VMName)] FAILED: $($result.Error)" "red"
            }
            Remove-Job -Job $_
        }
    }

    # Clean up any failed/stopped jobs
    $deploymentJobs | Where-Object { $_.State -ne 'Completed' } | ForEach-Object {
        My-Logger "Cleaning up job: $($_.Name) (State: $($_.State))" "yellow"
        Remove-Job -Job $_ -Force
    }

    # Summary
    $successCount = ($deploymentResults.Values | Where-Object { $_ -eq $true }).Count
    $failCount = $deploymentResults.Count - $successCount

    My-Logger "`n========================================" "cyan"
    My-Logger "  $DomainType ESXi DEPLOYMENT SUMMARY" "cyan"
    My-Logger "  Total: $($deploymentResults.Count) | Success: $successCount | Failed: $failCount" $(if($failCount -eq 0){"green"}else{"yellow"})
    My-Logger "========================================`n" "cyan"

    if ($failCount -gt 0) {
        My-Logger "Failed deployments:" "red"
        $deploymentResults.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object {
            My-Logger "  - $($_.Key)" "red"
        }
    }

    return $deploymentResults
}

# -------------------------------------------------------------------
# Pre-checks
# -------------------------------------------------------------------
if ($PSVersionTable.PSEdition -ne "Core") {
    Write-Host -ForegroundColor Yellow "Warning: Script is tested with PowerShell Core. You're running: $($PSVersionTable.PSEdition)"
}

if (!(Test-Path $NestedESXiApplianceOVA)) {
    Write-Host -ForegroundColor Red "`nUnable to find Nested ESXi OVA: $NestedESXiApplianceOVA`n"
    exit 1
}

if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
    Write-Host -ForegroundColor Red "VMware PowerCLI module not found. Install it first:"
    Write-Host -ForegroundColor Cyan "  Install-Module VMware.PowerCLI"
    exit 1
}

# -------------------------------------------------------------------
# Summary + confirmation
# -------------------------------------------------------------------
Write-Host -ForegroundColor Yellow "`n---- WLD Nested ESXi Deployment (VCF 9 Lab) ----"
Write-Host -NoNewline -ForegroundColor Green "Config file: "
Write-Host -ForegroundColor White $EnvConfigFile

Write-Host -ForegroundColor Yellow "`n---- vCenter Target ----"
Write-Host -NoNewline -ForegroundColor Green "vCenter: "
Write-Host -ForegroundColor White $VIServer
Write-Host -NoNewline -ForegroundColor Green "Cluster: "
Write-Host -ForegroundColor White $VMCluster
Write-Host -NoNewline -ForegroundColor Green "Datastore: "
Write-Host -ForegroundColor White $VMDatastore
Write-Host -NoNewline -ForegroundColor Green "Network (Portgroup): "
Write-Host -ForegroundColor White $VMNetwork

Write-Host -ForegroundColor Yellow "`n---- WLD vESXi Config ----"
Write-Host -NoNewline -ForegroundColor Green "# of WLD Nested ESXi VMs: "
Write-Host -ForegroundColor White $NestedESXiHostnameToIPsForWorkloadDomain.Count
Write-Host -NoNewline -ForegroundColor Green "IP Address(es): "
Write-Host -ForegroundColor White ($NestedESXiHostnameToIPsForWorkloadDomain.Values -join ", ")
Write-Host -NoNewline -ForegroundColor Green "vCPU: "
Write-Host -ForegroundColor White $NestedESXiWLDvCPU
Write-Host -NoNewline -ForegroundColor Green "vMEM: "
Write-Host -ForegroundColor White "$NestedESXiWLDvMEM GB"
Write-Host -NoNewline -ForegroundColor Green "Boot Disk: "
Write-Host -ForegroundColor White "$NestedESXiWLDBootDisk GB"
Write-Host -NoNewline -ForegroundColor Green "vSAN Capacity Disk: "
Write-Host -ForegroundColor White "$NestedESXiWLDCapacityvDisk GB"

Write-Host -ForegroundColor Magenta "`nThis script will ONLY deploy the WLD Nested ESXi VMs."
Write-Host -ForegroundColor Magenta "Management domain, SDDC Manager and Installer are NOT touched.`n"

$answer = Read-Host -Prompt "Proceed with WLD ESXi deployment? (Y/N)"
if ($answer -notin @("Y","y")) {
    Write-Host "Aborted."
    exit 0
}

# -------------------------------------------------------------------
# Connect to vCenter
# -------------------------------------------------------------------
My-Logger "Connecting to vCenter Server $VIServer ..."
try {
    $viConnection = Connect-VIServer -Server $VIServer -User $VIUsername -Password $VIPassword -WarningAction SilentlyContinue
} catch {
    Write-Host -ForegroundColor Red "Failed to connect to vCenter: $($_.Exception.Message)"
    exit 1
}

# -------------------------------------------------------------------
# Deploy WLD Nested ESXi VMs in Parallel
# -------------------------------------------------------------------
$StartTime = Get-Date

$wldResults = Deploy-NestedESXiVMsParallel `
    -HostnameToIPs $NestedESXiHostnameToIPsForWorkloadDomain `
    -DomainType "WLD" `
    -OVAPath $NestedESXiApplianceOVA `
    -NetworkConfig @{
        Netmask = $VMNetmask
        Gateway = $ESXWLDGateway
        VLAN = $ESXWLDVLAN
        DNS = $VMDNS
        Domain = $VMDomain
        NTP = $VMNTP
        Syslog = $VMSyslog
        Password = $VMPassword
    } `
    -ResourceConfig @{
        vCPU = $NestedESXiWLDvCPU
        vMEM = $NestedESXiWLDvMEM
        BootDisk = $NestedESXiWLDBootDisk
        CapacityDisk = $NestedESXiWLDCapacityvDisk
    } `
    -vCenterConfig @{
        Server = $VIServer
        Username = $VIUsername
        Password = $VIPassword
        Datastore = $VMDatastore
        Cluster = $VMCluster
        Network = $VMNetwork
    } `
    -MaxConcurrent 6  # Can be more aggressive since this is WLD-only

$wldFailures = ($wldResults.Values | Where-Object { -not $_ }).Count

# -------------------------------------------------------------------
# Disconnect + summary
# -------------------------------------------------------------------
My-Logger "Disconnecting from vCenter Server $VIServer ..."
Disconnect-VIServer -Server $viConnection -Confirm:$false | Out-Null

$EndTime  = Get-Date
$Duration = [Math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes, 2)

My-Logger "`n╔════════════════════════════════════════════════════════════════╗" "cyan"
My-Logger "║         WLD NESTED ESXi DEPLOYMENT COMPLETE                   ║" "cyan"
My-Logger "╠════════════════════════════════════════════════════════════════╣" "cyan"
My-Logger "║  StartTime: $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" "cyan"
My-Logger "║  EndTime:   $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))" "cyan"
My-Logger "║  Duration:  $Duration minutes" "cyan"
My-Logger "║  Success:   $($wldResults.Count - $wldFailures)/$($wldResults.Count) hosts" "cyan"
if ($wldFailures -gt 0) {
    My-Logger "║  Failed:    $wldFailures hosts (see log for details)" "yellow"
}
My-Logger "║  Log File:  $verboseLogFile" "cyan"
My-Logger "╚════════════════════════════════════════════════════════════════╝" "cyan"

if ($wldFailures -gt 0) {
    exit 1
} else {
    exit 0
}
