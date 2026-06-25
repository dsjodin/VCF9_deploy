# Author: William Lam
# Website: https://williamlam.com
# Enhanced with: Parallel ESXi Deployment + Improved Bundle Management
#
#Version: 2.2

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

# VCF Instance Deployment JSON
$random_string = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object {[char]$_})

$VAppName = "Nested-${VCFInstallerProductSKU}-9-Lab-${random_string}"
$VCFManagementDomainJSONFile = "$(${VCFInstallerProductSKU}.toLower())-mgmt-${random_string}.json"
$verboseLogFile = "vcf-9-lab-deployment-${random_string}.log"

$preCheck = 1
$confirmDeployment = 1
$deployVCFInstaller = 1
$updateVCFInstallerConfig = 1
$configureVCFInstallerConfig = 1
$deployNestedESXiVMsForMgmt = 1
$deployNestedESXiVMsForWLD = 1
$moveVMsIntovApp = 1
$generateMgmtJson = 1
$startVCFBringup = 1
$validateBeforeBringup = 1    # run POST /v1/sddcs/validations before bringup; abort on failure
$uploadVCFNotifyScript = 0

$srcNotificationScript = "vcf-bringup-notification.sh"
$dstNotificationScript = "/root/vcf-bringup-notification.sh"

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

Function Get-VCFInstallerToken {
    $payload = @{
        "username" = $VCFInstallerAdminUsername
        "password" = $VCFInstallerAdminPassword
    }

    $body = $payload | ConvertTo-Json

    try {
        # FIX: bumped from 5s. A 5s timeout on the token call would intermittently
        # cancel the request and trigger the exit below, killing the whole run.
        $requests = Invoke-WebRequest -Uri "https://${VCFInstallerFQDN}/v1/tokens" -Method POST -SkipCertificateCheck -TimeoutSec 30 -Headers @{"Content-Type"="application/json";"Accept"="application/json"} -Body $body
        if($requests.StatusCode -eq 200) {
            $accessToken = ($requests.Content | ConvertFrom-Json).accessToken
        }
    } catch {
        My-Logger "Unable to retrieve VCF Installer Token ..." "red"
        exit
    }

    $headers = @{
        "Content-Type"="application/json"
        "Accept"="application/json"
        "Authorization"="Bearer ${accessToken}"
    }

    return $headers
}

Function Validate-VCFBringupSpec {
    # Runs the installer's pre-bringup validation (POST /v1/sddcs/validations),
    # polls the task to completion, and prints every non-SUCCEEDED check with its
    # nested error detail. Returns $true if the overall result is SUCCEEDED,
    # otherwise $false. This is the same validation bringup runs, but it gives the
    # full structured per-check report instead of a single summarized 400.
    param(
        [Parameter(Mandatory=$true)][String]$EndpointIp,
        [Parameter(Mandatory=$true)][String]$JsonFile
    )

    $headers = Get-VCFInstallerToken
    $body = Get-Content -Raw $JsonFile

    My-Logger "Submitting deployment spec for pre-bringup validation ..." "cyan"

    # Submit. A spec error can come back two ways: a 4xx with the error in the body
    # (synchronous reject), or a 200/202 with a task id to poll (async validation).
    $valId = $null
    try {
        $uri = "https://${EndpointIp}/v1/sddcs/validations"
        if($Debug) {
            My-Logger "DEBUG: Method: POST" "cyan"
            My-Logger "DEBUG: Uri: $uri" "cyan"
        }
        $resp = Invoke-WebRequest -Uri $uri -Method POST -SkipCertificateCheck -TimeoutSec 120 -Headers $headers -Body $body
        $valObj = $resp.Content | ConvertFrom-Json
        $valId = $valObj.id
    } catch {
        # Synchronous rejection - the body holds the reason.
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
        My-Logger "✗ Validation request was rejected synchronously:" "red"
        if ($respBody) {
            try { ($respBody | ConvertFrom-Json) | ConvertTo-Json -Depth 30 | Out-Host }
            catch { My-Logger $respBody "yellow" }
        }
        return $false
    }

    if (-not $valId) {
        My-Logger "✗ Validation did not return a task id; cannot poll." "red"
        return $false
    }

    My-Logger "Validation task id: $valId - polling until complete ..." "cyan"

    # Poll until executionStatus leaves IN_PROGRESS. Network-connectivity checks
    # (vMotion/vSAN/TEP pings to not-yet-configured nets) can take 15-20 min in a
    # nested lab due to ping timeouts, so allow a generous cap before giving up.
    #
    # Output is event-based: we only print when something actually changes (a check
    # finishes or a new one starts), so the log reads as a running list of steps
    # instead of repeating the same status every 15s. A heartbeat line is printed
    # occasionally so you can see it is still alive during the long network checks.
    $result = $null
    $pollMax = 100   # 100 * 15s = 25 min
    $pollNum = 0
    $prevStatus = @{}   # description -> last seen resultStatus
    do {
        Start-Sleep -Seconds 15
        $pollNum++
        try {
            $poll = Invoke-WebRequest -Uri "https://${EndpointIp}/v1/sddcs/validations/$valId" -Method GET -SkipCertificateCheck -TimeoutSec 60 -Headers (Get-VCFInstallerToken)
            $result = $poll.Content | ConvertFrom-Json

            $checks  = @($result.validationChecks)
            $total   = $checks.Count
            $done    = @($checks | Where-Object { $_.resultStatus -eq "SUCCEEDED" }).Count
            $failed  = @($checks | Where-Object { $_.resultStatus -eq "FAILED" }).Count
            $elapsed = "{0:mm\:ss}" -f ([timespan]::FromSeconds($pollNum * 15))

            # Emit a line only for checks whose status CHANGED since the last poll.
            $changed = $false
            foreach ($c in $checks) {
                $name = $c.description
                $now  = $c.resultStatus
                if ($prevStatus[$name] -ne $now) {
                    $changed = $true
                    switch ($now) {
                        "SUCCEEDED"   { My-Logger "  [$elapsed] ✓ $name  ($done/$total done)" "green" }
                        "FAILED"      { My-Logger "  [$elapsed] ✗ $name  FAILED" "red" }
                        "IN_PROGRESS" { My-Logger "  [$elapsed] → running: $name" "cyan" }
                        default       { }   # UNKNOWN/pending -> stay quiet
                    }
                    $prevStatus[$name] = $now
                }
            }
            # Heartbeat every ~2 min if nothing changed, so a long check still shows life.
            if (-not $changed -and ($pollNum % 8 -eq 0)) {
                $runNames = (@($checks | Where-Object { $_.resultStatus -eq "IN_PROGRESS" }) | ForEach-Object { $_.description }) -join ", "
                My-Logger "  [$elapsed] still working on: $runNames" "white"
            }
        } catch {
            My-Logger "Failed to poll validation task: $($_.Exception.Message)" "red"
            return $false
        }
        if ($pollNum -ge $pollMax) {
            My-Logger "Validation still IN_PROGRESS after $([int]($pollMax*15/60)) min - giving up polling. Check the installer UI / domainmanager log for the result." "yellow"
            return $false
        }
    } while ($result.executionStatus -eq "IN_PROGRESS")

    # Report. SUCCEEDED and WARNING both mean "passed" - WARNING just carries
    # non-blocking advisories (e.g. nested-lab vSAN HCL, core-count recommendation,
    # duplicate PTR records). Only a genuine FAILED check blocks bringup.
    if ($result.resultStatus -eq "SUCCEEDED") {
        My-Logger "✓ Validation SUCCEEDED - all checks passed." "green"
        return $true
    }

    if ($result.resultStatus -eq "WARNING") {
        My-Logger "" "white"
        My-Logger "✓ VALIDATION PASSED (with non-blocking warnings)" "green"
        My-Logger "  These advisories are expected in a nested lab and do NOT stop deployment." "green"
        My-Logger "" "white"

        # Friendly explanations for the warnings we know are benign in a nested lab.
        $known = @{
            "IP_RESOLVES_TO_MULTIPLE_FQDN"  = "Duplicate reverse-DNS (PTR) records - tidy up .vcf.local PTRs when convenient"
            "VSAN_ESA_HOST_HCL_COMPATIBLE_ERROR" = "Nested vNVMe disks are not on the HCL - expected; handled by disk-claim workaround"
            "NO_VSAN_ESA_CERTIFIED_DISKS"   = "No HCL-certified vSAN disks (nested storage) - expected in a lab"
            "CAPACITY_NUMBER_OF_CORES_VALIDATION" = "Fewer cores than the 110-core perf recommendation - fine for a lab"
        }

        foreach ($check in $result.validationChecks) {
            if ($check.resultStatus -eq "WARNING") {
                # Tally warnings in this check by errorCode so we show "x4" not 4 lines.
                $byCode = @{}
                foreach ($ne in @($check.errorResponse.nestedErrors)) {
                    $code = ($ne.errorCode -replace '\.warning$','')
                    if ($byCode.ContainsKey($code)) { $byCode[$code]++ } else { $byCode[$code] = 1 }
                }
                My-Logger "  ⚠ $($check.description)" "yellow"
                foreach ($code in $byCode.Keys) {
                    $count = $byCode[$code]
                    $hint  = if ($known.ContainsKey($code)) { $known[$code] } else { "(advisory)" }
                    My-Logger "      • $code x$count - $hint" "white"
                }
            }
        }
        My-Logger "" "white"
        My-Logger "Proceeding to bringup." "green"
        return $true
    }

    # Anything else (FAILED / UNKNOWN) is treated as a real failure - show full detail.
    My-Logger "✗ Validation resultStatus: $($result.resultStatus). Non-passing checks:" "red"
    foreach ($check in $result.validationChecks) {
        if ($check.resultStatus -ne "SUCCEEDED") {
            My-Logger "  --- $($check.description): $($check.resultStatus) ---" "yellow"
            if ($check.errorResponse) {
                ($check.errorResponse | ConvertTo-Json -Depth 30) | Out-Host
            }
        }
    }
    return $false
}

Function Get-VCFBundleStatus {
    param(
        [Parameter(Mandatory=$true)][String]$BundleId,
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    $headers = Get-VCFInstallerToken

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
                My-Logger "  ✓ Bundle $($bundleStatus.componentType) already downloaded, skipping..." "green"
                return $true
            } elseif ($status -in @("INPROGRESS", "SCHEDULED", "VALIDATING")) {
                My-Logger "  → Bundle $($bundleStatus.componentType) download already in progress ($status)..." "cyan"
                return $true
            }
        }
    } catch {
        My-Logger "  Could not check bundle status (will attempt download): $($_.Exception.Message)" "yellow"
    }

    # Proceed with download
    $headers = Get-VCFInstallerToken

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
            My-Logger "  ▶ Bundle download initiated: $($bundleStatus.componentType)" "cyan"
        } else {
            My-Logger "  ▶ Bundle download initiated: $BundleId" "cyan"
        }
        return $true

    } catch {
        $errorMsg = $_.Exception.Message

        # Parse error response if available
        if ($_.ErrorDetails.Message) {
            try {
                $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errorJson.errorCode -eq "BUNDLE_DOWNLOAD_ALREADY_DOWNLOADED") {
                    My-Logger "  ✓ Bundle $BundleId already downloaded" "green"
                    return $true
                } elseif ($errorJson.errorCode -match "BUNDLE_DOWNLOAD") {
                    My-Logger "  ℹ Bundle download status: $($errorJson.message)" "yellow"
                    return $true
                }
            } catch {
                # Not JSON, continue with original error
            }
        }

        My-Logger "  ✗ Failed to download bundle ${BundleId}: $errorMsg" "red"
        return $false
    }
}

Function Delete-VCFBundle {
    param(
        [Parameter(Mandatory=$true)][String]$BundleId,
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    $headers = Get-VCFInstallerToken

    try {
        $uri = "https://${EndpointIp}/v1/bundles/$BundleId"
        $method = "DELETE"

        if($Debug) {
            My-Logger "DEBUG: Deleting bundle $BundleId" "cyan"
        }

        # FIX: bumped from 5s.
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
        [Parameter(Mandatory=$true)][String]$ProductVersion
    )

    $headers = Get-VCFInstallerToken
    $maxRetries = 3
    $retryCount = @{}
    # Bundles that have exhausted their retries. Tracked separately because a
    # 404'd / deleted bundle disappears from the live download-status list, which
    # would otherwise make the loop think everything finished successfully.
    $permanentFailures = @{}

    My-Logger "`nMonitoring bundle download progress..." "cyan"

    while($true) {
        try {
            $uri = "https://${EndpointIp}/v1/bundles/download-status?releaseVersion=${ProductVersion}&imageType=INSTALL"
            $response = Invoke-WebRequest -Uri $uri -Method GET -SkipCertificateCheck -Headers $headers
            $bundles = ($response.Content | ConvertFrom-Json).elements

            $inProgress = $bundles | Where-Object { $_.downloadStatus -in @("INPROGRESS", "SCHEDULED", "VALIDATING") }
            $failed = $bundles | Where-Object { $_.downloadStatus -eq "FAILED" }
            $completed = $bundles | Where-Object { $_.downloadStatus -in @("DOWNLOADED", "SUCCESSFUL") }

            # Show summary
            My-Logger "  Bundle Status: $($completed.Count) completed | $($inProgress.Count) in progress | $($failed.Count) failed" "cyan"

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
                        My-Logger "    → $($bundle.componentType): $($bundle.downloadStatus) ($percentage%)" "yellow"
                    } else {
                        My-Logger "    → $($bundle.componentType): $($bundle.downloadStatus)" "yellow"
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
                        My-Logger "  ⟳ Retrying failed bundle: $($failedBundle.componentType) (attempt $($retryCount[$bundleKey])/$maxRetries)" "yellow"
                        Delete-VCFBundle -BundleId $failedBundle.bundleId -EndpointIp $EndpointIp
                        $retryOk = Download-VCFBundle -BundleId $failedBundle.bundleId -EndpointIp $EndpointIp
                        # A 404 (missing from the offline depot) fails instantly and
                        # returns $false. Record it now, because once deleted the bundle
                        # drops out of the status list and would otherwise look "done".
                        if (-not $retryOk) {
                            $permanentFailures[$bundleKey] = $failedBundle.componentType
                            My-Logger "  ✗ Bundle $($failedBundle.componentType) could not be downloaded (likely missing from depot - 404)" "red"
                        }
                    } else {
                        $permanentFailures[$bundleKey] = $failedBundle.componentType
                        My-Logger "  ✗ Bundle $($failedBundle.componentType) failed after $maxRetries retries" "red"
                    }
                }
            }

            # Check if all done.
            # A bundle is "settled" when it is no longer in progress AND is either
            # completed or recorded as a permanent failure. We must NOT treat a
            # bundle simply vanishing from the status list as success.
            if ($inProgress.Count -eq 0) {
                if ($permanentFailures.Count -gt 0) {
                    My-Logger "`n⚠ Bundle downloads finished with $($permanentFailures.Count) permanent failure(s):" "red"
                    $permanentFailures.GetEnumerator() | ForEach-Object {
                        My-Logger "    - $($_.Value)  [$($_.Key)]" "red"
                    }
                    My-Logger "  These bundles are missing from the depot. Re-populate the offline depot" "yellow"
                    My-Logger "  (VCF Download Tool) for ${ProductSKU} ${ProductVersion} before starting bring-up." "yellow"
                } else {
                    My-Logger "`n✓ All bundles downloaded successfully!" "green"
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

    $headers = Get-VCFInstallerToken

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

    # Build bundle map.
    # NOTE: a single component can expose MORE THAN ONE bundle id (e.g. VCENTER,
    # NSX_T_MANAGER, SDDC_MANAGER each return 2). Force the result into an array
    # with @(...) so the value is always a collection of strings, never a bare
    # string that later gets coerced incorrectly.
    $bundle = @{}
    foreach ($component in $components) {
        $bundle[$component.name] = @($component.versions.artifacts.bundles.id) | Where-Object { $_ }
    }

    # Download each bundle (with idempotency).
    # Iterate every id for the component - passing an array to the [String]
    # -BundleId parameter is what previously threw the type-conversion error.
    My-Logger "`nInitiating bundle downloads..." "cyan"
    $downloadResults = @{}
    foreach ($entry in $bundle.GetEnumerator()) {
        foreach ($bundleId in $entry.Value) {
            My-Logger "Processing: $($entry.Key) [$bundleId]" "cyan"
            $downloadResults["$($entry.Key):$bundleId"] = Download-VCFBundle -BundleId $bundleId -EndpointIp $EndpointIp
        }
    }

    # Wait for all downloads to complete
    Wait-VCFBundleDownloads -EndpointIp $EndpointIp -ProductSKU $VCFInstallerProductSKU -ProductVersion $VCFInstallerProductVersion
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
            # 5s is fine here: this is only a readiness probe and we loop with a 30s sleep.
            $requests = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -TimeoutSec 5
            if($requests.StatusCode -eq 200) {
                My-Logger "  ✓ ${EndpointName} API is now ready!" "green"
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

Function Connect-VCFDepot {
    param(
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    $headers = Get-VCFInstallerToken

    try {
        if($VCFInstallerSoftwareDepot -eq "offline") {
            $payload = @{
                "offlineAccount" = [Ordered]@{
                    "username" = $VCFInstallerDepotUsername
                    "password" = $VCFInstallerDepotPassword
                }
                "depotConfiguration" = @{
                    "isOfflineDepot" = $true
                    "hostname" = $VCFInstallerDepotHost
                    "port" = $VCFInstallerDepotPort
                }
            }
        } else {
            $payload = @{
                "vmwareAccount" = [Ordered]@{
                    "downloadToken" = $VCFInstallerDepotToken
                }
            }
        }

        $uri = "https://${EndpointIp}/v1/system/settings/depot"
        $method = "PUT"
        $body = $payload | ConvertTo-Json

        if($Debug) {
            My-Logger "DEBUG: Method: $method" "cyan"
            My-Logger "DEBUG: Uri: $uri" "cyan"
        }

        # FIX: bumped from 5s. For an online depot this PUT reaches out to the
        # Broadcom depot and validates the token; that round-trip does not reliably
        # complete in 5s, and a cancelled connect leaves "credentials not configured".
        $requests = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -TimeoutSec 120 -Headers $headers -Body $body -ErrorAction Stop
    } catch {
        My-Logger "Failed to connect to VCF Software Depot" "red"
        Write-Error "`n$($_.Exception.Message)`n"
        return
    }

    if($requests.Statuscode -eq 202) {
        My-Logger "✓ Successfully connected to VCF Software Depot" "green"
    } else {
        My-Logger "Unexpected response connecting to VCF Software Depot (Status: $($requests.StatusCode))" "yellow"
    }
}

Function Sync-VCFDepot {
    param(
        [Parameter(Mandatory=$true)][String]$EndpointIp
    )

    $headers = Get-VCFInstallerToken

    try {
        $uri = "https://${EndpointIp}/v1/system/settings/depot/depot-sync-info"
        $method = "PATCH"

        if($Debug) {
            My-Logger "DEBUG: Initiating depot sync" "cyan"
        }

        # FIX: bumped from 5s.
        $requests = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -TimeoutSec 60 -Headers $headers
    } catch {
        My-Logger "Failed to sync VCF Software Depot" "red"
        Write-Error "`n$($_.Exception.Message)`n"
        return
    }

    if($requests.Statuscode -eq 202) {
        My-Logger "✓ VCF Software Depot sync initiated" "green"
    } else {
        My-Logger "Unexpected response starting depot sync (Status: $($requests.StatusCode))" "yellow"
        return
    }

    My-Logger "Waiting for depot sync to complete..." "cyan"

    while(1) {
        try {
            $uri = "https://${EndpointIp}/v1/system/settings/depot/depot-sync-info"
            $method = "GET"

            # FIX: bumped from 5s.
            $requests = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -TimeoutSec 60 -Headers $headers
            if($requests.StatusCode -eq 200) {
                $syncInfo = ($requests.Content | ConvertFrom-Json)
                $syncStatus = $syncInfo.syncStatus

                if($syncStatus -eq "SYNCED") {
                    Write-Host ""  # New line
                    My-Logger "  ✓ VCF Software Depot synced successfully" "green"
                    break
                } elseif($syncStatus -eq "SYNC_FAILED" -or $syncStatus -eq "FAILED") {
                    Write-Host ""  # New line
                    My-Logger "  ✗ VCF Software Depot sync FAILED (status: $syncStatus)" "red"
                    if($syncInfo.errorMessage) {
                        My-Logger "    Reason: $($syncInfo.errorMessage)" "red"
                    }
                    My-Logger "    Check /var/log/vmware/vcf/lcm/lcm-debug.log on the appliance for detail." "yellow"
                    # Terminal state - stop polling. Returning lets the caller decide;
                    # the bundle-download stage will surface any missing artifacts.
                    return
                } else {
                    Write-Host -NoNewline "`r"
                    Write-Host -NoNewline -ForegroundColor Yellow "  Depot sync status: $syncStatus (checking again in 30s)..."
                    sleep 30
                }
            }
        }
        catch {
            My-Logger "Error checking sync status, will retry..." "yellow"
            sleep 30
        }
    }
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

        # Skip deployment if this Nested ESXi VM already exists
        if (Get-VM -Server $viConnection -Name $VMName -ErrorAction SilentlyContinue) {
            My-Logger "[$jobCounter/$($HostnameToIPs.Count)] ⊘ $VMName already exists, skipping deployment" "yellow"
            $deploymentResults[$VMName] = $true
            return   # inside ForEach-Object, 'return' just moves to the next host
        }

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

                # Safety net: skip (don't fail) if the VM already exists
                $existingVM = Get-VM -Server $viConn -Name $config.VMName -ErrorAction SilentlyContinue
                if ($existingVM) {
                    $result.Success  = $true
                    $result.Skipped  = $true
                    $result.EndTime  = Get-Date
                    $result.Duration = 0
                    return $result
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

if($preCheck -eq 1) {
    if($PSVersionTable.PSEdition -ne "Core") {
        Write-Host -ForegroundColor Red "`tPowerShell Core was not detected, please install that before continuing ... `n"
        exit
    }

    if(!(Test-Path $NestedESXiApplianceOVA)) {
        Write-Host -ForegroundColor Red "`nUnable to find $NestedESXiApplianceOVA ...`n"
        exit
    }

    if(!(Test-Path $VCFInstallerOVA)) {
        Write-Host -ForegroundColor Red "`nUnable to find $VCFInstallerOVA ...`n"
        exit
    }

    if($VCFInstallerSoftwareDepot -eq "offline") {
        try {
            (new-object System.Net.Sockets.TcpClient).Connect(${VCFInstallerDepotHost},${VCFInstallerDepotPort})
        } catch {
            Write-Host -ForegroundColor Red "`nUnable to reach VCF offline depot ${VCFInstallerDepotHost}:${VCFInstallerDepotPort} ...`n"
            exit
        }
    }
}

if($confirmDeployment -eq 1) {
    Write-Host -ForegroundColor Magenta "`nPlease confirm the following configuration will be deployed:`n"

    Write-Host -ForegroundColor Yellow "---- VCF Automated 9 Lab Deployment Configuration ---- "
    Write-Host -NoNewline -ForegroundColor Green "Generated Deployment ID: "
    Write-Host -ForegroundColor White $random_string
    Write-Host -NoNewline -ForegroundColor Green "Configuration Variables File: "
    Write-Host -ForegroundColor White $EnvConfigFile
    Write-Host -NoNewline -ForegroundColor Green "Nested ESXi Image Path: "
    Write-Host -ForegroundColor White $NestedESXiApplianceOVA
    Write-Host -NoNewline -ForegroundColor Green "VCF Installer Image Path: "
    Write-Host -ForegroundColor White $VCFInstallerOVA

    Write-Host -ForegroundColor Yellow "`n---- vCenter Server Deployment Target Configuration ----"
    Write-Host -NoNewline -ForegroundColor Green "vCenter Server Address: "
    Write-Host -ForegroundColor White $VIServer
    Write-Host -NoNewline -ForegroundColor Green "VM Network: "
    Write-Host -ForegroundColor White $VMNetwork

    Write-Host -NoNewline -ForegroundColor Green "VM Storage: "
    Write-Host -ForegroundColor White $VMDatastore
    Write-Host -NoNewline -ForegroundColor Green "VM Cluster: "
    Write-Host -ForegroundColor White $VMCluster
    Write-Host -NoNewline -ForegroundColor Green "VM vApp: "
    Write-Host -ForegroundColor White $VAppName

    Write-Host -ForegroundColor Yellow "`n---- VCF Installer Configuration ----"
    Write-Host -NoNewline -ForegroundColor Green "Software SKU: "
    Write-Host -ForegroundColor White $VCFInstallerProductSKU
    Write-Host -NoNewline -ForegroundColor Green "Software Version: "
    Write-Host -ForegroundColor White $VCFInstallerProductVersion
    Write-Host -NoNewline -ForegroundColor Green "Hostname: "
    Write-Host -ForegroundColor White $VCFInstallerVMName
    Write-Host -NoNewline -ForegroundColor Green "IP Address: "
    Write-Host -ForegroundColor White $VCFInstallerIP

    if($deployNestedESXiVMsForMgmt -eq 1) {
        Write-Host -ForegroundColor Yellow "`n---- vESXi Configuration for $VCFInstallerProductSKU Management Domain ----"
        Write-Host -NoNewline -ForegroundColor Green "# of Nested ESXi VMs: "
        Write-Host -ForegroundColor White $NestedESXiHostnameToIPsForManagementDomain.count
        Write-Host -NoNewline -ForegroundColor Green "IP Address(es): "
        Write-Host -ForegroundColor White ($NestedESXiHostnameToIPsForManagementDomain.Values -join ", ")
        Write-Host -NoNewline -ForegroundColor Green "vCPU: "
        Write-Host -ForegroundColor White $NestedESXiMGMTvCPU
        Write-Host -NoNewline -ForegroundColor Green "vMEM: "
        Write-Host -ForegroundColor White "$NestedESXiMGMTvMEM GB"
        Write-Host -NoNewline -ForegroundColor Green "Boot Disk: "
        Write-Host -ForegroundColor White "$NestedESXiMGMTBootDisk GB"
        Write-Host -NoNewline -ForegroundColor Green "Capacity VMDK: "
        Write-Host -ForegroundColor White "$NestedESXiMGMTCapacityvDisk GB"
    }

    if($deployNestedESXiVMsForWLD -eq 1) {
        Write-Host -ForegroundColor Yellow "`n---- vESXi Configuration for $VCFInstallerProductSKU Workload Domain ----"
        Write-Host -NoNewline -ForegroundColor Green "# of Nested ESXi VMs: "
        Write-Host -ForegroundColor White $NestedESXiHostnameToIPsForWorkloadDomain.count
        Write-Host -NoNewline -ForegroundColor Green "IP Address(es): "
        Write-Host -ForegroundColor White ($NestedESXiHostnameToIPsForWorkloadDomain.Values -join ", ")
        Write-Host -NoNewline -ForegroundColor Green "vCPU: "
        Write-Host -ForegroundColor White $NestedESXiWLDvCPU
        Write-Host -NoNewline -ForegroundColor Green "vMEM: "
        Write-Host -ForegroundColor White "$NestedESXiWLDvMEM GB"
        Write-Host -NoNewline -ForegroundColor Green "Boot Disk: "
        Write-Host -ForegroundColor White "$NestedESXiWLDBootDisk GB"
        Write-Host -NoNewline -ForegroundColor Green "Capacity VMDK: "
        Write-Host -ForegroundColor White "$NestedESXiWLDCapacityvDisk GB"
    }

    Write-Host -NoNewline -ForegroundColor Green "`nNetmask: "
    Write-Host -ForegroundColor White $VMNetmask
    Write-Host -NoNewline -ForegroundColor Green "MGMT Gateway: "
    Write-Host -ForegroundColor White $ESXMGMTGateway
    Write-Host -NoNewline -ForegroundColor Green "WLD Gateway: "
    Write-Host -ForegroundColor White $ESXWLDGateway
    Write-Host -NoNewline -ForegroundColor Green "DNS: "
    Write-Host -ForegroundColor White $VMDNS
    Write-Host -NoNewline -ForegroundColor Green "NTP: "
    Write-Host -ForegroundColor White $VMNTP
    Write-Host -NoNewline -ForegroundColor Green "Syslog: "
    Write-Host -ForegroundColor White $VMSyslog

    Write-Host -ForegroundColor Magenta "`nWould you like to proceed with this deployment?`n"
    $answer = Read-Host -Prompt "Do you accept (Y or N)"
    if($answer -ne "Y" -and $answer -ne "y") {
        exit
    }
    Clear-Host
}

if($deployNestedESXiVMsForMgmt -eq 1 -or $deployNestedESXiVMsForWLD -eq 1 -or $updateVCFInstallerConfig -eq 1 -or $deployVCFInstaller -eq 1 -or $moveVMsIntovApp -eq 1) {
    My-Logger "Connecting to Management vCenter Server $VIServer ..."
    $viConnection = Connect-VIServer $VIServer -User $VIUsername -Password $VIPassword -WarningAction SilentlyContinue

    $datastore = Get-Datastore -Server $viConnection -Name $VMDatastore | Select -First 1
    $cluster = Get-Cluster -Server $viConnection -Name $VMCluster
    $vmhost = $cluster | Get-VMHost | Get-Random -Count 1
}

if($deployVCFInstaller -eq 1) {
    $ovfconfig = Get-OvfConfiguration $VCFInstallerOVA

    $networkMapLabel = ($ovfconfig.ToHashTable().keys | where {$_ -Match "NetworkMapping"}).replace("NetworkMapping.","").replace("-","_").replace(" ","_")
    $ovfconfig.NetworkMapping.$networkMapLabel.value = $VMVCFInstNetwork
    $ovfconfig.Common.vami.hostname.value = $VCFInstallerFQDN
    $ovfconfig.vami.SDDC_Manager.ip0.value = $VCFInstallerIP
    $ovfconfig.vami.SDDC_Manager.netmask0.value = $VMNetmask
    $ovfconfig.vami.SDDC_Manager.gateway.value = $ESXMGMTGateway
    $ovfconfig.vami.SDDC_Manager.DNS.value = $VMDNS
    $ovfconfig.vami.SDDC_Manager.domain.value = $VMDomain
    $ovfconfig.vami.SDDC_Manager.searchpath.value = $VMDomain
    $ovfconfig.common.guestinfo.ntp.value = $VMNTP
    $ovfconfig.Common.LOCAL_USER_PASSWORD.value = $VCFInstallerAdminPassword
    $ovfconfig.Common.ROOT_PASSWORD.value = $VCFInstallerRootPassword

    My-Logger "Deploying VCF Installer VM $VCFInstallerVMName ..."
    try {
        $vm = Import-VApp -Server $viConnection -Source $VCFInstallerOVA -OvfConfiguration $ovfconfig -Name $VCFInstallerVMName -Location $VMCluster -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin | Out-Null
        $vm = Get-VM -Server $viConnection -Name $VCFInstallerVMName
    } catch {
        My-Logger "Failed to deploy $VCFInstallerVMName ..." "red"
        Disconnect-VIServer -Server $viConnection -Confirm:$false
        exit
    }

    My-Logger "Powering On $VCFInstallerVMName ..."
    $vm | Start-Vm -RunAsync | Out-Null
}

if($updateVCFInstallerConfig -eq 1) {
    Verify-VCFAPIEndpoint -EndpointName "VCF Installer" -EndpointIp $VCFInstallerFQDN
    $vcfVM = Get-VM -Server $viConnection $VCFInstallerVMName
    $scriptName = "vcfIntScript.sh"
    $script = @"
#!/bin/bash
# Generated by DS VCF 9.1 Automated Deployment Lab Script
"@

    # Helper: append a property line only if it isn't already present
    function Add-PropLine($file, $line) {
        return "grep -qxF '$line' $file || echo '$line' >> $file`n"
    }

    # --- VCF Installer Workarounds -> application.properties ---
    $vcfDomainConfigFile = "/etc/vmware/vcf/domainmanager/application.properties"
    $script += Add-PropLine $vcfDomainConfigFile "validation.disable.network.connectivity.check=true"
    $script += Add-PropLine $vcfDomainConfigFile "nsxt.mtu.validation.skip=true"
    $script += Add-PropLine $vcfDomainConfigFile "vsan.esa.sddc.managed.disk.claim=true"

    # --- Feature properties -> feature.properties ---
    if($VCFFeatureProperties -ne $null) {
        $vcfFeatureConfigFile = "/home/vcf/feature.properties"
        $VCFFeatureProperties.GetEnumerator() | Foreach-Object {
            $script += Add-PropLine $vcfFeatureConfigFile "$($_.Key)=$($_.Value)"
        }
        $script += "chmod 755 ${vcfFeatureConfigFile}`n"
    }

    # --- Offline software depot -> LCM config ---
    if($VCFInstallerSoftwareDepot -eq "offline") {
        $vcfLcmConfigFile = "/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties"
        if($VCFInstallerDepotHttps -eq $false) {
            $script += "grep -qF 'lcm.depot.adapter.httpsEnabled=false' ${vcfLcmConfigFile} || sed -i -e `"/lcm.depot.adapter.port=.*/a lcm.depot.adapter.httpsEnabled=false`" ${vcfLcmConfigFile}`n"
        }
    }

    # --- Restart services (must come last, after all config edits) ---
    $script += "echo 'y' | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh`n"
    $script += "systemctl restart lcm`n"

    $script | Set-Content -NoNewline -Encoding UTF8 $scriptName
    My-Logger "Transfering configuration shell script ($scriptName) to VCF Installer VM ..."
    Copy-VMGuestFile -Server $viConnection -VM $vcfVM -GuestUser "root" -GuestPassword $VCFInstallerRootPassword -LocalToGuest -Source ${scriptName} -Destination /tmp/${scriptName} -Force | Out-Null
    My-Logger "Running configuration shell script on VCF Installer VM ..."
    Invoke-VMScript -ScriptText "bash /tmp/${scriptName}" -VM $vcfVM -GuestUser "root" -GuestPassword $VCFInstallerRootPassword  | Out-Null
    Start-Sleep -Seconds 120
}

if($deployNestedESXiVMsForMgmt -eq 1) {
    $mgmtResults = Deploy-NestedESXiVMsParallel `
        -HostnameToIPs $NestedESXiHostnameToIPsForManagementDomain `
        -DomainType "MGMT" `
        -OVAPath $NestedESXiApplianceOVA `
        -NetworkConfig @{
            Netmask = $VMNetmask
            Gateway = $ESXMGMTGateway
            VLAN = $ESXMGMTVLAN
            DNS = $VMDNS
            Domain = $VMDomain
            NTP = $VMNTP
            Syslog = $VMSyslog
            Password = $VMPassword
        } `
        -ResourceConfig @{
            vCPU = $NestedESXiMGMTvCPU
            vMEM = $NestedESXiMGMTvMEM
            BootDisk = $NestedESXiMGMTBootDisk
            CapacityDisk = $NestedESXiMGMTCapacityvDisk
        } `
        -vCenterConfig @{
            Server = $VIServer
            Username = $VIUsername
            Password = $VIPassword
            Datastore = $VMDatastore
            Cluster = $VMCluster
            Network = $VMNetwork
        } `
        -MaxConcurrent 4

    $mgmtFailures = ($mgmtResults.Values | Where-Object { -not $_ }).Count
    if ($mgmtFailures -gt 0) {
        My-Logger "WARNING: $mgmtFailures Management ESXi host(s) failed to deploy" "yellow"
        $answer = Read-Host -Prompt "Continue anyway? (Y/N)"
        if ($answer -ne "Y" -and $answer -ne "y") {
            Disconnect-VIServer -Server $viConnection -Confirm:$false
            exit 1
        }
    }
}

if($deployNestedESXiVMsForWLD -eq 1) {
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
        -MaxConcurrent 4

    $wldFailures = ($wldResults.Values | Where-Object { -not $_ }).Count
    if ($wldFailures -gt 0) {
        My-Logger "WARNING: $wldFailures Workload ESXi host(s) failed to deploy" "yellow"
        $answer = Read-Host -Prompt "Continue anyway? (Y/N)"
        if ($answer -ne "Y" -and $answer -ne "y") {
            Disconnect-VIServer -Server $viConnection -Confirm:$false
            exit 1
        }
    }
}

if($moveVMsIntovApp -eq 1) {
    # Check whether DRS is enabled as that is required to create vApp
    if((Get-Cluster -Server $viConnection $cluster).DrsEnabled) {
        My-Logger "Creating vApp $VAppName ..."
        $rp = Get-ResourcePool -Name Resources -Location $cluster
        $VApp = New-VApp -Name $VAppName -Server $viConnection -Location $cluster

        if(-Not (Get-Folder $VMFolder -ErrorAction Ignore)) {
            My-Logger "Creating VM Folder $VMFolder ..."
            $folder = New-Folder -Name $VMFolder -Server $viConnection -Location (Get-Datacenter $VMDatacenter | Get-Folder vm)
        }

        if($deployNestedESXiVMsForMgmt -eq 1) {
            My-Logger "Moving Nested Management ESXi VMs into $VAppName vApp ..."
            $NestedESXiHostnameToIPsForManagementDomain.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
                $vm = Get-VM -Name $_.Key -Server $viConnection -Location $cluster | where{$_.ResourcePool.Id -eq $rp.Id}
                if ($vm) {
                    Move-VM -VM $vm -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                }
            }
        }

        if($deployNestedESXiVMsForWLD -eq 1) {
            My-Logger "Moving Nested Workload ESXi VMs into $VAppName vApp ..."
            $NestedESXiHostnameToIPsForWorkloadDomain.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
                $vm = Get-VM -Name $_.Key -Server $viConnection -Location $cluster | where{$_.ResourcePool.Id -eq $rp.Id}
                if ($vm) {
                    Move-VM -VM $vm -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                }
            }
        }

        if($deployVCFInstaller -eq 1) {
            $vcfInstallerVM = Get-VM -Name $VCFInstallerVMName -Server $viConnection -Location $cluster | where{$_.ResourcePool.Id -eq $rp.Id}
            if ($vcfInstallerVM) {
                My-Logger "Moving $VCFInstallerVMName into $VAppName vApp ..."
                Move-VM -VM $vcfInstallerVM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            }
        }

        My-Logger "Moving $VAppName to VM Folder $VMFolder ..."
        Move-VApp -Server $viConnection $VAppName -Destination (Get-Folder -Server $viConnection $VMFolder) | Out-File -Append -LiteralPath $verboseLogFile
    } else {
        My-Logger "vApp $VAppName will NOT be created as DRS is NOT enabled on vSphere Cluster ${cluster} ..." "yellow"
    }
}

if($generateMgmtJson -eq 1) {
    $esxivMotionNetwork = $NestedMGMTESXivMotionNetworkCidr.split("/")[0]
    $esxivMotionNetworkOctects = $esxivMotionNetwork.split(".")
    $esxivMotionGateway = ($esxivMotionNetworkOctects[0..2] -join '.') + ".1"
    $esxivMotionStart = ($esxivMotionNetworkOctects[0..2] -join '.') + ".101"
    $esxivMotionEnd = ($esxivMotionNetworkOctects[0..2] -join '.') + ".118"

    $esxivSANNetwork = $NestedMGMTESXivSANNetworkCidr.split("/")[0]
    $esxivSANNetworkOctects = $esxivSANNetwork.split(".")
    $esxivSANGateway = ($esxivSANNetworkOctects[0..2] -join '.') + ".1"
    $esxivSANStart = ($esxivSANNetworkOctects[0..2] -join '.') + ".101"
    $esxivSANEnd = ($esxivSANNetworkOctects[0..2] -join '.') + ".118"

    $esxiNSXTepNetwork = $NestedMGMTESXiNSXTepNetworkCidr.split("/")[0]
    $esxiNSXTepNetworkOctects = $esxiNSXTepNetwork.split(".")
    $esxiNSXTepGateway = ($esxiNSXTepNetworkOctects[0..2] -join '.') + ".1"
    $esxiNSXTepStart = ($esxiNSXTepNetworkOctects[0..2] -join '.') + ".101"
    $esxiNSXTepEnd = ($esxiNSXTepNetworkOctects[0..2] -join '.') + ".118"

    $hostSpecs = @()
    $count = 1
    $NestedESXiHostnameToIPsForManagementDomain.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
        $VMName = $_.Key

        $hostSpec = [ordered]@{
            "hostname" = $VMName
            "credentials" = [ordered]@{
                "username" = "root"
                "password" = $VMPassword
            }
        }
        $hostSpecs+=$hostSpec
        $count++
    }

    $vcfConfig = [ordered]@{
        "sddcId" = $DeploymentId
        "vcfInstanceName" = $DeploymentInstanceName
        "workflowType" = $VCFInstallerProductSKU
        "version" = $VCFInstallerProductVersion
        "ceipEnabled" = $CEIPEnabled
        "fipsEnabled" = $FIPSEnabled
        "skipEsxThumbprintValidation" = $true
        "skipGatewayPingValidation" = $true
    }

    if($VCFInstallerProductSKU -eq "VCF"){
        $sddcmSpec = [ordered]@{
            "rootUserCredentials" = [ordered]@{
                "username" = "root"
                "password" = $SddcManagerRootPassword
            }
            "secondUserCredentials" = [ordered]@{
                "username" = "vcf"
                "password" = $SddcManagerVcfPassword
            }
            "hostname" = $SddcManagerHostname
            "useExistingDeployment" = $false
            "rootPassword" = $SddcManagerRootPassword
            "sshPassword" = $SddcManagerSSHPassword
            "localUserPassword" = $SddcManagerLocalPassword
        }
        $vcfConfig.Add("sddcManagerSpec",$sddcmSpec)
    }

        $dnsSpec = [ordered]@{
            "nameservers" = @($VMDNS)
            "subdomain" = $VMDomain
        }
        $ntpSpec = @($VMNTP)
        $vcSpec = [ordered]@{
            "vcenterHostname" = $VCSAName
            "rootVcenterPassword" = $VCSARootPassword
            "vmSize" = $VCSASize
            "storageSize" = ""
            "adminUserSsoPassword" = $VCSASSOPassword
            "ssoDomain" = "vsphere.local"
            "useExistingDeployment" = $false
        }
        $hostSpec = $hostSpecs
        $clusterSpec = [ordered]@{
            "clusterName" = $VCSAClusterName
            "datacenterName" = $VCSADatacenterName
            "clusterEvcMode" = ""
            "clusterImageEnabled" = $VCSAEnableVCLM
        }
        $dsSpec = [ordered]@{
            "vsanSpec" = [ordered] @{
                "failuresToTolerate" = $VSANFTT
                "vsanDedup" = $VSANDedupe
                "esaConfig" = @{
                    "enabled" = $VSANESAEnabled
                }
                "datastoreName" = $VSANDatastoreName
            }
        }
        $vcfConfig.Add("dnsSpec",$dnsSpec)
        $vcfConfig.Add("ntpServers",$ntpSpec)
        $vcfConfig.Add("vcenterSpec",$vcSpec)
        $vcfConfig.Add("hostSpecs",$hostSpec)
        $vcfConfig.Add("clusterSpec",$clusterSpec)
        $vcfConfig.Add("datastoreSpec",$dsSpec)

    if($VCFInstallerProductSKU -eq "VCF"){
        $nsxSpec = [ordered]@{
            "nsxtManagerSize" = $NSXManagerSize
            "nsxtManagers" = @(
                @{"hostname" = $NSXManagerNodeHostname}
            )
            "vipFqdn" = $NSXManagerVIPHostname
            "useExistingDeployment" = $false
            "nsxtAdminPassword" = $NSXAdminPassword
            "nsxtAuditPassword" = $NSXAuditPassword
            "rootNsxtManagerPassword" = $NSXRootPassword
            "skipNsxOverlayOverManagementNetwork" = $true
            "ipAddressPoolSpec" = [ordered]@{
                "name" = "tep01"
                "description" = "ESXi Host Overlay TEP IP Pool"
                "subnets" = @(
                    @{
                        "cidr" = $NestedMGMTESXiNSXTepNetworkCidr
                        "gateway" = $esxiNSXTepGateway
                        "ipAddressPoolRanges" = @(@{"start" = $esxiNSXTepStart;"end" = $esxiNSXTepEnd})
                    }
                )
            }
            "transportVlanId" = "104"
        }

        $vcfConfig.Add("nsxtSpec",$nsxSpec)
    }

        $opsSpec = [ordered]@{
            "nodes" = @(
                @{
                    "hostname" = $VCFOperationsHostname
                    "rootUserPassword" = $VCFOperationsRootPassword
                    "type" = "master"
                }
            )
            "adminUserPassword" = $VCFOperationsAdminPassword
            "applianceSize" = $VCFOperationsSize
            "useExistingDeployment" = $false
            "loadBalancerFqdn" = ""
        }
        $vcfConfig.Add("vcfOperationsSpec",$opsSpec)

    # --- VCF 9.1.0.0 required service-runtime / license / LCM specs ---
    # 9.1.0.0 replaced the old vcfOperationsFleetManagementSpec model with a
    # VCF Services Platform (VSP) cluster plus discrete LCM / license / identity
    # specs. The installer's Deployment Specification check rejects the spec
    # ("License Server must be present", "VCF service runtime ... must be present")
    # unless these are included. Built for all SKUs; gated additions below stay
    # inside the VCF-only block.
    # Expand the start/end range into an explicit address list.
    # 9.1.0.0 validation accepts the "addresses" pool format (the format used in
    # Broadcom's own working VCFMS payloads); the "ipRange" format was being
    # rejected by the QUICK_START_VALIDATION_FAILED IPv4-pool check. Same IPs,
    # just enumerated. Assumes start/end share the first three octets (a /24-style
    # contiguous range), which matches the management network layout.
    $vspPoolStartOctet = [int]($VCFManagementServicesIPStartRange.Split('.')[-1])
    $vspPoolEndOctet   = [int]($VCFManagementServicesIPEndRange.Split('.')[-1])
    $vspPoolPrefix     = ($VCFManagementServicesIPStartRange.Split('.')[0..2] -join '.')
    $vspPoolAddresses  = @($vspPoolStartOctet..$vspPoolEndOctet | ForEach-Object { "$vspPoolPrefix.$_" })

    # Default VSP cluster name if the config does not define one.
    if (-not $VCFManagementServicesClusterName) {
        $VCFManagementServicesClusterName = "$($DeploymentId)-vmsp-01"
    }

    # Pool format selection. The VSP IPv4-pool format was never the cause of
    # VSP_IPV4_POOL_TOO_SMALL (that was the VCF Automation ipPool needing >=5 IPs).
    # Default to "ipRange" - the simplest form, matching Broadcom's reference spec
    # and William Lam's working script - rather than the cidr+excludedAddresses
    # construction we used while diagnosing. Set $VCFManagementServicesPoolFormat
    # in config to "cidr", "ipRange", or "addresses" to switch.
    if (-not $VCFManagementServicesPoolFormat) {
        $VCFManagementServicesPoolFormat = "ipRange"
    }

    switch ($VCFManagementServicesPoolFormat) {
        "cidr" {
            # Use an explicit CIDR if the config provides one; otherwise fall back
            # to the /24 the pool lives in and exclude everything outside the
            # start..end range so only the intended IPs are consumable.
            if ($VCFManagementServicesPoolCidr) {
                $vspIpv4Pool = [ordered]@{ "cidr" = $VCFManagementServicesPoolCidr }
            } else {
                $cidr = "$vspPoolPrefix.0/24"
                # exclude .0/.1(gw)/.255 and any host octet outside the pool range
                $excluded = @()
                foreach ($o in 0..255) {
                    if ($o -lt $vspPoolStartOctet -or $o -gt $vspPoolEndOctet) {
                        if ($o -ne 0 -and $o -ne 255) { $excluded += "$vspPoolPrefix.$o" }
                    }
                }
                $vspIpv4Pool = [ordered]@{
                    "cidr"              = $cidr
                    "excludedAddresses" = $excluded
                }
            }
        }
        "ipRange" {
            $vspIpv4Pool = [ordered]@{
                "ipRange" = [ordered]@{
                    "startIpAddress" = $VCFManagementServicesIPStartRange
                    "endIpAddress"   = $VCFManagementServicesIPEndRange
                }
            }
        }
        default {
            $vspIpv4Pool = [ordered]@{ "addresses" = $vspPoolAddresses }
        }
    }

    $vspClusterSpec = [ordered]@{
        "platformFqdn"            = $VCFManagementServicesRuntimeHostname
        "instanceFqdn"            = $VCFManagementServicesInstanceHostname
        "fleetFqdn"               = $VCFManagementServicesFleetHostname
        "systemUserPassword"      = $VCFManagementServicesSystemPassword
        # Per the installer's own vcf-installer-openapi.json, SddcVspClusterSpec has
        # NO "type" and NO "name" field - both were tested and are not in the schema.
        # The network binding that makes the consumption-pool count work lives in
        # vcfManagementComponentsInfrastructureSpec (added at top level below), NOT here.
        "size"                    = $VCFManagementServicesSize
        "internalClusterCidrIpv4" = $VCFManagementServicesInternalClusterCidrIpv4
        "ipv4Pool"                = $vspIpv4Pool
    }

    # vcfManagementComponentsInfrastructureSpec: binds the VSP/VCFMS pool to a
    # network. Confirmed present in the installer's vcf-installer-openapi.json. The
    # inner VcfManagementComponentsNetworkSpec requires networkName, gateway, subnetMask.
    #
    # Region key: the schema exposes BOTH "localRegionNetwork" and "xRegionNetwork".
    # A documented working separate-VLAN VSP deployment used "xRegionNetwork", so
    # that is the default here. Override $VCFManagementServicesRegionKey to
    # "localRegionNetwork", "xRegionNetwork", or "both" to test alternatives.
    if (-not $VCFManagementServicesNetworkName) { $VCFManagementServicesNetworkName = "VM_MANAGEMENT" }
    if (-not $VCFManagementServicesGateway)     { $VCFManagementServicesGateway     = "$vspPoolPrefix.1" }
    if (-not $VCFManagementServicesSubnetMask)  { $VCFManagementServicesSubnetMask  = "255.255.255.0" }
    if (-not $VCFManagementServicesRegionKey)   { $VCFManagementServicesRegionKey   = "xRegionNetwork" }

    $vcfMgmtNetBlock = [ordered]@{
        "networkName" = $VCFManagementServicesNetworkName
        "gateway"     = $VCFManagementServicesGateway
        "subnetMask"  = $VCFManagementServicesSubnetMask
    }

    $vcfMgmtInfraSpec = [ordered]@{}
    switch ($VCFManagementServicesRegionKey) {
        "localRegionNetwork" { $vcfMgmtInfraSpec["localRegionNetwork"] = $vcfMgmtNetBlock }
        "both" {
            $vcfMgmtInfraSpec["localRegionNetwork"] = $vcfMgmtNetBlock
            $vcfMgmtInfraSpec["xRegionNetwork"]     = $vcfMgmtNetBlock
        }
        default { $vcfMgmtInfraSpec["xRegionNetwork"] = $vcfMgmtNetBlock }
    }
    $sddcLcmSpec       = [ordered]@{ "hostname" = $VCFManagementServicesInstanceHostname }
    $fleetLcmSpec      = [ordered]@{ "hostname" = $VCFManagementServicesFleetHostname }
    $licenseServerSpec = [ordered]@{ "hostname" = $VCFLicenseServerHostname }

    if($VCFInstallerProductSKU -eq "VCF") {
        $vidbSpec = [ordered]@{
            "hostname" = $VCFManagementServicesIdentityHostname
        }
        $opsCollectorSpec = [ordered]@{
            "hostname" = $VCFOperationsCollectorHostname
            "applicationSize" = $VCFOperationsCollectorSize
            "rootUserPassword" = $VCFOperationsCollectorRootPassword
            "useExistingDeployment" = $false
        }
        # GUARD: VCF Automation requires an ipPool of at least 5 addresses. This was
        # the actual cause of the long VSP_IPV4_POOL_TOO_SMALL chase - the error text
        # says "VCF Management Services ... type consumption ... at least 5 addresses",
        # but it is the vcfAutomationSpec.ipPool that is counted, not vspClusterSpec.
        # Stop early with a clear message rather than failing opaque validation later.
        $autoPoolCount = @($VCFAutomationIPPool).Count
        if ($autoPoolCount -lt 5) {
            My-Logger "✗ VCF Automation ipPool has only $autoPoolCount address(es); at least 5 are required." "red"
            My-Logger "  Currently configured: $(@($VCFAutomationIPPool) -join ', ')" "yellow"
            My-Logger "  Fix: set `$VCFAutomationIPPool in the config to 5+ addresses, e.g.:" "yellow"
            My-Logger "  `$VCFAutomationIPPool = @(\"10.2.101.108\",\"10.2.101.109\",\"10.2.101.110\",\"10.2.101.111\",\"10.2.101.112\")" "yellow"
            exit
        }

        $autoSpec = [ordered]@{
            "platformFqdn" = $VCFAutomationServicesRuntimeHostname
            "hostname" = $VCFAutomationHostname
            "adminUserPassword" = $VCFAutomationAdminPassword
            "ipPool" = $VCFAutomationIPPool
            "nodePrefix" = $VCFAutomationNodePrefix
            "internalClusterCidr" = $VCFAutomationClusterCIDR
            "useExistingDeployment" = $false
            "size" = $VCFAutomationSize
        }
    }
        $netSpec = @(
            [ordered]@{
                "networkType" = "MANAGEMENT"
                "subnet" = $NestedMGMTESXiManagementNetworkCidr
                "gateway" = $ESXMGMTGateway
                "subnetMask" = $null
                "includeIpAddress" = $null
                "includeIpAddressRanges" = $null
                "vlanId" = $ESXMGMTVLAN
                "mtu" = "1500"
                "teamingPolicy" = "loadbalance_loadbased"
                "activeUplinks" = @("uplink1","uplink2")
                "standbyUplinks" = @()
                "portGroupKey" = "ESX_MANAGEMENT"
            }
            [ordered]@{
                "networkType" = "VM_MANAGEMENT"
                "subnet" = $NestedMGMTESXiVMNetworkCidr
                "gateway" = $VMMGMTGateway
                "subnetMask" = $null
                "includeIpAddress" = $null
                "includeIpAddressRanges" = $null
                "vlanId" = $VMMGMTVLAN
                "mtu" = "1500"
                "teamingPolicy" = "loadbalance_loadbased"
                "activeUplinks" = @("uplink1","uplink2")
                "standbyUplinks" = @()
                "portGroupKey" = "VM_MANAGEMENT"
            }
            [ordered]@{
                "networkType" = "VMOTION"
                "subnet" = $NestedMGMTESXivMotionNetworkCidr
                "gateway" = $esxivMotionGateway
                "subnetMask" = $null
                "includeIpAddress" = $null
                "includeIpAddressRanges" = @(@{"startIpAddress" = $esxivMotionStart;"endIpAddress" = $esxivMotionEnd})
                "vlanId" = "102"
                "mtu" = "8900"
                "teamingPolicy" = "loadbalance_loadbased"
                "activeUplinks" = @("uplink1","uplink2")
                "standbyUplinks" = @()
                "portGroupKey" = "VMOTION"
            }
            [ordered]@{
                "networkType" = "VSAN"
                "subnet" = $NestedMGMTESXivSANNetworkCidr
                "gateway"= $esxivSANGateway
                "subnetMask" = $null
                "includeIpAddress" = $null
                "teamingPolicy" = "loadbalance_loadbased"
                "includeIpAddressRanges" = @(@{"startIpAddress" = $esxivSANStart;"endIpAddress" = $esxivSANEnd})
                "vlanId" = "103"
                "mtu" = "8900"
                "activeUplinks" = @("uplink1","uplink2")
                "standbyUplinks" = @()
                "portGroupKey" = "VSAN"
            }
        )
        $vdsSpec = @(
            [ordered]@{
                "dvsName" = "sddc1-cl01-vds01"
                "networks" = @(
                    "MANAGEMENT",
                    "VM_MANAGEMENT",
                    "VMOTION",
                    "VSAN"
                )
                "mtu" = "8900"
                "nsxtSwitchConfig" = [ordered]@{
                    "transportZones" = @(
                        @{
                            "transportType" = "OVERLAY"
                            "name" = "VCF-Created-Overlay-Zone"
                        }
                    )
                    "hostSwitchOperationalMode" = "STANDARD"
                }
                "vmnicsToUplinks" = @(
                    @{
                        "id" = "vmnic0"
                        "uplink" = "uplink1"
                    }
                    @{
                        "id" = "vmnic1"
                        "uplink" = "uplink2"
                    }
                )
                "nsxTeamings" = @(
                    @{
                        "policy" = "LOADBALANCE_SRCID"
                        "activeUplinks" = @("uplink1","uplink2")
                        "standByUplinks" = @()
                    }
                )
                "lagSpecs" = $null
                "vmnics" = @("vmnic0","vmnic1")
            }
        )

    if($VCFInstallerProductSKU -eq "VCF") {
        $vcfConfig.Add("vcfOperationsCollectorSpec",$opsCollectorSpec)
        $vcfConfig.Add("vcfAutomationSpec",$autoSpec)
        $vcfConfig.Add("saltSpec",@{})
        $vcfConfig.Add("vidbSpec",$vidbSpec)
        $vcfConfig.Add("saltRaasSpec",@{})
    }

    # VCF 9.1.0.0 service-runtime / license / LCM specs (required for all SKUs)
    $vcfConfig.Add("vcfManagementComponentsInfrastructureSpec",$vcfMgmtInfraSpec)
    $vcfConfig.Add("vspClusterSpec",$vspClusterSpec)
    $vcfConfig.Add("telemetryAcceptorSpec",@{})
    $vcfConfig.Add("licenseServerSpec",$licenseServerSpec)
    $vcfConfig.Add("sddcLcmSpec",$sddcLcmSpec)
    $vcfConfig.Add("fleetLcmSpec",$fleetLcmSpec)
    $vcfConfig.Add("fleetDepotSpec",@{})

    $vcfConfig.Add("networkSpecs",$netSpec)
    $vcfConfig.Add("dvsSpecs",$vdsSpec)

    My-Logger "Generating $VCFInstallerProductSKU Management Domain deployment JSON file $VCFManagementDomainJSONFile"
    $vcfConfig | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $VCFManagementDomainJSONFile
}

if($configureVCFInstallerConfig -eq 1) {
    My-Logger "`n========================================" "cyan"
    My-Logger "  VCF SOFTWARE DEPOT CONFIGURATION" "cyan"
    My-Logger "========================================`n" "cyan"

    Verify-VCFAPIEndpoint -EndpointName "VCF Installer" -EndpointIp $VCFInstallerFQDN

    $connectDepot = 1
    $syncDepot = 1
    $downloadReleases = 1

    if($connectDepot -eq 1) {
        Connect-VCFDepot -EndpointIp $VCFInstallerFQDN
    }

    if($syncDepot -eq 1) {
        Sync-VCFDepot -EndpointIp $VCFInstallerFQDN
    }

    if($downloadReleases -eq 1) {
        Download-VCFRelease -EndpointIp $VCFInstallerFQDN
    }
}

if($startVCFBringup -eq 1) {
    My-Logger "`n========================================" "cyan"
    My-Logger "  STARTING VCF DEPLOYMENT BRINGUP" "cyan"
    My-Logger "========================================`n" "cyan"

    # Pre-bringup validation. Set $validateBeforeBringup = 0 to skip (e.g. once a
    # spec is known-good). When it fails, we stop here rather than firing a blind
    # POST /v1/sddcs - the per-check report above tells you exactly what to fix.
    if($validateBeforeBringup -ne 0) {
        $valOk = Validate-VCFBringupSpec -EndpointIp $VCFInstallerFQDN -JsonFile $VCFManagementDomainJSONFile
        if(-not $valOk) {
            My-Logger "Aborting bringup: validation did not pass. Fix the issues above and re-run." "red"
            exit
        }
        My-Logger "Validation passed - proceeding to submit bringup." "green"
    }

    $headers = Get-VCFInstallerToken

    try {
        $uri = "https://${VCFInstallerFQDN}/v1/sddcs"
        $method = "POST"
        $body = Get-Content -Raw $VCFManagementDomainJSONFile

        if($Debug) {
            My-Logger "DEBUG: Method: $method" "cyan"
            My-Logger "DEBUG: Uri: $uri" "cyan"
        }

        # FIX: bumped from 5s. POST /v1/sddcs kicks off a long-running bringup and
        # does not return in 5s; the old value cancelled the request every time.
        $requests = Invoke-WebRequest -Uri $uri -Method $method -SkipCertificateCheck -TimeoutSec 300 -Headers $headers -Body $body
        # FIX: success handling moved OUT of the catch block. A successful 202 throws
        # no exception, so the old code (which checked status inside catch) never ran
        # on success, and on a timeout $_.Exception.Response was null -> always "Failed".
        if($requests.StatusCode -eq 200 -or $requests.StatusCode -eq 202) {
            My-Logger "✓ VCF Deployment request submitted successfully" "green"
        } else {
            My-Logger "Unexpected response submitting bringup (Status: $($requests.StatusCode))" "yellow"
        }
    }
    catch {
        My-Logger "✗ Failed to submit VCF Deployment request" "red"

        # Read the actual response body from the installer - this is where the
        # real reason for a 400 lives (errorCode / message / causes / validationChecks).
        # On PowerShell 7 it is almost always in $_.ErrorDetails.Message; the stream
        # fallback covers older hosts / cases where ErrorDetails is empty.
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
            try {
                # Pretty-print if it is JSON so errorCode / causes are readable
                ($respBody | ConvertFrom-Json) | ConvertTo-Json -Depth 20 | Out-Host
            } catch {
                My-Logger $respBody "yellow"
            }
        } else {
            My-Logger "(No response body returned - likely a timeout or transport-level failure, not a validation error)" "yellow"
        }

        Write-Error "`n$($_.Exception.Message)`n"
        exit
    }

    My-Logger "`nOpen browser to the VMware VCF Installer UI to monitor deployment progress:" "cyan"
    My-Logger "  URL: https://${VCFInstallerFQDN}/vcf-installer-ui/portal/progress-viewer" "white"
}

if($startVCFBringup -eq 1 -and $uploadVCFNotifyScript -eq 1) {
    if(Test-Path $srcNotificationScript) {
        $vcfVM = Get-VM -Server $viConnection $VCFInstallerVMName

        My-Logger "Uploading VCF notification script $srcNotificationScript to $dstNotificationScript on VCF Installer appliance ..."
        Copy-VMGuestFile -Server $viConnection -VM $vcfVM -Source $srcNotificationScript -Destination $dstNotificationScript -LocalToGuest -GuestUser "root" -GuestPassword $VCFInstallerRootPassword | Out-Null
        Invoke-VMScript -Server $viConnection -VM $vcfVM -ScriptText "chmod +x $dstNotificationScript" -GuestUser "root" -GuestPassword $VCFInstallerRootPassword | Out-Null

        My-Logger "Configuring crontab to run notification check script every 15 minutes ..."
        Invoke-VMScript -Server $viConnection -VM $vcfVM -ScriptText "echo '*/15 * * * * $dstNotificationScript' > /var/spool/cron/root" -GuestUser "root" -GuestPassword $VCFInstallerRootPassword | Out-Null
    }
}

if($deployNestedESXiVMsForMgmt -eq 1 -or $deployNestedESXiVMsForWLD -eq 1 -or $updateVCFInstallerConfig -eq 1 -or $deployVCFInstaller -eq 1) {
    My-Logger "Disconnecting from Management vCenter Server $VIServer ..."
    Disconnect-VIServer -Server $viConnection -Confirm:$false
}

$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

My-Logger "`n╔════════════════════════════════════════════════════════════════╗" "cyan"
My-Logger "║         VCF 9 LAB DEPLOYMENT COMPLETE                         ║" "cyan"
My-Logger "╠════════════════════════════════════════════════════════════════╣" "cyan"
My-Logger "║  StartTime: $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" "cyan"
My-Logger "║  EndTime:   $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))" "cyan"
My-Logger "║  Duration:  $duration minutes" "cyan"
My-Logger "║  Log File:  $verboseLogFile" "cyan"
My-Logger "╚════════════════════════════════════════════════════════════════╝" "cyan"