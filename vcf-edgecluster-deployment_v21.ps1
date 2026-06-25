# Author: Daniel Sjödin
# Purpose: Deploy NSX Edge Clusters for Management and Workload Domains
# Compatible with VCF 9.x
#
#Version 2.1
#
# All configuration variables must be defined in the config file passed via -EnvConfigFile
#   Example config file variables (must exist there, NOT here):
#   - SddcManagerIP
#   - VCSASSOPassword
#   - VMDomain
#   - VMMGMTGateway
#   - ESXWLDGateway
#   - MGMTEdge* variables (names, IPs, VLANs, ASN, etc.)
#   - WLDEdge* variables (names, IPs, VLANs, ASN, etc.)
#   - VCSAClusterName
#   - VCFWorkloadDomainVCSAClusterName
#   - NSXRootPassword, NSXAdminPassword, NSXAuditPassword
#   - Debug (optional)

param (
    [string]$EnvConfigFile,
    [ValidateSet("MGMT", "WLD", "BOTH")]
    [string]$DeploymentTarget = "BOTH",
    [switch]$WhatIf
)

# Validate that the config file exists and load it
if ($EnvConfigFile -and (Test-Path $EnvConfigFile)) {
    . $EnvConfigFile  # Dot-sourcing the config file (must define all env-specific variables)
} else {
    Write-Host -ForegroundColor Red "`nNo valid deployment configuration file was provided or file was not found.`n"
    exit
}

#### DO NOT EDIT BEYOND HERE ####

$verboseLogFile = "vcf-edge-cluster-deployment.log"
$StartTime      = Get-Date

Function My-Logger {
    param(
        [Parameter(Mandatory = $true)][String]$message,
        [Parameter(Mandatory = $false)][String]$color = "green"
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_HH:mm:ss"

    Write-Host -NoNewline -ForegroundColor White "[$timeStamp]"
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
        $requests = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/tokens" -Method POST -SkipCertificateCheck -TimeoutSec 5 -Headers @{
            "Content-Type" = "application/json"
            "Accept"       = "application/json"
        } -Body $body

        if ($requests.StatusCode -eq 200) {
            $accessToken = ($requests.Content | ConvertFrom-Json).accessToken
        } else {
            My-Logger ("Unexpected status code retrieving SDDC Manager token: {0}" -f $requests.StatusCode) "red"
            return $null
        }
    } catch {
        My-Logger ("Unable to retrieve SDDC Manager Token: {0}" -f $_.Exception.Message) "red"
        return $null
    }

    $headers = @{
        "Content-Type" = "application/json"
        "Accept"       = "application/json"
        "Authorization"= "Bearer ${accessToken}"
    }

    return $headers
}

Function Get-VCFClusterId {
    param(
        [Parameter(Mandatory = $true)][String]$ClusterName
    )

    $headers = Get-VCFSDDCmToken

    try {
        $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/clusters" -Method GET -SkipCertificateCheck -Headers $headers
        $clusters = ($response.Content | ConvertFrom-Json).elements
        $cluster  = $clusters | Where-Object { $_.name -eq $ClusterName }

        if ($cluster) {
            return $cluster.id
        } else {
            My-Logger "Cluster '$ClusterName' not found" "red"
            return $null
        }
    } catch {
        My-Logger ("Failed to retrieve clusters: {0}" -f $_.Exception.Message) "red"
        return $null
    }
}

Function Get-VCFHostIds {
    param(
        [Parameter(Mandatory = $true)][String]$ClusterId,
        [Parameter(Mandatory = $true)][Int]$Count
    )

    $headers = Get-VCFSDDCmToken

    try {
        $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/hosts" -Method GET -SkipCertificateCheck -Headers $headers
        $hosts    = ($response.Content | ConvertFrom-Json).elements
        $clusterHosts = $hosts | Where-Object { $_.cluster.id -eq $ClusterId } | Select-Object -First $Count

        return $clusterHosts.id
    } catch {
        My-Logger ("Failed to retrieve hosts: {0}" -f $_.Exception.Message) "red"
        return $null
    }
}

Function Get-AllVCFDomains {
    <#
    .SYNOPSIS
        Gets all domains from SDDC Manager (used by -WhatIf)
    #>
    $headers = Get-VCFSDDCmToken
    if (-not $headers) { return @() }

    try {
        $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/domains" -Method GET -SkipCertificateCheck -Headers $headers
        $domains = ($response.Content | ConvertFrom-Json).elements
        return $domains
    } catch {
        return @()
    }
}

Function Get-AllVCFClusters {
    <#
    .SYNOPSIS
        Gets all clusters from SDDC Manager (used by -WhatIf)
    #>
    $headers = Get-VCFSDDCmToken
    if (-not $headers) { return @() }

    try {
        $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/clusters" -Method GET -SkipCertificateCheck -Headers $headers
        $clusters = ($response.Content | ConvertFrom-Json).elements
        return $clusters
    } catch {
        return @()
    }
}

Function Get-AllVCFHosts {
    <#
    .SYNOPSIS
        Gets all hosts from SDDC Manager (used by -WhatIf)
    #>
    $headers = Get-VCFSDDCmToken
    if (-not $headers) { return @() }

    try {
        $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/hosts" -Method GET -SkipCertificateCheck -Headers $headers
        $hosts = ($response.Content | ConvertFrom-Json).elements
        return $hosts
    } catch {
        return @()
    }
}

Function Get-AllVCFEdgeClusters {
    <#
    .SYNOPSIS
        Gets all existing edge clusters from SDDC Manager (used by -WhatIf)
    #>
    $headers = Get-VCFSDDCmToken
    if (-not $headers) { return @() }

    try {
        $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/edge-clusters" -Method GET -SkipCertificateCheck -Headers $headers
        $edgeClusters = ($response.Content | ConvertFrom-Json).elements
        return $edgeClusters
    } catch {
        return @()
    }
}

Function Get-ClusterHostsForEdge {
    <#
    .SYNOPSIS
        Gets hosts in a cluster that would be used for Edge deployment
    #>
    param(
        [Parameter(Mandatory = $true)][String]$ClusterId
    )

    $headers = Get-VCFSDDCmToken
    if (-not $headers) { return @() }

    try {
        $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/hosts" -Method GET -SkipCertificateCheck -Headers $headers
        $hosts = ($response.Content | ConvertFrom-Json).elements
        $clusterHosts = $hosts | Where-Object { $_.cluster.id -eq $ClusterId }
        return $clusterHosts
    } catch {
        return @()
    }
}

Function Wait-VCFTask {
    param(
        [Parameter(Mandatory = $true)][String]$TaskId,
        [Parameter(Mandatory = $false)][Int]$TimeoutMinutes = 120
    )

    $headers   = Get-VCFSDDCmToken
    $startTime = Get-Date
    $timeout   = New-TimeSpan -Minutes $TimeoutMinutes
    $lastSubtaskStatus = ""

    while ((Get-Date) - $startTime -lt $timeout) {
        try {
            # Refresh token periodically (every 15 minutes approximately)
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalMinutes -gt 0 -and [math]::Floor($elapsed.TotalMinutes) % 15 -eq 0) {
                $headers = Get-VCFSDDCmToken
            }

            $response = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/tasks/$TaskId" -Method GET -SkipCertificateCheck -Headers $headers
            $task     = ($response.Content | ConvertFrom-Json)
            $status   = $task.status

            switch ($status.ToUpper()) {
                "SUCCESSFUL" {
                    My-Logger "Task $TaskId completed successfully" "green"
                    return $true
                }
                "FAILED" {
                    My-Logger "Task $TaskId failed!" "red"
                    $task | ConvertTo-Json -Depth 10 | Out-File "failed-task-$TaskId.json"
                    
                    # Show failed subtasks
                    if ($task.subTasks) {
                        $failedSubtasks = $task.subTasks | Where-Object { $_.status -eq "FAILED" }
                        foreach ($st in $failedSubtasks) {
                            My-Logger "  Failed subtask: $($st.name)" "red"
                            if ($st.errors) {
                                foreach ($err in $st.errors) {
                                    My-Logger "    Error: $($err.message)" "red"
                                }
                            }
                        }
                    }
                    
                    if ($task.errors) {
                        foreach ($err in $task.errors) {
                            My-Logger "  Task error: $($err.message)" "red"
                        }
                    }
                    return $false
                }
                "CANCELLED" {
                    My-Logger "Task $TaskId was cancelled" "yellow"
                    return $false
                }
                default {
                    # Calculate real progress from subtasks
                    $subtaskInfo = ""
                    $overallProgress = 0
                    $activeSubtask = ""
                    
                    if ($task.subTasks -and $task.subTasks.Count -gt 0) {
                        $totalSubtasks = $task.subTasks.Count
                        $completedSubtasks = ($task.subTasks | Where-Object { $_.status -eq "SUCCESSFUL" }).Count
                        $inProgressSubtasks = $task.subTasks | Where-Object { $_.status -eq "IN_PROGRESS" -or $_.status -eq "PENDING" }
                        
                        # Calculate overall progress
                        $overallProgress = [math]::Round(($completedSubtasks / $totalSubtasks) * 100, 0)
                        
                        # Get the current active subtask
                        $currentSubtask = $task.subTasks | Where-Object { $_.status -eq "IN_PROGRESS" } | Select-Object -First 1
                        if ($currentSubtask) {
                            $activeSubtask = $currentSubtask.name
                            $subtaskProgress = if ($currentSubtask.completionPercentage) { $currentSubtask.completionPercentage } else { 0 }
                            $subtaskInfo = " | Subtask: $activeSubtask ($subtaskProgress%)"
                        } else {
                            # Check for pending subtasks
                            $pendingSubtask = $task.subTasks | Where-Object { $_.status -eq "PENDING" } | Select-Object -First 1
                            if ($pendingSubtask) {
                                $activeSubtask = $pendingSubtask.name
                                $subtaskInfo = " | Next: $activeSubtask"
                            }
                        }
                        
                        $subtaskInfo = " [$completedSubtasks/$totalSubtasks subtasks]$subtaskInfo"
                    } else {
                        # Fall back to top-level percentage if no subtasks
                        $overallProgress = if ($task.completionPercentage) { $task.completionPercentage } else { 0 }
                    }
                    
                    # Only log if status changed or every 2 minutes
                    $currentStatus = "$status-$overallProgress-$activeSubtask"
                    $shouldLog = ($currentStatus -ne $lastSubtaskStatus) -or ($elapsed.TotalSeconds % 120 -lt 60)
                    
                    if ($shouldLog -or $lastSubtaskStatus -eq "") {
                        $elapsedStr = "{0:D2}:{1:D2}" -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
                        My-Logger "[$elapsedStr] Task $status ($overallProgress% complete)$subtaskInfo" "yellow"
                        $lastSubtaskStatus = $currentStatus
                    }
                    
                    Start-Sleep -Seconds 30
                }
            }
        } catch {
            My-Logger ("Error checking task status for {0}: {1}" -f $TaskId, $_.Exception.Message) "yellow"
            # Refresh token on error
            $headers = Get-VCFSDDCmToken
            Start-Sleep -Seconds 30
        }
    }

    My-Logger "Task $TaskId timed out after $TimeoutMinutes minutes" "red"
    return $false
}

Function Build-EdgeClusterSpec {
    <#
    .SYNOPSIS
        Builds the Edge Cluster spec without deploying (used for WhatIf display)
    #>
    param(
        [Parameter(Mandatory = $true)][String]$DomainType,
        [Parameter(Mandatory = $true)][String]$ClusterName,
        [Parameter(Mandatory = $true)][String]$EdgeClusterName,
        [Parameter(Mandatory = $true)][String]$EdgeFormFactor,
        [Parameter(Mandatory = $true)][String]$EdgeNode1Name,
        [Parameter(Mandatory = $true)][String]$EdgeNode1MgmtIP,
        [Parameter(Mandatory = $true)][String]$EdgeNode1TEP1IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode1TEP2IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2Name,
        [Parameter(Mandatory = $true)][String]$EdgeNode2MgmtIP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2TEP1IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2TEP2IP,
        [Parameter(Mandatory = $true)][Int]$EdgeMgmtPrefix,
        [Parameter(Mandatory = $true)][Int]$EdgeTEPVLAN,
        [Parameter(Mandatory = $true)][String]$EdgeTEPGateway,
        [Parameter(Mandatory = $true)][Int]$EdgeTEPPrefix,
        [Parameter(Mandatory = $true)][String]$Tier0Name,
        [Parameter(Mandatory = $true)][Int]$Tier0ASN,
        [Parameter(Mandatory = $true)][Int]$BGPPeerASN,
        [Parameter(Mandatory = $true)][String]$ManagementGateway,
        [Parameter(Mandatory = $true)][Int]$Uplink1VLAN,
        [Parameter(Mandatory = $true)][Int]$Uplink1Prefix,
        [Parameter(Mandatory = $true)][String]$Uplink1Gateway,
        [Parameter(Mandatory = $true)][String]$EdgeNode1Uplink1IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2Uplink1IP,
        [Parameter(Mandatory = $false)][Int]$Uplink2VLAN = 0,
        [Parameter(Mandatory = $false)][Int]$Uplink2Prefix = 24,
        [Parameter(Mandatory = $false)][String]$Uplink2Gateway = "",
        [Parameter(Mandatory = $false)][String]$EdgeNode1Uplink2IP = "",
        [Parameter(Mandatory = $false)][String]$EdgeNode2Uplink2IP = ""
    )

    $clusterId = Get-VCFClusterId -ClusterName $ClusterName

    # Edge Node 1 uplinks
    $edgeNode1Uplinks = @(
        @{
            "uplinkVlan"        = $Uplink1VLAN
            "uplinkInterfaceIP" = "${EdgeNode1Uplink1IP}/${Uplink1Prefix}"
            "peerIP"            = "${Uplink1Gateway}/${Uplink1Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
    )
    if ($EdgeNode1Uplink2IP -ne "" -and $Uplink2VLAN -ne 0) {
        $edgeNode1Uplinks += @{
            "uplinkVlan"        = $Uplink2VLAN
            "uplinkInterfaceIP" = "${EdgeNode1Uplink2IP}/${Uplink2Prefix}"
            "peerIP"            = "${Uplink2Gateway}/${Uplink2Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
    }

    # Edge Node 2 uplinks
    $edgeNode2Uplinks = @(
        @{
            "uplinkVlan"        = $Uplink1VLAN
            "uplinkInterfaceIP" = "${EdgeNode2Uplink1IP}/${Uplink1Prefix}"
            "peerIP"            = "${Uplink1Gateway}/${Uplink1Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
    )
    if ($EdgeNode2Uplink2IP -ne "" -and $Uplink2VLAN -ne 0) {
        $edgeNode2Uplinks += @{
            "uplinkVlan"        = $Uplink2VLAN
            "uplinkInterfaceIP" = "${EdgeNode2Uplink2IP}/${Uplink2Prefix}"
            "peerIP"            = "${Uplink2Gateway}/${Uplink2Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
    }

    $edgeClusterSpec = [ordered]@{
        "edgeClusterName"               = $EdgeClusterName
        "edgeClusterProfileType"        = "DEFAULT"
        "edgeClusterType"               = "NSX-T"
        "edgeRootPassword"              = "********"  # Masked for display
        "edgeAdminPassword"             = "********"
        "edgeAuditPassword"             = "********"
        "edgeFormFactor"                = $EdgeFormFactor
        "tier0ServicesHighAvailability" = "ACTIVE_ACTIVE"
        "mtu"                           = 8900
        "asn"                           = $Tier0ASN
        "edgeNodeSpecs"                 = @(
            [ordered]@{
                "edgeNodeName"     = "${EdgeNode1Name}.${VMDomain}"
                "managementIP"     = "${EdgeNode1MgmtIP}/${EdgeMgmtPrefix}"
                "managementGateway"= $ManagementGateway
                "edgeTepGateway"   = $EdgeTEPGateway
                "edgeTep1IP"       = "${EdgeNode1TEP1IP}/${EdgeTEPPrefix}"
                "edgeTep2IP"       = "${EdgeNode1TEP2IP}/${EdgeTEPPrefix}"
                "edgeTepVlan"      = $EdgeTEPVLAN
                "clusterId"        = $clusterId
                "interRackCluster" = $false
                "uplinkNetwork"    = $edgeNode1Uplinks
            }
            [ordered]@{
                "edgeNodeName"     = "${EdgeNode2Name}.${VMDomain}"
                "managementIP"     = "${EdgeNode2MgmtIP}/${EdgeMgmtPrefix}"
                "managementGateway"= $ManagementGateway
                "edgeTepGateway"   = $EdgeTEPGateway
                "edgeTep1IP"       = "${EdgeNode2TEP1IP}/${EdgeTEPPrefix}"
                "edgeTep2IP"       = "${EdgeNode2TEP2IP}/${EdgeTEPPrefix}"
                "edgeTepVlan"      = $EdgeTEPVLAN
                "clusterId"        = $clusterId
                "interRackCluster" = $false
                "uplinkNetwork"    = $edgeNode2Uplinks
            }
        )
        "tier0RoutingType"              = "EBGP"
        "tier0Name"                     = $Tier0Name
        "tier1Name"                     = "${EdgeClusterName}-t1-gw01"
        "tier1Unhosted"                 = $false
    }

    return @{
        "spec" = $edgeClusterSpec
        "clusterId" = $clusterId
        "clusterName" = $ClusterName
        "hasSecondUplink" = ($EdgeNode1Uplink2IP -ne "" -and $Uplink2VLAN -ne 0)
    }
}

Function Deploy-EdgeCluster {
    param(
        [Parameter(Mandatory = $true)][String]$DomainType,
        [Parameter(Mandatory = $true)][String]$ClusterName,
        [Parameter(Mandatory = $true)][String]$EdgeClusterName,
        [Parameter(Mandatory = $true)][String]$EdgeFormFactor,
        [Parameter(Mandatory = $true)][String]$EdgeNode1Name,
        [Parameter(Mandatory = $true)][String]$EdgeNode1MgmtIP,
        [Parameter(Mandatory = $true)][String]$EdgeNode1TEP1IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode1TEP2IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2Name,
        [Parameter(Mandatory = $true)][String]$EdgeNode2MgmtIP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2TEP1IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2TEP2IP,
        [Parameter(Mandatory = $true)][Int]$EdgeMgmtPrefix,
        [Parameter(Mandatory = $true)][Int]$EdgeTEPVLAN,
        [Parameter(Mandatory = $true)][String]$EdgeTEPGateway,
        [Parameter(Mandatory = $true)][Int]$EdgeTEPPrefix,
        [Parameter(Mandatory = $true)][String]$Tier0Name,
        [Parameter(Mandatory = $true)][Int]$Tier0ASN,
        [Parameter(Mandatory = $true)][Int]$BGPPeerASN,
        [Parameter(Mandatory = $true)][String]$ManagementGateway,
        # Uplink 1 (required)
        [Parameter(Mandatory = $true)][Int]$Uplink1VLAN,
        [Parameter(Mandatory = $true)][Int]$Uplink1Prefix,
        [Parameter(Mandatory = $true)][String]$Uplink1Gateway,
        [Parameter(Mandatory = $true)][String]$EdgeNode1Uplink1IP,
        [Parameter(Mandatory = $true)][String]$EdgeNode2Uplink1IP,
        # Uplink 2 (optional)
        [Parameter(Mandatory = $false)][Int]$Uplink2VLAN = 0,
        [Parameter(Mandatory = $false)][Int]$Uplink2Prefix = 24,
        [Parameter(Mandatory = $false)][String]$Uplink2Gateway = "",
        [Parameter(Mandatory = $false)][String]$EdgeNode1Uplink2IP = "",
        [Parameter(Mandatory = $false)][String]$EdgeNode2Uplink2IP = ""
    )

    My-Logger "Deploying Edge Cluster for $DomainType Domain..."

    $clusterId = Get-VCFClusterId -ClusterName $ClusterName
    if (-not $clusterId) {
        My-Logger "Failed to get cluster ID for $ClusterName" "red"
        return $false
    }
    My-Logger "[$DomainType] Using vSphere cluster '$ClusterName' with ID: $clusterId"

    $hostIds = Get-VCFHostIds -ClusterId $clusterId -Count 2
    if (-not $hostIds -or $hostIds.Count -lt 2) {
        My-Logger "Need at least 2 hosts in cluster '$ClusterName' for Edge deployment" "red"
        return $false
    }
    My-Logger "Found hosts for Edge placement in '$ClusterName': $($hostIds -join ', ')"

    $headers = Get-VCFSDDCmToken

    # Edge Node 1 uplinks
    $edgeNode1Uplinks = @(
        @{
            "uplinkVlan"        = $Uplink1VLAN
            "uplinkInterfaceIP" = "${EdgeNode1Uplink1IP}/${Uplink1Prefix}"
            "peerIP"            = "${Uplink1Gateway}/${Uplink1Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
    )
    if ($EdgeNode1Uplink2IP -ne "" -and $Uplink2VLAN -ne 0) {
        $edgeNode1Uplinks += @{
            "uplinkVlan"        = $Uplink2VLAN
            "uplinkInterfaceIP" = "${EdgeNode1Uplink2IP}/${Uplink2Prefix}"
            "peerIP"            = "${Uplink2Gateway}/${Uplink2Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
        My-Logger "Edge Node 1: Dual uplinks configured (VLAN $Uplink1VLAN + VLAN $Uplink2VLAN)"
    } else {
        My-Logger "Edge Node 1: Single uplink configured (VLAN $Uplink1VLAN)"
    }

    # Edge Node 2 uplinks
    $edgeNode2Uplinks = @(
        @{
            "uplinkVlan"        = $Uplink1VLAN
            "uplinkInterfaceIP" = "${EdgeNode2Uplink1IP}/${Uplink1Prefix}"
            "peerIP"            = "${Uplink1Gateway}/${Uplink1Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
    )
    if ($EdgeNode2Uplink2IP -ne "" -and $Uplink2VLAN -ne 0) {
        $edgeNode2Uplinks += @{
            "uplinkVlan"        = $Uplink2VLAN
            "uplinkInterfaceIP" = "${EdgeNode2Uplink2IP}/${Uplink2Prefix}"
            "peerIP"            = "${Uplink2Gateway}/${Uplink2Prefix}"
            "asnPeer"           = $BGPPeerASN
            "bgpPeerPassword"   = ""
        }
        My-Logger "Edge Node 2: Dual uplinks configured (VLAN $Uplink1VLAN + VLAN $Uplink2VLAN)"
    } else {
        My-Logger "Edge Node 2: Single uplink configured (VLAN $Uplink1VLAN)"
    }

    $edgeClusterSpec = [ordered]@{
        "edgeClusterName"               = $EdgeClusterName
        "edgeClusterProfileType"        = "DEFAULT"
        "edgeClusterType"               = "NSX-T"
        "edgeRootPassword"              = $NSXRootPassword
        "edgeAdminPassword"             = $NSXAdminPassword
        "edgeAuditPassword"             = $NSXAuditPassword
        "edgeFormFactor"                = $EdgeFormFactor
        "tier0ServicesHighAvailability" = "ACTIVE_ACTIVE"
        "mtu"                           = 8900
        "asn"                           = $Tier0ASN
        "edgeNodeSpecs"                 = @(
            [ordered]@{
                "edgeNodeName"     = "${EdgeNode1Name}.${VMDomain}"
                "managementIP"     = "${EdgeNode1MgmtIP}/${EdgeMgmtPrefix}"
                "managementGateway"= $ManagementGateway
                "edgeTepGateway"   = $EdgeTEPGateway
                "edgeTep1IP"       = "${EdgeNode1TEP1IP}/${EdgeTEPPrefix}"
                "edgeTep2IP"       = "${EdgeNode1TEP2IP}/${EdgeTEPPrefix}"
                "edgeTepVlan"      = $EdgeTEPVLAN
                "clusterId"        = $clusterId
                "interRackCluster" = $false
                "uplinkNetwork"    = $edgeNode1Uplinks
            }
            [ordered]@{
                "edgeNodeName"     = "${EdgeNode2Name}.${VMDomain}"
                "managementIP"     = "${EdgeNode2MgmtIP}/${EdgeMgmtPrefix}"
                "managementGateway"= $ManagementGateway
                "edgeTepGateway"   = $EdgeTEPGateway
                "edgeTep1IP"       = "${EdgeNode2TEP1IP}/${EdgeTEPPrefix}"
                "edgeTep2IP"       = "${EdgeNode2TEP2IP}/${EdgeTEPPrefix}"
                "edgeTepVlan"      = $EdgeTEPVLAN
                "clusterId"        = $clusterId
                "interRackCluster" = $false
                "uplinkNetwork"    = $edgeNode2Uplinks
            }
        )
        "tier0RoutingType"              = "EBGP"
        "tier0Name"                     = $Tier0Name
        "tier1Name"                     = "${EdgeClusterName}-t1-gw01"
        "tier1Unhosted"                 = $false
    }

    $body = $edgeClusterSpec | ConvertTo-Json -Depth 10

    if ($Debug) {
        My-Logger ("DEBUG: Edge Cluster Spec for {0}:" -f $DomainType) "cyan"
        My-Logger $body "cyan"
    }

    $specFile = "edge-cluster-spec-${DomainType}.json"
    $body | Out-File -LiteralPath $specFile
    My-Logger "Edge cluster spec for $DomainType saved to $specFile"

    try {
        $uri      = "https://${SddcManagerIP}/v1/edge-clusters"
        $response = Invoke-WebRequest -Uri $uri -Method POST -SkipCertificateCheck -Headers $headers -Body $body -ContentType "application/json"

        if ($response.StatusCode -eq 202 -or $response.StatusCode -eq 200) {
            $taskId = (($response.Content | ConvertFrom-Json).id)
            My-Logger "Edge cluster deployment for $DomainType started with task ID: $taskId"

            $success = Wait-VCFTask -TaskId $taskId -TimeoutMinutes 90
            return $success
        } else {
            My-Logger ("Unexpected response from Edge cluster deployment API: {0}" -f $response.StatusCode) "yellow"
            return $false
        }
    } catch {
        My-Logger ("Failed to deploy Edge cluster for {0}: {1}" -f $DomainType, $_.Exception.Message) "red"

        try {
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errorDetails = $_.ErrorDetails.Message | ConvertFrom-Json
                My-Logger ("Error details: {0}" -f ($errorDetails | ConvertTo-Json -Depth 5)) "red"
            }
        } catch {
            My-Logger ("Raw error (could not parse JSON error details): {0}" -f $_.Exception.Message) "red"
        }
        return $false
    }
}

# ==========================================================================
# Main Execution
# ==========================================================================

$modeIndicator = if ($WhatIf) { " [WHATIF MODE]" } else { "" }

Write-Host -ForegroundColor Cyan @"

╔═══════════════════════════════════════════════════════════════════╗
║      VCF 9 NSX Edge Cluster Deployment Script$modeIndicator
╠═══════════════════════════════════════════════════════════════════╣
║  Deployment Target: $DeploymentTarget
║  SDDC Manager: $SddcManagerIP
╚═══════════════════════════════════════════════════════════════════╝

"@

# ==========================================================================
# WhatIf Mode - Display all discovered values without deploying
# ==========================================================================
if ($WhatIf) {
    Write-Host -ForegroundColor Magenta @"

╔═══════════════════════════════════════════════════════════════════╗
║                    WHATIF MODE - DRY RUN                          ║
║              Querying SDDC Manager for information...             ║
╚═══════════════════════════════════════════════════════════════════╝

"@

    # ==================== SDDC MANAGER CONNECTIVITY ====================
    Write-Host -ForegroundColor Yellow "┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  SDDC MANAGER CONNECTIVITY                                      │"
    Write-Host -ForegroundColor Yellow "│  Source: https://$SddcManagerIP                                 │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

    $headers = Get-VCFSDDCmToken
    if ($headers) {
        Write-Host -ForegroundColor Green "`n  [✓] Successfully connected to SDDC Manager"
    } else {
        Write-Host -ForegroundColor Red "`n  [✗] Failed to connect to SDDC Manager"
        Write-Host -ForegroundColor Red "      Cannot proceed with WhatIf analysis"
        exit 1
    }

    # ==================== DOMAINS ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  VCF DOMAINS                                                    │"
    Write-Host -ForegroundColor Yellow "│  Source: /v1/domains                                            │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

    $domains = Get-AllVCFDomains
    if ($domains.Count -gt 0) {
        Write-Host -ForegroundColor Cyan "`n  Available Domains:"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        Write-Host -ForegroundColor DarkGray "  Name                 | Type           | Status       | ID"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        foreach ($domain in $domains) {
            $nameFormatted = $domain.name.PadRight(20)
            $typeFormatted = $domain.type.PadRight(14)
            $statusFormatted = $domain.status.PadRight(12)
            $statusColor = if ($domain.status -eq "ACTIVE") { "Green" } else { "Yellow" }
            Write-Host -NoNewline -ForegroundColor White "  $nameFormatted | $typeFormatted | "
            Write-Host -NoNewline -ForegroundColor $statusColor "$statusFormatted"
            Write-Host -ForegroundColor White " | $($domain.id)"
        }
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
    } else {
        Write-Host -ForegroundColor Red "`n  No domains found"
    }

    # ==================== CLUSTERS ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  VCF CLUSTERS                                                   │"
    Write-Host -ForegroundColor Yellow "│  Source: /v1/clusters                                           │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

    $clusters = Get-AllVCFClusters
    if ($clusters.Count -gt 0) {
        Write-Host -ForegroundColor Cyan "`n  Available Clusters:"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        Write-Host -ForegroundColor DarkGray "  Name                 | Primary Datastore | Host Count | ID"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        foreach ($cluster in $clusters) {
            $nameFormatted = $cluster.name.PadRight(20)
            $datastoreFormatted = ($cluster.primaryDatastoreType).PadRight(17)
            $hostCount = if ($cluster.hosts) { $cluster.hosts.Count } else { 0 }
            $hostCountFormatted = "$hostCount".PadRight(10)
            Write-Host -ForegroundColor White "  $nameFormatted | $datastoreFormatted | $hostCountFormatted | $($cluster.id)"
        }
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
    } else {
        Write-Host -ForegroundColor Red "`n  No clusters found"
    }

    # ==================== HOSTS ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  VCF HOSTS                                                      │"
    Write-Host -ForegroundColor Yellow "│  Source: /v1/hosts                                              │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

    $allHosts = Get-AllVCFHosts
    if ($allHosts.Count -gt 0) {
        Write-Host -ForegroundColor Cyan "`n  Hosts by Cluster:"
        
        foreach ($cluster in $clusters) {
            $clusterHosts = $allHosts | Where-Object { $_.cluster.id -eq $cluster.id }
            Write-Host -ForegroundColor White "`n  Cluster: $($cluster.name) ($($clusterHosts.Count) hosts)"
            Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
            
            if ($clusterHosts.Count -gt 0) {
                foreach ($h in $clusterHosts) {
                    $hostName = $h.fqdn.PadRight(35)
                    $hostStatus = $h.status.PadRight(12)
                    $statusColor = if ($h.status -eq "ASSIGNED") { "Green" } else { "Yellow" }
                    Write-Host -NoNewline -ForegroundColor White "    $hostName "
                    Write-Host -ForegroundColor $statusColor "$hostStatus"
                }
            }
        }
    } else {
        Write-Host -ForegroundColor Red "`n  No hosts found"
    }

    # ==================== EXISTING EDGE CLUSTERS ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  EXISTING NSX EDGE CLUSTERS                                     │"
    Write-Host -ForegroundColor Yellow "│  Source: /v1/edge-clusters                                      │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

    $existingEdgeClusters = Get-AllVCFEdgeClusters
    if ($existingEdgeClusters.Count -gt 0) {
        Write-Host -ForegroundColor Cyan "`n  Deployed Edge Clusters:"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        foreach ($ec in $existingEdgeClusters) {
            Write-Host -ForegroundColor White "  Name: $($ec.name)"
            Write-Host -ForegroundColor White "    ID: $($ec.id)"
            Write-Host -ForegroundColor White "    Tier-0: $($ec.tier0Name)"
            Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        }
    } else {
        Write-Host -ForegroundColor Yellow "`n  No existing Edge Clusters found"
    }

    # ==================== MGMT EDGE CLUSTER CONFIG ====================
    if ($DeploymentTarget -eq "MGMT" -or $DeploymentTarget -eq "BOTH") {
        Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
        Write-Host -ForegroundColor Yellow "│  MANAGEMENT DOMAIN EDGE CLUSTER CONFIGURATION                  │"
        Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

        Write-Host -ForegroundColor Cyan "`n  Configuration Values (from config file):"
        Write-Host -ForegroundColor White "    Target vSphere Cluster: $VCSAClusterName"
        
        $mgmtClusterId = Get-VCFClusterId -ClusterName $VCSAClusterName
        if ($mgmtClusterId) {
            Write-Host -ForegroundColor Green "    Cluster ID: $mgmtClusterId [✓]"
            
            $mgmtClusterHosts = Get-ClusterHostsForEdge -ClusterId $mgmtClusterId
            Write-Host -ForegroundColor White "    Hosts available for Edge: $($mgmtClusterHosts.Count)"
            if ($mgmtClusterHosts.Count -ge 2) {
                Write-Host -ForegroundColor Green "    [✓] Sufficient hosts (need 2)"
            } else {
                Write-Host -ForegroundColor Red "    [✗] Insufficient hosts (need at least 2)"
            }
        } else {
            Write-Host -ForegroundColor Red "    Cluster ID: NOT FOUND [✗]"
        }

        Write-Host -ForegroundColor Cyan "`n  Edge Cluster Settings:"
        Write-Host -ForegroundColor White "    Edge Cluster Name: $MGMTEdgeClusterName"
        Write-Host -ForegroundColor White "    Form Factor: $MGMTEdgeFormFactor"
        Write-Host -ForegroundColor White "    Tier-0 Gateway Name: $MGMTEdgeTier0Name"
        Write-Host -ForegroundColor White "    Tier-0 ASN: $MGMTEdgeTier0ASN"
        Write-Host -ForegroundColor White "    BGP Peer ASN: $MGMTEdgeBGPPeerASN"

        Write-Host -ForegroundColor Cyan "`n  Edge Node 1:"
        Write-Host -ForegroundColor White "    Name: ${MGMTEdgeNode1Name}.${VMDomain}"
        Write-Host -ForegroundColor White "    Management IP: ${MGMTEdgeNode1MgmtIP}/${MGMTEdgeMgmtPrefix}"
        Write-Host -ForegroundColor White "    Management Gateway: $VMMGMTGateway"
        Write-Host -ForegroundColor White "    TEP IPs: ${MGMTEdgeNode1TEP1IP}, ${MGMTEdgeNode1TEP2IP}"
        Write-Host -ForegroundColor White "    TEP VLAN: $MGMTEdgeTEPVLAN"
        Write-Host -ForegroundColor White "    Uplink1: ${MGMTEdgeNode1Uplink1IP}/${MGMTEdgeUplink1Prefix} (VLAN $MGMTEdgeUplink1VLAN)"
        if ($MGMTEdgeNode1Uplink2IP -ne "") {
            Write-Host -ForegroundColor White "    Uplink2: ${MGMTEdgeNode1Uplink2IP}/${MGMTEdgeUplink2Prefix} (VLAN $MGMTEdgeUplink2VLAN)"
        } else {
            Write-Host -ForegroundColor DarkGray "    Uplink2: Not configured (single uplink mode)"
        }

        Write-Host -ForegroundColor Cyan "`n  Edge Node 2:"
        Write-Host -ForegroundColor White "    Name: ${MGMTEdgeNode2Name}.${VMDomain}"
        Write-Host -ForegroundColor White "    Management IP: ${MGMTEdgeNode2MgmtIP}/${MGMTEdgeMgmtPrefix}"
        Write-Host -ForegroundColor White "    Management Gateway: $VMMGMTGateway"
        Write-Host -ForegroundColor White "    TEP IPs: ${MGMTEdgeNode2TEP1IP}, ${MGMTEdgeNode2TEP2IP}"
        Write-Host -ForegroundColor White "    TEP VLAN: $MGMTEdgeTEPVLAN"
        Write-Host -ForegroundColor White "    Uplink1: ${MGMTEdgeNode2Uplink1IP}/${MGMTEdgeUplink1Prefix} (VLAN $MGMTEdgeUplink1VLAN)"
        if ($MGMTEdgeNode2Uplink2IP -ne "") {
            Write-Host -ForegroundColor White "    Uplink2: ${MGMTEdgeNode2Uplink2IP}/${MGMTEdgeUplink2Prefix} (VLAN $MGMTEdgeUplink2VLAN)"
        } else {
            Write-Host -ForegroundColor DarkGray "    Uplink2: Not configured (single uplink mode)"
        }

        # Build and display the spec
        Write-Host -ForegroundColor Cyan "`n  Edge Cluster Spec (would be sent to API):"
        $mgmtSpecResult = Build-EdgeClusterSpec `
            -DomainType "MGMT" `
            -ClusterName $VCSAClusterName `
            -EdgeClusterName $MGMTEdgeClusterName `
            -EdgeFormFactor $MGMTEdgeFormFactor `
            -EdgeNode1Name $MGMTEdgeNode1Name `
            -EdgeNode1MgmtIP $MGMTEdgeNode1MgmtIP `
            -EdgeNode1TEP1IP $MGMTEdgeNode1TEP1IP `
            -EdgeNode1TEP2IP $MGMTEdgeNode1TEP2IP `
            -EdgeNode2Name $MGMTEdgeNode2Name `
            -EdgeNode2MgmtIP $MGMTEdgeNode2MgmtIP `
            -EdgeNode2TEP1IP $MGMTEdgeNode2TEP1IP `
            -EdgeNode2TEP2IP $MGMTEdgeNode2TEP2IP `
            -EdgeMgmtPrefix $MGMTEdgeMgmtPrefix `
            -EdgeTEPVLAN $MGMTEdgeTEPVLAN `
            -EdgeTEPGateway $MGMTEdgeTEPGateway `
            -EdgeTEPPrefix $MGMTEdgeTEPPrefix `
            -Tier0Name $MGMTEdgeTier0Name `
            -Tier0ASN $MGMTEdgeTier0ASN `
            -BGPPeerASN $MGMTEdgeBGPPeerASN `
            -ManagementGateway $VMMGMTGateway `
            -Uplink1VLAN $MGMTEdgeUplink1VLAN `
            -Uplink1Prefix $MGMTEdgeUplink1Prefix `
            -Uplink1Gateway $MGMTEdgeUplink1Gateway `
            -EdgeNode1Uplink1IP $MGMTEdgeNode1Uplink1IP `
            -EdgeNode2Uplink1IP $MGMTEdgeNode2Uplink1IP `
            -Uplink2VLAN $MGMTEdgeUplink2VLAN `
            -Uplink2Prefix $MGMTEdgeUplink2Prefix `
            -Uplink2Gateway $MGMTEdgeUplink2Gateway `
            -EdgeNode1Uplink2IP $MGMTEdgeNode1Uplink2IP `
            -EdgeNode2Uplink2IP $MGMTEdgeNode2Uplink2IP

        $mgmtSpecResult.spec | ConvertTo-Json -Depth 10 | ForEach-Object { Write-Host -ForegroundColor DarkGray "    $_" }
    }

    # ==================== WLD EDGE CLUSTER CONFIG ====================
    if ($DeploymentTarget -eq "WLD" -or $DeploymentTarget -eq "BOTH") {
        Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
        Write-Host -ForegroundColor Yellow "│  WORKLOAD DOMAIN EDGE CLUSTER CONFIGURATION                    │"
        Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

        Write-Host -ForegroundColor Cyan "`n  Configuration Values (from config file):"
        Write-Host -ForegroundColor White "    Target vSphere Cluster: $VCFWorkloadDomainVCSAClusterName"
        
        $wldClusterId = Get-VCFClusterId -ClusterName $VCFWorkloadDomainVCSAClusterName
        if ($wldClusterId) {
            Write-Host -ForegroundColor Green "    Cluster ID: $wldClusterId [✓]"
            
            $wldClusterHosts = Get-ClusterHostsForEdge -ClusterId $wldClusterId
            Write-Host -ForegroundColor White "    Hosts available for Edge: $($wldClusterHosts.Count)"
            if ($wldClusterHosts.Count -ge 2) {
                Write-Host -ForegroundColor Green "    [✓] Sufficient hosts (need 2)"
            } else {
                Write-Host -ForegroundColor Red "    [✗] Insufficient hosts (need at least 2)"
            }
        } else {
            Write-Host -ForegroundColor Red "    Cluster ID: NOT FOUND [✗]"
        }

        Write-Host -ForegroundColor Cyan "`n  Edge Cluster Settings:"
        Write-Host -ForegroundColor White "    Edge Cluster Name: $WLDEdgeClusterName"
        Write-Host -ForegroundColor White "    Form Factor: $WLDEdgeFormFactor"
        Write-Host -ForegroundColor White "    Tier-0 Gateway Name: $WLDEdgeTier0Name"
        Write-Host -ForegroundColor White "    Tier-0 ASN: $WLDEdgeTier0ASN"
        Write-Host -ForegroundColor White "    BGP Peer ASN: $WLDEdgeBGPPeerASN"

        Write-Host -ForegroundColor Cyan "`n  Edge Node 1:"
        Write-Host -ForegroundColor White "    Name: ${WLDEdgeNode1Name}.${VMDomain}"
        Write-Host -ForegroundColor White "    Management IP: ${WLDEdgeNode1MgmtIP}/${WLDEdgeMgmtPrefix}"
        Write-Host -ForegroundColor White "    Management Gateway: $ESXWLDGateway"
        Write-Host -ForegroundColor White "    TEP IPs: ${WLDEdgeNode1TEP1IP}, ${WLDEdgeNode1TEP2IP}"
        Write-Host -ForegroundColor White "    TEP VLAN: $WLDEdgeTEPVLAN"
        Write-Host -ForegroundColor White "    Uplink1: ${WLDEdgeNode1Uplink1IP}/${WLDEdgeUplink1Prefix} (VLAN $WLDEdgeUplink1VLAN)"
        if ($WLDEdgeNode1Uplink2IP -ne "") {
            Write-Host -ForegroundColor White "    Uplink2: ${WLDEdgeNode1Uplink2IP}/${WLDEdgeUplink2Prefix} (VLAN $WLDEdgeUplink2VLAN)"
        } else {
            Write-Host -ForegroundColor DarkGray "    Uplink2: Not configured (single uplink mode)"
        }

        Write-Host -ForegroundColor Cyan "`n  Edge Node 2:"
        Write-Host -ForegroundColor White "    Name: ${WLDEdgeNode2Name}.${VMDomain}"
        Write-Host -ForegroundColor White "    Management IP: ${WLDEdgeNode2MgmtIP}/${WLDEdgeMgmtPrefix}"
        Write-Host -ForegroundColor White "    Management Gateway: $ESXWLDGateway"
        Write-Host -ForegroundColor White "    TEP IPs: ${WLDEdgeNode2TEP1IP}, ${WLDEdgeNode2TEP2IP}"
        Write-Host -ForegroundColor White "    TEP VLAN: $WLDEdgeTEPVLAN"
        Write-Host -ForegroundColor White "    Uplink1: ${WLDEdgeNode2Uplink1IP}/${WLDEdgeUplink1Prefix} (VLAN $WLDEdgeUplink1VLAN)"
        if ($WLDEdgeNode2Uplink2IP -ne "") {
            Write-Host -ForegroundColor White "    Uplink2: ${WLDEdgeNode2Uplink2IP}/${WLDEdgeUplink2Prefix} (VLAN $WLDEdgeUplink2VLAN)"
        } else {
            Write-Host -ForegroundColor DarkGray "    Uplink2: Not configured (single uplink mode)"
        }

        # Build and display the spec
        Write-Host -ForegroundColor Cyan "`n  Edge Cluster Spec (would be sent to API):"
        $wldSpecResult = Build-EdgeClusterSpec `
            -DomainType "WLD" `
            -ClusterName $VCFWorkloadDomainVCSAClusterName `
            -EdgeClusterName $WLDEdgeClusterName `
            -EdgeFormFactor $WLDEdgeFormFactor `
            -EdgeNode1Name $WLDEdgeNode1Name `
            -EdgeNode1MgmtIP $WLDEdgeNode1MgmtIP `
            -EdgeNode1TEP1IP $WLDEdgeNode1TEP1IP `
            -EdgeNode1TEP2IP $WLDEdgeNode1TEP2IP `
            -EdgeNode2Name $WLDEdgeNode2Name `
            -EdgeNode2MgmtIP $WLDEdgeNode2MgmtIP `
            -EdgeNode2TEP1IP $WLDEdgeNode2TEP1IP `
            -EdgeNode2TEP2IP $WLDEdgeNode2TEP2IP `
            -EdgeMgmtPrefix $WLDEdgeMgmtPrefix `
            -EdgeTEPVLAN $WLDEdgeTEPVLAN `
            -EdgeTEPGateway $WLDEdgeTEPGateway `
            -EdgeTEPPrefix $WLDEdgeTEPPrefix `
            -Tier0Name $WLDEdgeTier0Name `
            -Tier0ASN $WLDEdgeTier0ASN `
            -BGPPeerASN $WLDEdgeBGPPeerASN `
            -ManagementGateway $ESXWLDGateway `
            -Uplink1VLAN $WLDEdgeUplink1VLAN `
            -Uplink1Prefix $WLDEdgeUplink1Prefix `
            -Uplink1Gateway $WLDEdgeUplink1Gateway `
            -EdgeNode1Uplink1IP $WLDEdgeNode1Uplink1IP `
            -EdgeNode2Uplink1IP $WLDEdgeNode2Uplink1IP `
            -Uplink2VLAN $WLDEdgeUplink2VLAN `
            -Uplink2Prefix $WLDEdgeUplink2Prefix `
            -Uplink2Gateway $WLDEdgeUplink2Gateway `
            -EdgeNode1Uplink2IP $WLDEdgeNode1Uplink2IP `
            -EdgeNode2Uplink2IP $WLDEdgeNode2Uplink2IP

        $wldSpecResult.spec | ConvertTo-Json -Depth 10 | ForEach-Object { Write-Host -ForegroundColor DarkGray "    $_" }
    }

    # ==================== SUMMARY ====================
    Write-Host -ForegroundColor Magenta @"

╔═══════════════════════════════════════════════════════════════════╗
║                    WHATIF SUMMARY                                 ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    
    $allGood = $true
    Write-Host -ForegroundColor White "`n  Checklist:"

    if ($headers) {
        Write-Host -ForegroundColor Green "  [✓] SDDC Manager connectivity"
    } else {
        Write-Host -ForegroundColor Red "  [✗] SDDC Manager connectivity"
        $allGood = $false
    }

    if ($DeploymentTarget -eq "MGMT" -or $DeploymentTarget -eq "BOTH") {
        if ($mgmtClusterId) {
            Write-Host -ForegroundColor Green "  [✓] MGMT cluster found: $VCSAClusterName"
        } else {
            Write-Host -ForegroundColor Red "  [✗] MGMT cluster NOT found: $VCSAClusterName"
            $allGood = $false
        }
        
        if ($mgmtClusterHosts.Count -ge 2) {
            Write-Host -ForegroundColor Green "  [✓] MGMT cluster has sufficient hosts ($($mgmtClusterHosts.Count))"
        } else {
            Write-Host -ForegroundColor Red "  [✗] MGMT cluster needs at least 2 hosts (has $($mgmtClusterHosts.Count))"
            $allGood = $false
        }
    }

    if ($DeploymentTarget -eq "WLD" -or $DeploymentTarget -eq "BOTH") {
        if ($wldClusterId) {
            Write-Host -ForegroundColor Green "  [✓] WLD cluster found: $VCFWorkloadDomainVCSAClusterName"
        } else {
            Write-Host -ForegroundColor Red "  [✗] WLD cluster NOT found: $VCFWorkloadDomainVCSAClusterName"
            $allGood = $false
        }
        
        if ($wldClusterHosts.Count -ge 2) {
            Write-Host -ForegroundColor Green "  [✓] WLD cluster has sufficient hosts ($($wldClusterHosts.Count))"
        } else {
            Write-Host -ForegroundColor Red "  [✗] WLD cluster needs at least 2 hosts (has $($wldClusterHosts.Count))"
            $allGood = $false
        }
    }

    Write-Host ""
    if ($allGood) {
        Write-Host -ForegroundColor Green "  All prerequisites satisfied. Ready to deploy."
        Write-Host -ForegroundColor White "  Run without -WhatIf to proceed with actual deployment."
    } else {
        Write-Host -ForegroundColor Red "  Some prerequisites are missing. Please resolve before deployment."
    }
    
    Write-Host -ForegroundColor Magenta "`n  ─────────────────────────────────────────────────────────────────"
    Write-Host -ForegroundColor Magenta "  WhatIf mode complete. No changes were made."
    Write-Host -ForegroundColor Magenta "  ─────────────────────────────────────────────────────────────────`n"
    
    exit 0
}

# ==========================================================================
# Actual Deployment (when -WhatIf is NOT specified)
# ==========================================================================

if ($DeploymentTarget -eq "MGMT" -or $DeploymentTarget -eq "BOTH") {
    Write-Host -ForegroundColor Yellow "`n=== Management Domain Edge Cluster Deployment ==="
    Write-Host -ForegroundColor White "  Edge Cluster Name: $MGMTEdgeClusterName"
    Write-Host -ForegroundColor White "  Edge Nodes: $MGMTEdgeNode1Name, $MGMTEdgeNode2Name"
    Write-Host -ForegroundColor White "  Edge TEP VLAN: $MGMTEdgeTEPVLAN"
    Write-Host -ForegroundColor White "  Tier-0 Gateway: $MGMTEdgeTier0Name"

    $mgmtParams = @{
        DomainType         = "MGMT"
        ClusterName        = $VCSAClusterName
        EdgeClusterName    = $MGMTEdgeClusterName
        EdgeFormFactor     = $MGMTEdgeFormFactor
        EdgeNode1Name      = $MGMTEdgeNode1Name
        EdgeNode1MgmtIP    = $MGMTEdgeNode1MgmtIP
        EdgeNode1TEP1IP    = $MGMTEdgeNode1TEP1IP
        EdgeNode1TEP2IP    = $MGMTEdgeNode1TEP2IP
        EdgeNode2Name      = $MGMTEdgeNode2Name
        EdgeNode2MgmtIP    = $MGMTEdgeNode2MgmtIP
        EdgeNode2TEP1IP    = $MGMTEdgeNode2TEP1IP
        EdgeNode2TEP2IP    = $MGMTEdgeNode2TEP2IP
        EdgeMgmtPrefix     = $MGMTEdgeMgmtPrefix
        EdgeTEPVLAN        = $MGMTEdgeTEPVLAN
        EdgeTEPGateway     = $MGMTEdgeTEPGateway
        EdgeTEPPrefix      = $MGMTEdgeTEPPrefix
        Tier0Name          = $MGMTEdgeTier0Name
        Tier0ASN           = $MGMTEdgeTier0ASN
        BGPPeerASN         = $MGMTEdgeBGPPeerASN
        ManagementGateway  = $VMMGMTGateway
        Uplink1VLAN        = $MGMTEdgeUplink1VLAN
        Uplink1Prefix      = $MGMTEdgeUplink1Prefix
        Uplink1Gateway     = $MGMTEdgeUplink1Gateway
        EdgeNode1Uplink1IP = $MGMTEdgeNode1Uplink1IP
        EdgeNode2Uplink1IP = $MGMTEdgeNode2Uplink1IP
        Uplink2VLAN        = $MGMTEdgeUplink2VLAN
        Uplink2Prefix      = $MGMTEdgeUplink2Prefix
        Uplink2Gateway     = $MGMTEdgeUplink2Gateway
        EdgeNode1Uplink2IP = $MGMTEdgeNode1Uplink2IP
        EdgeNode2Uplink2IP = $MGMTEdgeNode2Uplink2IP
    }

    $mgmtSuccess = Deploy-EdgeCluster @mgmtParams

    if ($mgmtSuccess) {
        My-Logger "Management Domain Edge Cluster deployed successfully!"
    } else {
        My-Logger "Management Domain Edge Cluster deployment failed!" "red"
    }
}

if ($DeploymentTarget -eq "WLD" -or $DeploymentTarget -eq "BOTH") {
    Write-Host -ForegroundColor Yellow "`n=== Workload Domain Edge Cluster Deployment ==="
    Write-Host -ForegroundColor White "  Edge Cluster Name: $WLDEdgeClusterName"
    Write-Host -ForegroundColor White "  Edge Nodes: $WLDEdgeNode1Name, $WLDEdgeNode2Name"
    Write-Host -ForegroundColor White "  Edge TEP VLAN: $WLDEdgeTEPVLAN"
    Write-Host -ForegroundColor White "  Tier-0 Gateway: $WLDEdgeTier0Name"

    $wldParams = @{
        DomainType         = "WLD"
        ClusterName        = $VCFWorkloadDomainVCSAClusterName
        EdgeClusterName    = $WLDEdgeClusterName
        EdgeFormFactor     = $WLDEdgeFormFactor
        EdgeNode1Name      = $WLDEdgeNode1Name
        EdgeNode1MgmtIP    = $WLDEdgeNode1MgmtIP
        EdgeNode1TEP1IP    = $WLDEdgeNode1TEP1IP
        EdgeNode1TEP2IP    = $WLDEdgeNode1TEP2IP
        EdgeNode2Name      = $WLDEdgeNode2Name
        EdgeNode2MgmtIP    = $WLDEdgeNode2MgmtIP
        EdgeNode2TEP1IP    = $WLDEdgeNode2TEP1IP
        EdgeNode2TEP2IP    = $WLDEdgeNode2TEP2IP
        EdgeMgmtPrefix     = $WLDEdgeMgmtPrefix
        EdgeTEPVLAN        = $WLDEdgeTEPVLAN
        EdgeTEPGateway     = $WLDEdgeTEPGateway
        EdgeTEPPrefix      = $WLDEdgeTEPPrefix
        Tier0Name          = $WLDEdgeTier0Name
        Tier0ASN           = $WLDEdgeTier0ASN
        BGPPeerASN         = $WLDEdgeBGPPeerASN
        ManagementGateway  = $ESXWLDGateway
        Uplink1VLAN        = $WLDEdgeUplink1VLAN
        Uplink1Prefix      = $WLDEdgeUplink1Prefix
        Uplink1Gateway     = $WLDEdgeUplink1Gateway
        EdgeNode1Uplink1IP = $WLDEdgeNode1Uplink1IP
        EdgeNode2Uplink1IP = $WLDEdgeNode2Uplink1IP
        Uplink2VLAN        = $WLDEdgeUplink2VLAN
        Uplink2Prefix      = $WLDEdgeUplink2Prefix
        Uplink2Gateway     = $WLDEdgeUplink2Gateway
        EdgeNode1Uplink2IP = $WLDEdgeNode1Uplink2IP
        EdgeNode2Uplink2IP = $WLDEdgeNode2Uplink2IP
    }

    $wldSuccess = Deploy-EdgeCluster @wldParams

    if ($wldSuccess) {
        My-Logger "Workload Domain Edge Cluster deployed successfully!"
    } else {
        My-Logger "Workload Domain Edge Cluster deployment failed!" "red"
    }
}

$EndTime  = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes, 2)

My-Logger "`nEdge Cluster Deployment Complete!"
My-Logger "  StartTime: $StartTime"
My-Logger "  EndTime:   $EndTime"
My-Logger "  Duration:  $duration minutes"