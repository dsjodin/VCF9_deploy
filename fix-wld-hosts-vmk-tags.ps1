# ============================================================================
# fix-wld-host-vmk-tags-powercli.ps1
#
# Purpose:
#   VCF host commission requires vmk0 to carry ONLY the "Management" tag. The
#   nested-ESXi OVA ships vmk0 with Management + VMotion + VSAN, which makes
#   commission fail:
#       HOSTS_VALIDATION_FOR_COMMISSION_FAILED
#       "Host must have only Management tag enabled on the VMkernel network
#        interface, found more than one tag or non Management tag."
#
#   This connects to each WLD ESXi host with PowerCLI (the host's own 443 API,
#   not vCenter - the WLD hosts are standalone until commissioned) and runs the
#   esxcli tag commands via Get-EsxCli -V2. No SSH, no Posh-SSH, no password
#   prompts. Idempotent and safe to re-run.
#
# Requirements:
#   - PowerShell 7
#   - VMware PowerCLI (already used by the fleet deployment script)
#
# Usage:
#   . .\your-config.ps1
#   .\fix-wld-host-vmk-tags-powercli.ps1                 # connect by IP (default)
#   .\fix-wld-host-vmk-tags-powercli.ps1 -EnableSSH      # also turn SSH on
#   .\fix-wld-host-vmk-tags-powercli.ps1 -WhatIfTags     # dry run, no changes
#
#   # explicit hosts instead of config:
#   .\fix-wld-host-vmk-tags-powercli.ps1 -EsxiHosts "10.2.200.10","10.2.200.11","10.2.200.12" -RootPassword "VMwareVCF9!"
# ============================================================================

param(
    # Host IPs or FQDNs. If omitted, taken from the dot-sourced config.
    [string[]]$EsxiHosts,

    # ESXi root password. Falls back to $VMPassword from the config.
    [string]$RootPassword,

    [string]$RootUser = "root",

    # The single tag that should remain on vmk0.
    [string]$KeepTag = "Management",

    # Build the host list from FQDNs ($key.$VMDomain) instead of IPs.
    # Default is IP, which avoids the lab's flaky DNS entirely.
    [switch]$UseFQDN,

    # Also start the SSH (TSM-SSH) service on each host while connected.
    [switch]$EnableSSH,

    # Show what would change without changing anything.
    [switch]$WhatIfTags
)

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host -NoNewline -ForegroundColor DarkGray "[$ts] "
    Write-Host -ForegroundColor $Color $Message
}

# --- PowerCLI present? -------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI -ErrorAction SilentlyContinue) -and
    -not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) {
    Write-Host -ForegroundColor Red "`nVMware PowerCLI not found. It is the same module the fleet deployment script uses."
    Write-Host -ForegroundColor Yellow "Install with: Install-Module VMware.PowerCLI -Scope CurrentUser`n"
    exit 1
}

# Don't choke on the self-signed ESXi certs; don't nag about CEIP.
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCeip $false -Scope Session -Confirm:$false | Out-Null

# --- Resolve host list -------------------------------------------------------
if (-not $EsxiHosts -or $EsxiHosts.Count -eq 0) {
    if ($NestedESXiHostnameToIPsForWorkloadDomain) {
        if ($UseFQDN -and $VMDomain) {
            $EsxiHosts = @($NestedESXiHostnameToIPsForWorkloadDomain.Keys | ForEach-Object { "$_.$VMDomain" })
            Write-Log "Using WLD host FQDNs from config: $($EsxiHosts -join ', ')" "Cyan"
        } else {
            $EsxiHosts = @($NestedESXiHostnameToIPsForWorkloadDomain.Values)
            Write-Log "Using WLD host IPs from config: $($EsxiHosts -join ', ')" "Cyan"
        }
    } else {
        Write-Host -ForegroundColor Red "`nNo hosts. Pass -EsxiHosts or dot-source a config with `$NestedESXiHostnameToIPsForWorkloadDomain.`n"
        exit 1
    }
}

if (-not $RootPassword) {
    if ($VMPassword) { $RootPassword = $VMPassword; Write-Log "Using root password from `$VMPassword" "Cyan" }
    else { Write-Host -ForegroundColor Red "`nNo -RootPassword and no `$VMPassword in scope.`n"; exit 1 }
}

$changed = 0
$errors  = 0

foreach ($h in $EsxiHosts) {
    Write-Log "----------------------------------------------------------------" "DarkGray"
    Write-Log "Host: $h" "White"

    $conn = $null
    try {
        $conn = Connect-VIServer -Server $h -User $RootUser -Password $RootPassword -WarningAction SilentlyContinue -ErrorAction Stop
    } catch {
        Write-Log "  Could not connect (PowerCLI): $($_.Exception.Message)" "Red"
        $errors++
        continue
    }

    try {
        $vmhost = Get-VMHost -Server $conn -ErrorAction Stop | Select-Object -First 1
        $esxcli = Get-EsxCli -Server $conn -VMHost $vmhost -V2

        # Optionally enable SSH.
        if ($EnableSSH) {
            try {
                $sshSvc = Get-VMHostService -Server $conn -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
                if ($sshSvc -and -not $sshSvc.Running) {
                    Start-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
                    Write-Log "  SSH (TSM-SSH) started." "Green"
                } else {
                    Write-Log "  SSH (TSM-SSH) already running." "Green"
                }
            } catch {
                Write-Log "  Could not change SSH service state: $($_.Exception.Message)" "Yellow"
            }
        }

        # Read current vmk0 tags.
        # esxcli network ip interface tag get -i vmk0
        $args = $esxcli.network.ip.interface.tag.get.CreateArgs()
        $args.interfacename = "vmk0"
        $tagResult = $esxcli.network.ip.interface.tag.get.Invoke($args)

        # The result's .Tags is typically a string[] of tag names.
        $tags = @()
        if ($tagResult -and $tagResult.Tags) {
            $tags = @($tagResult.Tags | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        }

        if ($tags.Count -eq 0) {
            Write-Log "  Could not read any tags on vmk0 - skipping." "Yellow"
            $errors++
            continue
        }

        Write-Log "  Current tags: $($tags -join ', ')" "Gray"

        $toRemove = @($tags | Where-Object { $_ -ne $KeepTag })

        if ($toRemove.Count -eq 0) {
            Write-Log "  Already clean - only '$KeepTag' present. No change." "Green"
            continue
        }

        if ($tags -notcontains $KeepTag) {
            Write-Log "  WARNING: '$KeepTag' not present on vmk0; refusing to remove tags (would orphan the host)." "Red"
            $errors++
            continue
        }

        Write-Log "  Will remove: $($toRemove -join ', ')  (keeping '$KeepTag')" "Cyan"

        if ($WhatIfTags) {
            Write-Log "  [dry run] no changes made." "Yellow"
            continue
        }

        foreach ($t in $toRemove) {
            $rargs = $esxcli.network.ip.interface.tag.remove.CreateArgs()
            $rargs.interfacename = "vmk0"
            $rargs.tagname = $t
            $null = $esxcli.network.ip.interface.tag.remove.Invoke($rargs)
        }

        # Verify.
        $afterResult = $esxcli.network.ip.interface.tag.get.Invoke($args)
        $afterTags = @()
        if ($afterResult -and $afterResult.Tags) {
            $afterTags = @($afterResult.Tags | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        }
        Write-Log "  Result tags:  $($afterTags -join ', ')" "Green"

        if ($afterTags.Count -eq 1 -and $afterTags[0] -eq $KeepTag) {
            Write-Log "  OK - vmk0 now has only '$KeepTag'." "Green"
            $changed++
        } else {
            Write-Log "  Tags after cleanup are not exactly '$KeepTag' - check manually." "Yellow"
            $errors++
        }
    } catch {
        Write-Log "  Error processing host: $($_.Exception.Message)" "Red"
        $errors++
    } finally {
        if ($conn) { Disconnect-VIServer -Server $conn -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

Write-Log "================================================================" "DarkGray"
if ($WhatIfTags) {
    Write-Log "Dry run complete. No hosts were modified." "Yellow"
} else {
    Write-Log "Done. Hosts changed: $changed | errors/unconfirmed: $errors" $(if($errors -eq 0){"Green"}else{"Yellow"})
    if ($errors -eq 0) {
        Write-Log "All WLD hosts have only '$KeepTag' on vmk0. Re-run the WLD deployment script now." "Green"
    }
}