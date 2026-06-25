# Author: William Lam
# Website: https://williamlam.com
# Enhanced with: Improved Bundle Management for SDDC Manager
#
# MIGRATED TO VCF PowerCLI 9 (VMware.Sdk.Vcf.SddcManager)
# Original version using PowerVCF backed up to: vcf-automated-wld-deployment.ps1.powervcf.backup
# See MIGRATION_GUIDE.md for details on cmdlet mappings
#
# 9.1 updates applied:
#   - depot connect/sync removed (API_NO_LONGER_SUPPORTED in 9.1; depot inherited from fleet)
#   - bundle-id handling fixed (versions.artifacts.bundles.id can be an array)
#   - token timeout raised from 5s to 30s

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

#### DO NOT EDIT BEYOND HERE ####

$confirmDeployment = 1
$updateSDDCMConfig = 0
$applyEsaHclWorkaround = 1     # 9.1 nested: bypass vSAN ESA NVMe-HCL check at host commission
$configureSDDCMConfig = 1
$generateWldHostCommissionJson = 1
$commissionHost = 1
$generateWLDDeploymentFile = 1
$startWLDDeployment = 1

$VCFManagementDomainVLCMImageName = "Management-Domain-ESXi-Personality"
$VCFWorkloadDomainUIJSONFile = "vcf-commission-host-ui.json"
$VCFWorkloadDomainAPIJSONFile = "vcf-commission-host-api.json"
$VCFWorkloadJSONFile = "vcf-$VCFWorkloadDomainName-deployment.json"
$verboseLogFile = "vcf-workload-domain-deployment.log"

$sddcManagerFQDN = "${SddcManagerHostname}.${VMDomain}"

$StartTime = Get-Date

Function My-Logger {
    param(
    [Parameter(Mandatory=$true)][AllowEmptyString()][String]$message,
    [Parameter(Mandatory=$false)][String]$color="green"
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_hh:mm:ss"

    Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
    Write-Host -ForegroundColor $color " $message"
    $logMessage = "[$timeStamp] $message"
    $logMessage | Out-File -Append -LiteralPath $verboseLogFile
}

Function Get-VCFSDDCmToken {
    $payload = @{
        "username" = "administrator@vsphere.local"
        "password" = $VCSASSOPassword
    }

    $body = $payload | ConvertTo-Json

    try {
        $requests = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/tokens" -Method POST -SkipCertificateCheck -TimeoutSec 30 -Headers @{"Content-Type"="application/json";"Accept"="application/json"} -Body $body
        if($requests.StatusCode -eq 200) {
            $accessToken = ($requests.Content | ConvertFrom-Json).accessToken
        }
    } catch {
        My-Logger "Unable to retrieve SDDC Manager Token ..." "red"
        exit
    }

    $headers = @{
        "Content-Type"="application/json"
        "Accept"="application/json"
        "Authorization"="Bearer ${accessToken}"
    }

    return $headers
}

Function Get-VCFBundleStatus {
    param(
        [Parameter(Mandatory=$true)][String]$BundleId,
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    $headers = Get-VCFSDDCmToken

    try {
        $uri = "https://${EndpointIp}/v1/bundles/$BundleId"
        $response = Invoke-WebRequest -Uri $uri -Method GET -SkipCertificateCheck -Headers $headers -ErrorAction Stop
        $bundle = ($response.Content | ConvertFrom-Json)

        return @{
            "exists" = $true
            "downloadStatus" = $bundle.downloadStatus
            "componentType" = $bundle.componentType
        }
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            return @{ "exists" = $false }
        }
        throw
    }
}

Function Download-VCFBundle {
    param(
        [Parameter(Mandatory=$true)][String]$BundleId,
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    # Check if bundle already exists and is downloaded
    try {
        $bundleStatus = Get-VCFBundleStatus -BundleId $BundleId -EndpointIp $EndpointIp

        if ($bundleStatus.exists) {
            $status = $bundleStatus.downloadStatus
            if ($status -eq "DOWNLOADED" -or $status -eq "SUCCESSFUL") {
                My-Logger "  Bundle $($bundleStatus.componentType) already downloaded, skipping..." "green"
                return $true
            } elseif ($status -in @("INPROGRESS", "SCHEDULED", "VALIDATING")) {
                My-Logger "  Bundle $($bundleStatus.componentType) download already in progress ($status)..." "cyan"
                return $true
            }
        }
    } catch {
        My-Logger "  Could not check bundle status (will attempt download): $($_.Exception.Message)" "yellow"
    }

    # Proceed with download
    $headers = Get-VCFSDDCmToken

    try {
        $payload = @{
            "bundleDownloadSpec" = @{
                "downloadNow" = $true
            }
        }

        $uri = "https://${EndpointIp}/v1/bundles/$BundleId"
        $method = "PATCH"
        $body = $payload | ConvertTo-Json

        if($Debug) {
            My-Logger "DEBUG: Starting download for bundle $BundleId" "cyan"
        }

        $response = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck `
            -Headers $headers -Body $body -ErrorAction Stop

        if ($bundleStatus.exists) {
            My-Logger "  Bundle download initiated: $($bundleStatus.componentType)" "cyan"
        } else {
            My-Logger "  Bundle download initiated: $BundleId" "cyan"
        }
        return $true

    } catch {
        $errorMsg = $_.Exception.Message

        # Parse error response if available
        if ($_.ErrorDetails.Message) {
            try {
                $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errorJson.errorCode -eq "BUNDLE_DOWNLOAD_ALREADY_DOWNLOADED") {
                    My-Logger "  Bundle $BundleId already downloaded" "green"
                    return $true
                } elseif ($errorJson.errorCode -match "BUNDLE_DOWNLOAD") {
                    My-Logger "  Bundle download status: $($errorJson.message)" "yellow"
                    return $true
                }
            } catch {
                # Not JSON, continue with original error
            }
        }

        My-Logger "  Failed to download bundle ${BundleId}: $errorMsg" "red"
        return $false
    }
}

Function Delete-VCFBundle {
    param(
        [Parameter(Mandatory=$true)][String]$BundleId,
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    $headers = Get-VCFSDDCmToken

    try {
        $uri = "https://${EndpointIp}/v1/bundles/$BundleId"
        $method = "DELETE"

        if($Debug) {
            My-Logger "DEBUG: Deleting bundle $BundleId" "cyan"
        }

        $requests = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -TimeoutSec 30 -Headers $headers
        My-Logger "  Deleted bundle $BundleId for retry" "yellow"
    } catch {
        My-Logger "  Warning: Could not delete bundle ${bundleId}: $($_.Exception.Message)" "yellow"
    }
}

Function Wait-VCFBundleDownloads {
    param(
        [Parameter(Mandatory=$true)][String]$EndpointIp,
        [Parameter(Mandatory=$true)][String]$ProductSKU,
        [Parameter(Mandatory=$true)][String]$ProductVersion,
        [Parameter(Mandatory=$true)][Int]$TotalBundles
    )

    $headers = Get-VCFSDDCmToken
    $maxRetries = 3
    $retryCount = @{}

    My-Logger "`nMonitoring bundle download progress (Total bundles: $TotalBundles)..." "cyan"

    while($true) {
        try {
            $uri = "https://${EndpointIp}/v1/bundles/download-status?releaseVersion=${ProductVersion}&imageType=INSTALL"
            $response = Invoke-WebRequest -Uri $uri -Method GET -SkipCertificateCheck -Headers $headers
            $bundles = ($response.Content | ConvertFrom-Json).elements

            $inProgress = $bundles | Where-Object { $_.downloadStatus -in @("INPROGRESS", "SCHEDULED", "VALIDATING") }
            $failed = $bundles | Where-Object { $_.downloadStatus -eq "FAILED" }

            # Calculate completed: completed bundles don't appear in download-status, so:
            # completed = total - (still in progress) - (failed)
            $completedCount = $TotalBundles - $inProgress.Count - $failed.Count

            # Show summary
            My-Logger "  Bundle Status: $completedCount completed | $($inProgress.Count) in progress | $($failed.Count) failed" "cyan"

            # Show details for in-progress bundles
            if ($inProgress.Count -gt 0) {
                foreach ($bundle in $inProgress) {
                    # Try multiple possible property names for percentage
                    $percentage = $null
                    if ($bundle.PSObject.Properties['downloadPercentage']) {
                        $percentage = $bundle.downloadPercentage
                    } elseif ($bundle.PSObject.Properties['completionPercentage']) {
                        $percentage = $bundle.completionPercentage
                    } elseif ($bundle.PSObject.Properties['progress']) {
                        $percentage = $bundle.progress
                    } elseif ($bundle.PSObject.Properties['percentage']) {
                        $percentage = $bundle.percentage
                    }

                    # Debug: Show what properties are available (only if Debug is on)
                    if ($Debug -and $percentage -eq $null) {
                        $props = ($bundle.PSObject.Properties.Name | Where-Object { $_ -notlike '*Spec*' }) -join ', '
                        My-Logger "    DEBUG: Available properties for $($bundle.componentType): $props" "cyan"
                    }

                    # Format output based on whether we have percentage
                    if ($percentage -ne $null -and $percentage -gt 0) {
                        My-Logger "    -> $($bundle.componentType): $($bundle.downloadStatus) ($percentage%)" "yellow"
                    } else {
                        My-Logger "    -> $($bundle.componentType): $($bundle.downloadStatus)" "yellow"
                    }
                }
            }

            # Retry failed downloads (up to maxRetries)
            if ($failed.Count -gt 0) {
                foreach ($failedBundle in $failed) {
                    $bundleKey = $failedBundle.bundleId

                    if (-not $retryCount.ContainsKey($bundleKey)) {
                        $retryCount[$bundleKey] = 0
                    }

                    if ($retryCount[$bundleKey] -lt $maxRetries) {
                        $retryCount[$bundleKey]++
                        My-Logger "  Retrying failed bundle: $($failedBundle.componentType) (attempt $($retryCount[$bundleKey])/$maxRetries)" "yellow"
                        Delete-VCFBundle -BundleId $failedBundle.bundleId -EndpointIp $EndpointIp
                        Download-VCFBundle -BundleId $failedBundle.bundleId -EndpointIp $EndpointIp
                    } else {
                        My-Logger "  Bundle $($failedBundle.componentType) failed after $maxRetries retries" "red"
                    }
                }
            }

            # Check if all done
            if ($inProgress.Count -eq 0 -and ($failed.Count -eq 0 -or $failed.Count -eq $retryCount.Keys.Count)) {
                if ($failed.Count -gt 0) {
                    My-Logger "`nBundle downloads completed with $($failed.Count) permanent failure(s)" "yellow"
                    $failed | ForEach-Object {
                        My-Logger "    - $($_.componentType): FAILED" "red"
                    }
                } else {
                    My-Logger "`nAll $TotalBundles bundles downloaded successfully!" "green"
                }
                break
            }

            Start-Sleep -Seconds 60
        } catch {
            My-Logger "  Error checking download status: $($_.Exception.Message)" "yellow"
            Start-Sleep -Seconds 60
        }
    }
}

Function Download-VCFRelease {
    param(
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    $headers = Get-VCFSDDCmToken

    My-Logger "Retrieving $VCFInstallerProductSKU release components..." "cyan"

    # Get release components
    try {
        $uri = "https://${EndpointIp}/v1/releases/${VCFInstallerProductSKU}/release-components?releaseVersion=${VCFInstallerProductVersion}&automatedInstall=true&imageType=INSTALL"
        $response = Invoke-WebRequest -Uri $uri -Method GET -SkipCertificateCheck -Headers $headers
        $components = (($response.Content | ConvertFrom-Json).elements |
            Where-Object {$_.releaseVersion -eq $VCFInstallerProductVersion}).components

        My-Logger "  Found $($components.Count) components for $VCFInstallerProductSKU ${VCFInstallerProductVersion}" "green"
    } catch {
        My-Logger "Failed to retrieve release components" "red"
        Write-Error "`n$($_.Exception.Message)`n"
        return
    }

    # Build bundle map
    # Note: $component.versions.artifacts.bundles.id can be a single id OR an array
    # (components with multiple available versions return multiple artifact ids).
    # Flatten and pick a single concrete bundle id so -BundleId always gets a string.
    $bundle = @{}
    foreach ($component in $components) {
        $rawIds = @($component.versions.artifacts.bundles.id | Where-Object { $_ })
        if ($rawIds.Count -eq 0) {
            My-Logger "  Skipping $($component.name): no bundle id found" "yellow"
            continue
        }
        # If multiple ids, prefer the one matching the target version; else take the first.
        $chosenId = $rawIds[0]
        if ($rawIds.Count -gt 1) {
            $match = @($component.versions | Where-Object { $_.version -eq $VCFInstallerProductVersion }).artifacts.bundles.id | Select-Object -First 1
            if ($match) { $chosenId = $match }
            My-Logger "  $($component.name): $($rawIds.Count) bundle ids, using $chosenId" "cyan"
        }
        $bundle[$component.name] = [string]$chosenId
    }

    # Download each bundle (with idempotency)
    My-Logger "`nInitiating bundle downloads..." "cyan"
    $downloadResults = @{}
    foreach ($entry in $bundle.GetEnumerator()) {
        My-Logger "Processing: $($entry.Key)" "cyan"
        $downloadResults[$entry.Key] = Download-VCFBundle -BundleId $entry.Value -EndpointIp $EndpointIp
    }

    # Wait for all downloads to complete (pass total count)
    Wait-VCFBundleDownloads -EndpointIp $EndpointIp -ProductSKU $VCFInstallerProductSKU -ProductVersion $VCFInstallerProductVersion -TotalBundles $bundle.Count
}

Function Verify-VCFAPIEndpoint {
    param(
        [Parameter(Mandatory=$true)][String]$EndpointName,
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    My-Logger "Waiting for ${EndpointName} API to become ready..." "cyan"

    while(1) {
        try {
            $method = "GET"
            $uri = "https://${EndpointIp}/v1/system/appliance-info"
            $requests = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -TimeoutSec 30
            if($requests.StatusCode -eq 200) {
                My-Logger "  ${EndpointName} API is now ready!" "green"
                break
            }
        } catch {
            Write-Host -NoNewline "`r"
            Write-Host -NoNewline -ForegroundColor Yellow "  Waiting for ${EndpointName} API... (will retry in 30s)"
            sleep 30
        }
    }
    Write-Host ""  # New line after progress indicator
}

# NEW: Create or retrieve WLD-specific network pool for the WLD hosts
Function Get-OrCreate-WLDNetworkPool {
    param(
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    $headers = Get-VCFSDDCmToken

    # 1. Get all existing pools
    $networkPoolResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/network-pools" `
                                             -Method GET `
                                             -SkipCertificateCheck `
                                             -Headers $headers
    $networkPools = ($networkPoolResponse.Content | ConvertFrom-Json).elements

    # --- LIST ALL EXISTING POOLS IN LOG ---
    if ($networkPools -and $networkPools.Count -gt 0) {
        My-Logger "Existing Network Pools discovered in SDDC Manager:"
        foreach ($p in $networkPools) {
            My-Logger "  - Name: $($p.name)  |  ID: $($p.id)" "cyan"
        }
    } else {
        My-Logger "No existing Network Pools found in SDDC Manager" "yellow"
    }
    # --------------------------------------

    # 2. Check if the requested WLD pool already exists
    $existingPool = $networkPools | Where-Object { $_.name -eq $PoolName } | Select-Object -First 1
    if ($existingPool) {
        My-Logger "Found existing WLD Network Pool '$PoolName' (ID: $($existingPool.id))" "green"
        return $existingPool.id
    }

    My-Logger "WLD Network Pool '$PoolName' not found, creating ..." "yellow"

    # 3. Prepare subnet + mask (we store CIDR, API wants subnet + mask)
    $wldVmtnSubnet = ($WLDvMotionCidr -split "/")[0]
    $wldVsanSubnet = ($WLDVsanCidr    -split "/")[0]

    # Reuse global mask (or define separate WLD masks if you prefer)
    $wldMask = $VMNetmask   # e.g. 255.255.255.0

    # 4. Build WLD pool spec (only VMOTION + VSAN - no MANAGEMENT here)
    $wldPoolSpec = @{
        name     = $PoolName
        networks = @(
            @{
                type    = "VMOTION"
                vlanId  = $WLDvMotionVlan
                mtu     = 8900
                subnet  = $wldVmtnSubnet
                mask    = $wldMask
                gateway = $WLDvMotionGateway
                ipPools = @(
                    @{
                        start = $WLDvMotionStart
                        end   = $WLDvMotionEnd
                    }
                )
            },
            @{
                type    = "VSAN"
                vlanId  = $WLDVsanVlan
                mtu     = 8900
                subnet  = $wldVsanSubnet
                mask    = $wldMask
                gateway = $WLDVsanGateway
                ipPools = @(
                    @{
                        start = $WLDVsanStart
                        end   = $WLDVsanEnd
                    }
                )
            }
        )
    }

    $body = $wldPoolSpec | ConvertTo-Json -Depth 6

    My-Logger "Creating WLD Network Pool with spec:`n$body" "cyan"

    $createResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/network-pools" `
                                        -Method POST `
                                        -SkipCertificateCheck `
                                        -Headers $headers `
                                        -Body $body `
                                        -ContentType "application/json"

    if ($createResponse.StatusCode -ne 200 -and $createResponse.StatusCode -ne 201) {
        My-Logger "Failed to create WLD Network Pool '$PoolName' (Status: $($createResponse.StatusCode))" "red"
        Write-Error "`n$($createResponse.Content)`n"
        throw "Network Pool creation failed"
    }

    # 5. Re-read pools to get the new ID
    $networkPoolResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/network-pools" `
                                             -Method GET `
                                             -SkipCertificateCheck `
                                             -Headers $headers
    $networkPools = ($networkPoolResponse.Content | ConvertFrom-Json).elements
    $newPool = $networkPools | Where-Object { $_.name -eq $PoolName } | Select-Object -First 1

    if (-not $newPool) {
        throw "Created Network Pool '$PoolName' but could not retrieve its ID"
    }

    My-Logger "Created WLD Network Pool '$PoolName' (ID: $($newPool.id))" "green"
    return $newPool.id
}

# (PowerCLI module checks omitted in your original; keeping them commented out)

if($confirmDeployment -eq 1) {
    Write-Host -ForegroundColor Magenta "`nPlease confirm the following configuration will be deployed:`n"

    Write-Host -ForegroundColor Yellow "---- VCF Automated Workload Domain Deployment Configuration ---- "
    Write-Host -NoNewline -ForegroundColor Green "Workload Domain Name: "
    Write-Host -ForegroundColor White $VCFWorkloadDomainName
    Write-Host -NoNewline -ForegroundColor Green "Workload Domain Org Name: "
    Write-Host -ForegroundColor White $VCFWorkloadDomainOrgName

    Write-Host -ForegroundColor Yellow "`n---- Target SDDC Manager Configuration ---- "
    Write-Host -NoNewline -ForegroundColor Green "SDDC Manager Hostname: "
    Write-Host -ForegroundColor White $sddcManagerFQDN

    Write-Host -ForegroundColor Yellow "`n---- Workload Domain vCenter Server Configuration ----"
    Write-Host -NoNewline -ForegroundColor Green "vCenter Server Hostname: "
    Write-Host -ForegroundColor White "${VCFWorkloadDomainVCSAHostname}.${VMDomain} (${VCFWorkloadDomainVCSAIP})"

    Write-Host -ForegroundColor Yellow "`n---- Workload Domain NSX Server Configuration ----"
    Write-Host -NoNewline -ForegroundColor Green "NSX Manager VIP Hostname: "
    Write-Host -ForegroundColor White $VCFWorkloadDomainNSXManagerVIPHostname"."$VMDomain
    Write-Host -NoNewline -ForegroundColor Green "Node 1: "
    Write-Host -ForegroundColor White "${VCFWorkloadDomainNSXManagerNode1Hostname}.${VMDomain}"

    Write-Host -ForegroundColor Magenta "`nWould you like to proceed with this deployment?`n"
    $answer = Read-Host -Prompt "Do you accept (Y or N)"
    if($answer -ne "Y" -and $answer -ne "y") {
        exit
    }
    Clear-Host
}

if($updateSDDCMConfig -eq 1) {
    My-Logger "Connecting to VCF Management vCenter Server $VCSAName ..." "cyan"
    $viConnection = Connect-VIServer $VCSAIP -User "administrator@vsphere.local" -Password $VCSASSOPassword -WarningAction SilentlyContinue

    $sddcmVM = Get-VM -Server $viConnection $SddcManagerHostname

    $scriptName = "vcfSddcmScript.sh"
    $script = @"
#!/bin/bash
# Generated by William Lam's VCF 9 Automated Deployment Lab Script


"@

    if($VCFInstallerSoftwareDepot -eq "offline") {
        $vcfLcmConfigFile = "/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties"
        if($VCFInstallerDepotPort -ne "") {
            $script += "sed -i -e `"s|lcm.depot.adapter.port=.*|lcm.depot.adapter.port=${VCFInstallerDepotPort}|`" ${vcfLcmConfigFile}`n"
        }

        if($VCFInstallerDepotHttps -eq $false) {
            $script += "sed -i -e `"/lcm.depot.adapter.port=.*/a lcm.depot.adapter.httpsEnabled=false`" ${vcfLcmConfigFile}`n"
        }
    }

    $script += "systemctl stop lcm`n"
    $script += "systemctl start lcm"
    $script | Set-Content -NoNewline -Encoding UTF8 $scriptName

    My-Logger "Transferring configuration shell script ($scriptName) to SDDC Manager VM ..."
    Copy-VMGuestFile -Server $viConnection -VM $sddcmVM -GuestUser "root" -GuestPassword $SddcManagerRootPassword -LocalToGuest -Source ${scriptName} -Destination /tmp/${scriptName} -Force | Out-Null
    My-Logger "Running configuration shell script on SDDC Manager VM ..."
    Invoke-VMScript -ScriptText "bash /tmp/${scriptName}" -VM $sddcmVM -GuestUser "root" -GuestPassword $SddcManagerRootPassword  | Out-Null

    Start-Sleep -Seconds 120

    My-Logger "Disconnecting from VCF Management vCenter Server $VCSAName ..."
    Disconnect-VIServer -Server $viConnection -Confirm:$false
}

if($applyEsaHclWorkaround -eq 1) {
    My-Logger "`n========================================" "cyan"
    My-Logger "  APPLYING vSAN ESA HCL WORKAROUND (SDDC MANAGER)" "cyan"
    My-Logger "========================================`n" "cyan"

    # 9.1 nested-lab workaround. Host commission runs a vSAN ESA NVMe-HCL check
    # in the operationsmanager service; nested vNVMe disks are never HCL-certified,
    # so commission fails with "Failed to validate vSAN HCL status" unless we add
    # the disk-claim property. Per Broadcom KB 408300 and William Lam's 9.1 notes,
    # for host commission the property must be on operationsmanager
    # (application-prod.properties); for the subsequent Create-Domain it must also
    # be on domainmanager (application.properties). We set both, plus the
    # feature.properties gate, then restart all SDDC Manager services.
    #
    # Done via the SDDC Manager VM guest (Connect-VIServer to the MANAGEMENT
    # vCenter, then Invoke-VMScript) - the same mechanism the block above uses,
    # so no SSH client / Posh-SSH is required.

    My-Logger "Connecting to VCF Management vCenter Server $VCSAName ..." "cyan"
    $viConnection = Connect-VIServer $VCSAIP -User "administrator@vsphere.local" -Password $VCSASSOPassword -WarningAction SilentlyContinue

    $sddcmVM = Get-VM -Server $viConnection $SddcManagerHostname

    $opsProps     = "/etc/vmware/vcf/operationsmanager/application-prod.properties"
    $dmProps      = "/etc/vmware/vcf/domainmanager/application.properties"
    $featureProps = "/home/vcf/feature.properties"
    $diskClaim    = "vsan.esa.sddc.managed.disk.claim=true"
    $featureGate  = "feature.vcf.vgl-43370.vsan.esa.sddc.managed.disk.claim=true"

    $scriptName = "vcfEsaHclWorkaround.sh"
    # Each line is appended only if not already present (grep -qxF) so the block
    # is idempotent and safe to re-run.
    $script = @"
#!/bin/bash
# Generated by VCF 9.1 WLD Lab Script - vSAN ESA HCL commission workaround
grep -qxF '$diskClaim' '$opsProps' 2>/dev/null || echo '$diskClaim' >> '$opsProps'
grep -qxF '$diskClaim' '$dmProps' 2>/dev/null || echo '$diskClaim' >> '$dmProps'
grep -qxF '$featureGate' '$featureProps' 2>/dev/null || echo '$featureGate' >> '$featureProps'
chmod 644 '$featureProps' 2>/dev/null || true
echo 'y' | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh
"@
    $script | Set-Content -NoNewline -Encoding UTF8 $scriptName

    My-Logger "Transferring ESA HCL workaround script ($scriptName) to SDDC Manager VM ..."
    Copy-VMGuestFile -Server $viConnection -VM $sddcmVM -GuestUser "root" -GuestPassword $SddcManagerRootPassword -LocalToGuest -Source ${scriptName} -Destination /tmp/${scriptName} -Force | Out-Null

    My-Logger "Applying properties and restarting SDDC Manager services (this restarts ALL services) ..." "yellow"
    Invoke-VMScript -ScriptText "bash /tmp/${scriptName}" -VM $sddcmVM -GuestUser "root" -GuestPassword $SddcManagerRootPassword | Out-Null

    My-Logger "Disconnecting from VCF Management vCenter Server $VCSAName ..."
    Disconnect-VIServer -Server $viConnection -Confirm:$false

    My-Logger "Waiting 2 minutes for SDDC Manager services to come back up ..." "cyan"
    Start-Sleep -Seconds 120

    # Confirm the API is actually responsive again before we proceed to commission.
    Verify-VCFAPIEndpoint -EndpointName "SDDC Manager" -EndpointIp $SddcManagerIP
    My-Logger "vSAN ESA HCL workaround applied and SDDC Manager is back online." "green"
}

if($configureSDDCMConfig -eq 1) {
    My-Logger "`n========================================" "cyan"
    My-Logger "  SDDC MANAGER BUNDLE DOWNLOAD" "cyan"
    My-Logger "========================================`n" "cyan"

    Verify-VCFAPIEndpoint -EndpointName "SDDC Manager" -EndpointIp $SddcManagerIP

    # 9.1: depot connect + sync are no longer done per-SDDC-Manager.
    # The VCF Depot is inherited from the fleet (flt01) - the old
    # PUT/GET /v1/system/settings/depot endpoints return API_NO_LONGER_SUPPORTED.
    # We only trigger bundle downloads here.
    $connectDepot = 0
    $syncDepot = 0
    $downloadReleases = 1

    if($downloadReleases -eq 1) {
        Download-VCFRelease -EndpointIp $SddcManagerIP
    }
}

if($generateWldHostCommissionJson -eq 1 -or $startWLDDeployment -eq 1) {
    # Disconnect any existing sessions first
    try {
        Disconnect-VcfSddcManagerServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Ignore disconnect errors
    }

    My-Logger "Connecting to SDDC Manager at $SddcManagerIP ..." "cyan"
    try {
        Connect-VcfSddcManagerServer -Server $SddcManagerIP -User "administrator@vsphere.local" -Password $VCSASSOPassword -ErrorAction Stop | Out-Null
        My-Logger "  Successfully connected to SDDC Manager" "green"
    } catch {
        My-Logger "Failed to connect to SDDC Manager at $SddcManagerIP" "red"
        Write-Error "`n$($_.Exception.Message)`n"
        exit
    }
}

if($generateWldHostCommissionJson -eq 1) {
    My-Logger "Generating VCF Workload Domain Host Commission file $VCFWorkloadDomainUIJSONFile and $VCFWorkloadDomainAPIJSONFile for SDDC Manager UI and API"

    # NEW: Ensure WLD Network Pool exists and get its ID
    try {
        $wldPoolId = Get-OrCreate-WLDNetworkPool -PoolName $VCFWorkloadDomainPoolName
        My-Logger "Using WLD Network Pool '$VCFWorkloadDomainPoolName' (ID: $wldPoolId)" "green"
    } catch {
        My-Logger "Failed to get or create WLD Network Pool '$VCFWorkloadDomainPoolName'" "red"
        Write-Error "`n$($_.Exception.Message)`n"
        exit
    }

    if($VCFWorkloadDomainEnableVSANESA) {
        $storageType = "VSAN_ESA"
    } else {
        $storageType = "VSAN"
    }

    $commissionHostsUI= @()
    $commissionHostsAPI= @()
    $NestedESXiHostnameToIPsForWorkloadDomain.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
        $hostFQDN = $_.Key + "." + $VMDomain

        $tmp1 = [ordered] @{
            "fqdn"            = $hostFQDN;
            "username"        = "root";
            "password"        = $VMPassword;
            "networkPoolName" = $VCFWorkloadDomainPoolName;
            "storageType"     = $storageType;
        }
        $commissionHostsUI += $tmp1

        $tmp2 = [ordered] @{
            "fqdn"        = $hostFQDN;
            "username"    = "root";
            "password"    = $VMPassword;
            "networkPoolId" = $wldPoolId;
            "storageType" = $storageType;
        }
        $commissionHostsAPI += $tmp2
    }

    $vcfCommissionHostConfigUI = @{
        "hosts" = $commissionHostsUI
    }

    $vcfCommissionHostConfigUI | ConvertTo-Json -Depth 2 | Out-File -LiteralPath $VCFWorkloadDomainUIJSONFile
    $commissionHostsAPI | ConvertTo-Json -Depth 2 | Out-File -LiteralPath $VCFWorkloadDomainAPIJSONFile
}

if($commissionHost -eq 1) {
    My-Logger "Commissioning ESXi hosts for Workload Domain deployment using $VCFWorkloadDomainAPIJSONFile ..." "cyan"

    # Read the JSON file
    $commissionHostsJson = Get-Content -Raw $VCFWorkloadDomainAPIJSONFile

    # Get auth token
    $headers = Get-VCFSDDCmToken

    try {
        $uri = "https://${SddcManagerIP}/v1/hosts"
        $method = "POST"

        if($Debug) {
            My-Logger "DEBUG: Method: $method" "cyan"
            My-Logger "DEBUG: Uri: $uri" "cyan"
            My-Logger "DEBUG: Body: $commissionHostsJson" "cyan"
        }

        $response = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -Headers $headers -Body $commissionHostsJson -ContentType "application/json"

        if($response.StatusCode -eq 202) {
            $taskId = (($response.Content | ConvertFrom-Json).id)
            My-Logger "  Host commission task started with ID: $taskId" "green"

            # Wait for commission to complete
            My-Logger "Waiting for host commission to complete..." "cyan"
            while(1) {
                try {
                    $taskResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/tasks/$taskId" -Method GET -SkipCertificateCheck -Headers $headers
                    $task = ($taskResponse.Content | ConvertFrom-Json)
                    $taskStatus = $task.status

                    if($taskStatus -eq "Successful") {
                        My-Logger "  Host commission completed successfully" "green"
                        break
                    } elseif($taskStatus -eq "Failed") {
                        My-Logger "  Host commission failed!" "red"
                        # Pull full task detail so the actual reason is visible.
                        try {
                            $failDetail = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/tasks/$taskId" -Method GET -SkipCertificateCheck -Headers $headers
                            $failTask = ($failDetail.Content | ConvertFrom-Json)
                            if($failTask.errors) {
                                My-Logger "Error details: $($failTask.errors | ConvertTo-Json -Depth 10)" "red"
                            }
                            if($failTask.subTasks) {
                                foreach($st in $failTask.subTasks) {
                                    if($st.status -ne "SUCCESSFUL" -and $st.status -ne "Successful") {
                                        My-Logger "  - Subtask '$($st.name)': $($st.status)" "red"
                                        if($st.errors) { My-Logger "      $($st.errors | ConvertTo-Json -Depth 10)" "red" }
                                    }
                                }
                            }
                        } catch {
                            My-Logger "  Could not retrieve commission failure detail: $($_.Exception.Message)" "yellow"
                        }
                        My-Logger "Aborting: host commission failed. Fix the issue above before continuing." "red"
                        exit
                    } else {
                        Write-Host -NoNewline "`r"
                        Write-Host -NoNewline -ForegroundColor Yellow "  Host commission in progress (Status: $taskStatus)..."
                        Start-Sleep -Seconds 30
                    }
                } catch {
                    My-Logger "Error checking task status: $($_.Exception.Message)" "yellow"
                    Start-Sleep -Seconds 30
                }
            }
            Write-Host ""  # New line after progress
        } else {
            My-Logger "Unexpected response status: $($response.StatusCode)" "yellow"
        }
    } catch {
        My-Logger "Failed to commission hosts" "red"
        Write-Error "`n$($_.Exception.Message)`n"
        return
    }
}

if($generateWLDDeploymentFile -eq 1) {
    My-Logger "Retrieving unassigned ESXi hosts from SDDC Manager and creating Workload Domain JSON deployment file $VCFWorkloadJSONFile" "cyan"

    # --------------------------------------------------------------------
    # Derive WLD ESXi NSX TEP network details from CIDR
    # --------------------------------------------------------------------
    $wldEsxiNSXTepNetwork       = $NestedWLDESXiNSXTepNetworkCidr.Split("/")[0]
    $wldEsxiNSXTepNetworkOctets = $wldEsxiNSXTepNetwork.Split(".")

    # Default gateway = .1
    $wldEsxiNSXTepGateway = ($wldEsxiNSXTepNetworkOctets[0..2] -join '.') + ".1"

    # TEP Pool Range
    $wldEsxiNSXTepStart = ($wldEsxiNSXTepNetworkOctets[0..2] -join '.') + ".10"
    $wldEsxiNSXTepEnd   = ($wldEsxiNSXTepNetworkOctets[0..2] -join '.') + ".50"
    # --------------------------------------------------------------------

    # Get unassigned hosts using REST API
    $headers = Get-VCFSDDCmToken
    try {
        $hostsResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/hosts?status=UNASSIGNED_USEABLE" -Method GET -SkipCertificateCheck -Headers $headers
        $hosts = ($hostsResponse.Content | ConvertFrom-Json).elements
        My-Logger "  Found $($hosts.Count) unassigned useable hosts" "green"
        if (@($hosts).Count -eq 0) {
            My-Logger "No unassigned useable hosts found - cannot build a Workload Domain spec." "red"
            My-Logger "This usually means host commission did not succeed. Check commission status and re-run." "red"
            exit
        }
    } catch {
        My-Logger "Failed to retrieve unassigned hosts" "red"
        Write-Error "`n$($_.Exception.Message)`n"
        exit
    }

    $hostSpecs = @()
    foreach ($id in $hosts.id) {
        if($VCFWorkloadDomainSeparateNSXSwitch) {
            $vmNics = @(
                @{
                    "id" = "vmnic0"
                    "vdsName" = "${VCFWorkloadDomainVCSAClusterName}-vds01"
                }
                @{
                    "id" = "vmnic1"
                    "vdsName" = "${VCFWorkloadDomainVCSAClusterName}-vds01"
                }
                @{
                    "id" = "vmnic2"
                    "vdsName" = "${VCFWorkloadDomainVCSAClusterName}-vds02"
                }
                @{
                    "id" = "vmnic3"
                    "vdsName" = "${VCFWorkloadDomainVCSAClusterName}-vds02"
                }
            )
        } else {
                $vmNics = @(
                @{
                    "id" = "vmnic0"
                    "vdsName" = "${VCFWorkloadDomainVCSAClusterName}-vds01"
                }
                @{
                    "id" = "vmnic1"
                    "vdsName" = "${VCFWorkloadDomainVCSAClusterName}-vds01"
                }
            )
        }

        $tmp = [ordered] @{
            "id" = $id
            "hostNetworkSpec" = @{
                "vmNics" = $vmNics
            }
        }
        $hostSpecs += $tmp
    }

    $payload = [ordered] @{
        "domainName" = $VCFWorkloadDomainName
        "orgName" = $VCFWorkloadDomainOrgName
        "deployWithoutLicenseKeys" = $true
        "vcenterSpec" = @{
            "name" = $VCFWorkloadDomainVCSAHostname
            "networkDetailsSpec" = @{
                "ipAddress" = $VCFWorkloadDomainVCSAIP
                "dnsName" = $VCFWorkloadDomainVCSAHostname + "." + $VMDomain
                # FIXED: use WLD gateway variable
                "gateway" = $VMMGMTGateway
                "subnetMask" = $VMNetmask
            }
            "rootPassword" = $VCFWorkloadDomainVCSARootPassword
            "datacenterName" = $VCFWorkloadDomainVCSADatacenterName
        }
        "ssoDomainSpec" = [ordered]@{
            "ssoDomainName" = "vsphere.local"
            "ssoDomainPassword" = $VCFWorkloadDomainVCSASSOPassword
        }
        "computeSpec" = [ordered] @{
            "clusterSpecs" = @(
                [ordered] @{
                    "name" = ${VCFWorkloadDomainVCSAClusterName}
                    "hostSpecs" = $hostSpecs
                    "datastoreSpec" = @{
                        "vsanDatastoreSpec" = @{
                            "failuresToTolerate" = "1"
                            "datastoreName" = "${VCFWorkloadDomainVCSAClusterName}-vsan01"
                        }
                    }
                    "networkSpec" = @{
                        "vdsSpecs" = @(
                            [ordered] @{
                                "name" = "${VCFWorkloadDomainVCSAClusterName}-vds01"
                                "portGroupSpecs" = @(
                                    @{
                                        "name" = "${VCFWorkloadDomainVCSAClusterName}-vds01-management"
                                        "transportType" = "MANAGEMENT"
                                    }
                                    @{
                                        "name" = "${VCFWorkloadDomainVCSAClusterName}-vds01-vmotion"
                                        "transportType" = "VMOTION"
                                    }
                                    @{
                                        "name" = "${VCFWorkloadDomainVCSAClusterName}-vds01-vsan"
                                        "transportType" = "VSAN"
                                    }
                                )
                            }
                        )
                        "nsxClusterSpec" = [ordered] @{
                            "nsxTClusterSpec" = @{
                                "geneveVlanId" = 203
                                "ipAddressPoolSpec" = @{
                                    "name" = "wld-pool"
                                    "subnets" = @(
                                        [ordered] @{
                                            "cidr" = $NestedWLDESXiNSXTepNetworkCidr
                                            "gateway" = $wldEsxiNSXTepGateway
                                            "ipAddressPoolRanges" = @(
                                                [ordered] @{
                                                    "start" = $wldEsxiNSXTepStart
                                                    "end" = $wldEsxiNSXTepEnd
                                                }
                                            )
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            )
        }
        "nsxTSpec" = [ordered] @{
            "nsxManagerSpecs" = @(
                [ordered] @{
                    "name" = $VCFWorkloadDomainNSXManagerNode1Hostname
                    "networkDetailsSpec" = @{
                        "ipAddress" = $VCFWorkloadDomainNSXManagerNode1IP
                        "dnsName" = $VCFWorkloadDomainNSXManagerNode1Hostname + "." + $VMDomain
                        "gateway" = $VMMGMTGateway
                        "subnetMask" = $VMNetmask
                    }
                }
            )
            "formFactor"= $NSXManagerSize
            "vipFqdn" = $VCFWorkloadDomainNSXManagerVIPHostname + "." + $VMDomain
            "nsxManagerAdminPassword" = $VCFWorkloadDomainNSXAdminPassword
        }
    }

    if($VCFWorkloadDomainSeparateNSXSwitch) {
        $payload.computeSpec.clusterSpecs.networkSpec.vdsSpecs+=@{"name"="${VCFWorkloadDomainVCSAClusterName}-vds02";"isUsedByNsxt"=$true}
    }

    if($VCFWorkloadDomainEnableVSANESA) {
        $esaEnable = [ordered]@{
            "enabled" = $true
        }
        $payload.computeSpec.clusterSpecs.datastoreSpec.vsanDatastoreSpec.Add("esaConfig",$esaEnable)

        $payload.computeSpec.clusterSpecs.datastoreSpec.vsanDatastoreSpec.Remove("failuresToTolerate")
    }

    if($VCFWorkloadDomainEnableVCLM) {
        # Get vLCM personality using REST API
        $headers = Get-VCFSDDCmToken
        try {
            $personalityResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/personalities" -Method GET -SkipCertificateCheck -Headers $headers
            $personalities = ($personalityResponse.Content | ConvertFrom-Json).elements
            $clusterImageId = ($personalities | where {$_.personalityName -eq $VCFManagementDomainVLCMImageName}).personalityId

            if($clusterImageId -eq $null) {
                Write-Host -ForegroundColor Red "`nUnable to find vLCM Image named $VCFManagementDomainVLCMImageName ...`n"
                exit
            }

            $payload.computeSpec.clusterSpecs[0].Add("clusterImageId",$clusterImageId)
        } catch {
            My-Logger "Failed to retrieve vLCM personalities" "red"
            Write-Error "`n$($_.Exception.Message)`n"
            exit
        }
    }

    My-Logger "Saving Workload Domain deployment spec to $VCFWorkloadJSONFile" "green"
    $payload | ConvertTo-Json -Depth 12 | Out-File $VCFWorkloadJSONFile
}

if($startWLDDeployment -eq 1) {
    My-Logger "`n========================================" "cyan"
    My-Logger "  STARTING WORKLOAD DOMAIN DEPLOYMENT" "cyan"
    My-Logger "========================================`n" "cyan"

    # Read JSON file
    $domainJson = Get-Content -Raw $VCFWorkloadJSONFile

    # Get auth token
    $headers = Get-VCFSDDCmToken

    try {
        $uri = "https://${SddcManagerIP}/v1/domains"
        $method = "POST"

        if($Debug) {
            My-Logger "DEBUG: Method: $method" "cyan"
            My-Logger "DEBUG: Uri: $uri" "cyan"
        }

        $response = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -Headers $headers -Body $domainJson -ContentType "application/json"

        if($response.StatusCode -eq 202 -or $response.StatusCode -eq 200) {
            $taskId = (($response.Content | ConvertFrom-Json).id)
            My-Logger "  Workload Domain deployment task started with ID: $taskId" "green"
            My-Logger "`nOpen a browser to monitor the deployment progress:" "cyan"
            My-Logger "  - VCF Operations: https://${SddcManagerIP}" "white"
            My-Logger "  - vCenter Server: https://${VCSAIP}" "white"
        } else {
            My-Logger "Unexpected response status: $($response.StatusCode)" "yellow"
        }
    } catch {
        My-Logger "Failed to start Workload Domain deployment" "red"
        # The real reason for a 400 lives in the response body (errorCode / message /
        # nestedErrors / causes). On PowerShell 7 it is almost always in
        # $_.ErrorDetails.Message; the stream fallback covers cases where that is empty.
        $respBody = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $respBody = $_.ErrorDetails.Message
        } elseif ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $respBody = $reader.ReadToEnd()
            } catch {}
        }
        if ($respBody) {
            My-Logger "Server response body:" "yellow"
            try { ($respBody | ConvertFrom-Json) | ConvertTo-Json -Depth 30 | Out-Host }
            catch { My-Logger $respBody "yellow" }
        } else {
            My-Logger "(No response body returned - likely a timeout or transport-level failure)" "yellow"
        }
        Write-Error "`n$($_.Exception.Message)`n"
        exit
    }
}

$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

My-Logger "`n========================================" "cyan"
My-Logger "  VCF WORKLOAD DOMAIN DEPLOYMENT COMPLETE" "cyan"
My-Logger "========================================" "cyan"
My-Logger "  StartTime: $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" "cyan"
My-Logger "  EndTime:   $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))" "cyan"
My-Logger "  Duration:  $duration minutes" "cyan"
My-Logger "  Log File:  $verboseLogFile" "cyan"
My-Logger "========================================" "cyan"