# Author: Daniel Sjödin
# Purpose: Deploy and Configure Supervisor Cluster (VKS) in Workload Domain
# Compatible with VCF 9.x with NSX Networking
#
#Version 2.1
#
# All configuration variables must be defined in the config file passed via -EnvConfigFile
# Required variables: See VCFEdgeSupervisorConfig.ps1

param (
    [string]$EnvConfigFile,
    [switch]$ValidateOnly,
    [switch]$SkipPreChecks,
    [switch]$WhatIf
)

# Validate that the file exists
if ($EnvConfigFile -and (Test-Path $EnvConfigFile)) {
    . $EnvConfigFile  # Dot-sourcing the config file
} else {
    Write-Host -ForegroundColor Red "`nNo valid deployment configuration file was provided or file was not found.`n"
    exit
}

#### DO NOT EDIT BEYOND HERE ####

$verboseLogFile = "vcf-supervisor-cluster-deployment.log"
$wldVCenterFQDN = "${VCFWorkloadDomainVCSAHostname}.${VMDomain}"

$StartTime = Get-Date

Function My-Logger {
    param(
        [Parameter(Mandatory=$true)][String]$message,
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

Function Get-WLDManagementNetworkFromSDDCM {
    <#
    .SYNOPSIS
        Gets the management network portgroup name for the WLD domain from SDDC Manager
    .DESCRIPTION
        Queries SDDC Manager for the WLD domain's cluster network configuration and returns
        the portgroup with transportType = "MANAGEMENT" or "VM_MANAGEMENT"
        
        Note: The transportType is VCF-specific metadata stored in SDDC Manager, 
        not a native vSphere/vCenter property. VDS portgroups in vCenter do not have
        transportType - only SDDC Manager tracks this information.
    .OUTPUTS
        Hashtable with portGroupName, vdsName, and transportType, or $null if not found
    #>
    param(
        [Parameter(Mandatory=$true)][String]$DomainName
    )

    $headers = Get-VCFSDDCmToken
    if (-not $headers) {
        My-Logger "Failed to get SDDC Manager token" "red"
        return $null
    }

    try {
        # Get all domains
        $domainsResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/domains" -Method GET -SkipCertificateCheck -Headers $headers
        $domains = ($domainsResponse.Content | ConvertFrom-Json).elements
        
        # Find the WLD domain
        $wldDomain = $domains | Where-Object { $_.name -eq $DomainName }
        
        if (-not $wldDomain) {
            My-Logger "Domain '$DomainName' not found in SDDC Manager" "red"
            My-Logger "Available domains: $(($domains | Select-Object -ExpandProperty name) -join ', ')" "yellow"
            return $null
        }

        My-Logger "Found WLD domain '$DomainName' with ID: $($wldDomain.id)"

        # Get the cluster from the domain
        if (-not $wldDomain.clusters -or $wldDomain.clusters.Count -eq 0) {
            My-Logger "No clusters found in domain '$DomainName'" "red"
            return $null
        }
        
        $clusterId = $wldDomain.clusters[0].id
        My-Logger "Querying cluster ID: $clusterId for network configuration..."
        
        # Get cluster details which includes VDS and portgroup info with transportType
        $clusterResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/clusters/$clusterId" -Method GET -SkipCertificateCheck -Headers $headers
        $cluster = ($clusterResponse.Content | ConvertFrom-Json)

        # Get VDS specs which contain the portgroup information with transport types
        $vdsSpecs = $cluster.vdsSpecs
        
        if (-not $vdsSpecs) {
            My-Logger "No VDS specs found for cluster '$($cluster.name)'" "yellow"
            return $null
        }

        # Search through all VDS and their portgroups for MANAGEMENT or VM_MANAGEMENT type
        My-Logger "Searching portgroups for MANAGEMENT transport type..." "cyan"
        
        foreach ($vds in $vdsSpecs) {
            My-Logger "  Checking VDS: $($vds.name)" "cyan"
            
            if (-not $vds.portGroupSpecs) {
                My-Logger "    No portgroups defined on this VDS" "yellow"
                continue
            }
            
            foreach ($pg in $vds.portGroupSpecs) {
                My-Logger "    Portgroup: $($pg.name) - TransportType: $($pg.transportType)" "cyan"
                
                # Look for MANAGEMENT or VM_MANAGEMENT transport type
                # VM_MANAGEMENT is what Supervisor needs for the control plane network
                if ($pg.transportType -eq "MANAGEMENT" -or $pg.transportType -eq "VM_MANAGEMENT") {
                    My-Logger "Found management network portgroup: $($pg.name) (TransportType: $($pg.transportType))" "green"
                    return @{
                        "portGroupName" = $pg.name
                        "vdsName" = $vds.name
                        "transportType" = $pg.transportType
                    }
                }
            }
        }

        My-Logger "No portgroup with MANAGEMENT or VM_MANAGEMENT transport type found in domain '$DomainName'" "yellow"
        return $null

    } catch {
        My-Logger "Failed to query SDDC Manager for management network: $($_.Exception.Message)" "red"
        return $null
    }
}

Function Get-AllNetworksFromSDDCM {
    <#
    .SYNOPSIS
        Gets ALL network information from SDDC Manager for a domain (used by -WhatIf)
    .DESCRIPTION
        Queries SDDC Manager for complete network configuration including all VDS and portgroups
        with their transportType metadata. Returns full details for display.
    .OUTPUTS
        Hashtable with domain info, cluster info, and all VDS/portgroup details
    #>
    param(
        [Parameter(Mandatory=$true)][String]$DomainName
    )

    $result = @{
        "domain" = $null
        "cluster" = $null
        "vdsSpecs" = @()
        "allPortgroups" = @()
        "rawClusterData" = $null
        "error" = $null
    }

    $headers = Get-VCFSDDCmToken
    if (-not $headers) {
        $result.error = "Failed to get SDDC Manager token"
        return $result
    }

    try {
        # Get all domains
        $domainsResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/domains" -Method GET -SkipCertificateCheck -Headers $headers
        $domains = ($domainsResponse.Content | ConvertFrom-Json).elements
        
        $wldDomain = $domains | Where-Object { $_.name -eq $DomainName }
        
        if (-not $wldDomain) {
            $result.error = "Domain '$DomainName' not found. Available: $(($domains | Select-Object -ExpandProperty name) -join ', ')"
            return $result
        }

        $result.domain = @{
            "name" = $wldDomain.name
            "id" = $wldDomain.id
            "type" = $wldDomain.type
            "status" = $wldDomain.status
        }

        if ($wldDomain.clusters -and $wldDomain.clusters.Count -gt 0) {
            $clusterId = $wldDomain.clusters[0].id
            
            $clusterResponse = Invoke-WebRequest -Uri "https://${SddcManagerIP}/v1/clusters/$clusterId" -Method GET -SkipCertificateCheck -Headers $headers
            $cluster = ($clusterResponse.Content | ConvertFrom-Json)

            # Store raw cluster data for debugging
            $result.rawClusterData = $cluster

            $result.cluster = @{
                "name" = $cluster.name
                "id" = $cluster.id
                "primaryDatastoreType" = $cluster.primaryDatastoreType
            }

            # Check for vdsSpecs (VCF 9.x structure)
            if ($cluster.vdsSpecs) {
                $result.vdsSpecs = $cluster.vdsSpecs
                
                foreach ($vds in $cluster.vdsSpecs) {
                    if ($vds.portGroupSpecs) {
                        foreach ($pg in $vds.portGroupSpecs) {
                            $result.allPortgroups += @{
                                "vdsName" = $vds.name
                                "portGroupName" = $pg.name
                                "transportType" = if ($pg.transportType) { $pg.transportType } else { "N/A" }
                                "vlanId" = if ($pg.vlanId) { $pg.vlanId } else { "N/A" }
                            }
                        }
                    }
                }
            }
            
            # Also check for networkSpecs (alternative structure in some VCF versions)
            if ($cluster.networkSpecs -and $result.allPortgroups.Count -eq 0) {
                foreach ($net in $cluster.networkSpecs) {
                    $result.allPortgroups += @{
                        "vdsName" = "N/A (from networkSpecs)"
                        "portGroupName" = if ($net.portGroupKey) { $net.portGroupKey } else { $net.networkType }
                        "transportType" = $net.networkType
                        "vlanId" = if ($net.vlanId) { $net.vlanId } else { "N/A" }
                    }
                }
            }
        }

        return $result

    } catch {
        $result.error = $_.Exception.Message
        return $result
    }
}

Function Get-AllNetworksFromvCenter {
    <#
    .SYNOPSIS
        Gets ALL networks from vCenter (used by -WhatIf)
    .DESCRIPTION
        Queries vCenter for all networks to display what's available
    .OUTPUTS
        Array of network objects
    #>
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
    }

    try {
        $networkResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/vcenter/network" -Method GET -SkipCertificateCheck -Headers $headers
        $networks = ($networkResponse.Content | ConvertFrom-Json)
        return $networks
    } catch {
        return @()
    }
}

Function Get-vCenterToken {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$Username,
        [Parameter(Mandatory=$true)][String]$Password
    )

    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))

    try {
        $response = Invoke-WebRequest -Uri "https://${vCenterServer}/api/session" -Method POST -SkipCertificateCheck -Headers @{"Authorization"="Basic $base64AuthInfo"}
        if ($response.StatusCode -eq 201) {
            $sessionToken = ($response.Content | ConvertFrom-Json)
            return $sessionToken
        }
    } catch {
        My-Logger "Failed to get vCenter session token: $($_.Exception.Message)" "red"
        return $null
    }
}

Function Get-WLDClusterMoRef {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$true)][String]$ClusterName
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
    }

    try {
        $response = Invoke-WebRequest -Uri "https://${vCenterServer}/api/vcenter/cluster" -Method GET -SkipCertificateCheck -Headers $headers
        $clusters = ($response.Content | ConvertFrom-Json)
        $cluster = $clusters | Where-Object { $_.name -eq $ClusterName }
        
        if ($cluster) {
            return $cluster.cluster
        }
    } catch {
        My-Logger "Failed to get cluster MoRef: $($_.Exception.Message)" "red"
    }
    return $null
}

Function Get-StoragePolicy {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$true)][String]$PolicyName
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
    }

    try {
        $response = Invoke-WebRequest -Uri "https://${vCenterServer}/api/vcenter/storage/policies" -Method GET -SkipCertificateCheck -Headers $headers
        $policies = ($response.Content | ConvertFrom-Json)
        $policy = $policies | Where-Object { $_.name -like "*$PolicyName*" }
        
        if ($policy) {
            return ($policy | Select-Object -First 1).policy
        }
    } catch {
        My-Logger "Failed to get storage policy: $($_.Exception.Message)" "red"
    }
    return $null
}

Function Get-NSXEdgeClusterId {
    param(
        [Parameter(Mandatory=$true)][String]$NSXManager,
        [Parameter(Mandatory=$true)][String]$NSXPassword,
        [Parameter(Mandatory=$true)][String]$EdgeClusterName
    )

    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:${NSXPassword}"))

    try {
        $headers = @{
            "Authorization" = "Basic $base64AuthInfo"
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-WebRequest -Uri "https://${NSXManager}/api/v1/edge-clusters" -Method GET -SkipCertificateCheck -Headers $headers
        $edgeClusters = ($response.Content | ConvertFrom-Json).results
        $edgeCluster = $edgeClusters | Where-Object { $_.display_name -eq $EdgeClusterName }
        
        if ($edgeCluster) {
            return $edgeCluster.id
        }
    } catch {
        My-Logger "Failed to get NSX Edge Cluster ID: $($_.Exception.Message)" "red"
    }
    return $null
}

Function Get-NSXTier0Id {
    param(
        [Parameter(Mandatory=$true)][String]$NSXManager,
        [Parameter(Mandatory=$true)][String]$NSXPassword,
        [Parameter(Mandatory=$true)][String]$Tier0Name
    )

    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:${NSXPassword}"))

    try {
        $headers = @{
            "Authorization" = "Basic $base64AuthInfo"
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-WebRequest -Uri "https://${NSXManager}/policy/api/v1/infra/tier-0s" -Method GET -SkipCertificateCheck -Headers $headers
        $tier0s = ($response.Content | ConvertFrom-Json).results
        $tier0 = $tier0s | Where-Object { $_.display_name -eq $Tier0Name }
        
        if ($tier0) {
            return $tier0.id
        }
    } catch {
        My-Logger "Failed to get NSX Tier-0 ID: $($_.Exception.Message)" "red"
    }
    return $null
}

Function Get-DVSwitchUUID {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$false)][String]$DVSName = ""
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
    }

    try {
        $response = Invoke-WebRequest -Uri "https://${vCenterServer}/api/vcenter/namespace-management/networks/nsx/distributed-switches" -Method GET -SkipCertificateCheck -Headers $headers
        $switches = ($response.Content | ConvertFrom-Json)
        
        if ($DVSName -and $DVSName -ne "") {
            $dvs = $switches | Where-Object { $_.name -eq $DVSName }
        } else {
            # Auto-select first available DVS
            $dvs = $switches | Select-Object -First 1
            if ($dvs) {
                My-Logger "Auto-discovered DVS: $($dvs.name)"
            }
        }
        
        if ($dvs) {
            return @{
                "name" = $dvs.name
                "uuid" = $dvs.distributed_switch
            }
        }
    } catch {
        My-Logger "Failed to get DVS UUID: $($_.Exception.Message)" "red"
    }
    return $null
}

Function Get-vCenterNetworkByName {
    <#
    .SYNOPSIS
        Gets a vCenter network object by its name
    .DESCRIPTION
        Queries vCenter for all networks and returns the one matching the specified name.
        Used to get the network MoRef after we know the portgroup name from SDDC Manager.
    .OUTPUTS
        Network object with name and network (MoRef), or $null if not found
    #>
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$true)][String]$NetworkName
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
    }

    try {
        $networkResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/vcenter/network" -Method GET -SkipCertificateCheck -Headers $headers
        $networks = ($networkResponse.Content | ConvertFrom-Json)
        
        $network = $networks | Where-Object { $_.name -eq $NetworkName } | Select-Object -First 1
        
        if ($network) {
            return $network
        } else {
            My-Logger "Network '$NetworkName' not found in vCenter" "yellow"
            return $null
        }
    } catch {
        My-Logger "Failed to get network from vCenter: $($_.Exception.Message)" "red"
        return $null
    }
}

Function Create-ContentLibrary {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$true)][String]$LibraryName,
        [Parameter(Mandatory=$true)][String]$SubscriptionURL,
        [Parameter(Mandatory=$true)][String]$DatastoreName,
        [Parameter(Mandatory=$false)][Switch]$SkipSubscribed = $false
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
        "Content-Type" = "application/json"
    }

    # Get datastore ID
    try {
        $dsResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/vcenter/datastore" -Method GET -SkipCertificateCheck -Headers $headers
        $datastores = ($dsResponse.Content | ConvertFrom-Json)
        $datastore = $datastores | Where-Object { $_.name -like "*$DatastoreName*" -or $_.name -like "*vsan*" } | Select-Object -First 1
        
        if (-not $datastore) {
            $datastore = $datastores | Select-Object -First 1
        }
        $datastoreId = $datastore.datastore
        My-Logger "Using datastore: $($datastore.name) ($datastoreId)"
    } catch {
        My-Logger "Failed to get datastore: $($_.Exception.Message)" "red"
        return $null
    }

    # Check if any content library already exists
    try {
        $libResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/content/library" -Method GET -SkipCertificateCheck -Headers $headers
        $libraries = ($libResponse.Content | ConvertFrom-Json)
        
        foreach ($libId in $libraries) {
            $libDetailResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/content/library/$libId" -Method GET -SkipCertificateCheck -Headers $headers
            $libDetail = ($libDetailResponse.Content | ConvertFrom-Json)
            
            # Check for exact name match
            if ($libDetail.name -eq $LibraryName) {
                My-Logger "Content Library '$LibraryName' already exists (ID: $libId)"
                return $libId
            }
            
            # Check for TKG/Tanzu related libraries that might work
            if ($libDetail.name -like "*TKG*" -or $libDetail.name -like "*Tanzu*" -or $libDetail.name -like "*Kubernetes*") {
                My-Logger "Found existing Kubernetes-related library: '$($libDetail.name)' (ID: $libId)" "cyan"
                My-Logger "Using this library instead of creating new one" "cyan"
                return $libId
            }
        }
        
        if ($libraries.Count -gt 0) {
            My-Logger "Found $($libraries.Count) existing content libraries, but none match TKG requirements"
        }
    } catch {
        My-Logger "Error checking existing libraries: $($_.Exception.Message)" "yellow"
    }

    # Try subscribed library first
    if (-not $SkipSubscribed) {
        My-Logger "Attempting to create subscribed content library..."
        
        # Step 1: Probe the subscription URL to get SSL thumbprint
        My-Logger "Probing subscription URL to get SSL certificate thumbprint..."
        $sslThumbprint = ""
        
        $probeSpec = @{
            "subscription_info" = @{
                "subscription_url" = $SubscriptionURL
                "authentication_method" = "NONE"
            }
        }
        $probeBody = $probeSpec | ConvertTo-Json -Depth 10
        
        try {
            $probeResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/content/subscribed-library?action=probe" -Method POST -SkipCertificateCheck -Headers $headers -Body $probeBody
            $probeResult = $probeResponse.Content | ConvertFrom-Json
            
            if ($probeResult.ssl_thumbprint) {
                $sslThumbprint = $probeResult.ssl_thumbprint
                My-Logger "Got SSL thumbprint: $sslThumbprint"
            }
            
            if ($probeResult.status -eq "SUCCESS") {
                My-Logger "Probe successful - URL is reachable from vCenter"
            } else {
                My-Logger "Probe status: $($probeResult.status)" "yellow"
                if ($probeResult.error_messages) {
                    foreach ($err in $probeResult.error_messages) {
                        My-Logger "  Probe error: $($err.default_message)" "yellow"
                    }
                }
            }
        } catch {
            My-Logger "Probe failed: $($_.Exception.Message)" "yellow"
            # Continue anyway - we'll try without thumbprint
        }
        
        # Step 2: Create the subscribed library with the thumbprint
        $librarySpec = @{
            "name" = $LibraryName
            "description" = "TKG Content Library for Supervisor Cluster"
            "type" = "SUBSCRIBED"
            "subscription_info" = @{
                "subscription_url" = $SubscriptionURL
                "authentication_method" = "NONE"
                "automatic_sync_enabled" = $true
                "on_demand" = $true
            }
            "storage_backings" = @(
                @{
                    "datastore_id" = $datastoreId
                    "type" = "DATASTORE"
                }
            )
        }
        
        # Add SSL thumbprint if we got one
        if ($sslThumbprint -ne "") {
            $librarySpec.subscription_info["ssl_thumbprint"] = $sslThumbprint
        }

        $body = $librarySpec | ConvertTo-Json -Depth 10
        
        if ($Debug) {
            My-Logger "DEBUG: Subscribed library spec:" "cyan"
            My-Logger $body "cyan"
        }

        try {
            $response = Invoke-WebRequest -Uri "https://${vCenterServer}/api/content/subscribed-library" -Method POST -SkipCertificateCheck -Headers $headers -Body $body
            $libraryId = ($response.Content | ConvertFrom-Json)
            My-Logger "Created Subscribed Content Library '$LibraryName' with ID: $libraryId" "green"
            return $libraryId
        } catch {
            My-Logger "Subscribed library creation failed: $($_.Exception.Message)" "yellow"
            
            # Try to get detailed error
            try {
                if ($_.ErrorDetails.Message) {
                    $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json
                    if ($errorDetail.messages) {
                        foreach ($msg in $errorDetail.messages) {
                            My-Logger "  API Error: $($msg.default_message)" "yellow"
                        }
                    }
                }
            } catch {}
        }
    }
    
    # Fall back to local library
    My-Logger "Creating local content library instead..."
    
    $localLibrarySpec = @{
        "name" = $LibraryName
        "description" = "TKG Content Library for Supervisor Cluster (Local)"
        "type" = "LOCAL"
        "storage_backings" = @(
            @{
                "datastore_id" = $datastoreId
                "type" = "DATASTORE"
            }
        )
    }
    
    $localBody = $localLibrarySpec | ConvertTo-Json -Depth 10
    
    try {
        $localResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/content/local-library" -Method POST -SkipCertificateCheck -Headers $headers -Body $localBody
        $localLibraryId = ($localResponse.Content | ConvertFrom-Json)
        My-Logger "Created Local Content Library '$LibraryName' with ID: $localLibraryId" "green"
        Write-Host ""
        Write-Host -ForegroundColor Yellow "╔════════════════════════════════════════════════════════════════════╗"
        Write-Host -ForegroundColor Yellow "║  LOCAL CONTENT LIBRARY CREATED                                      ║"
        Write-Host -ForegroundColor Yellow "╚════════════════════════════════════════════════════════════════════╝"
        Write-Host -ForegroundColor White "  Subscribed library failed - using local library instead."
        Write-Host -ForegroundColor White "  The Supervisor will deploy successfully."
        Write-Host ""
        Write-Host -ForegroundColor Cyan "  To add TKG images later:"
        Write-Host -ForegroundColor White "    1. In vCenter UI, create a Subscribed Library manually"
        Write-Host -ForegroundColor White "       (UI handles SSL certificate acceptance)"
        Write-Host -ForegroundColor White "    2. URL: $SubscriptionURL"
        Write-Host -ForegroundColor White "    3. Update Supervisor to use the new library"
        Write-Host ""
        return $localLibraryId
    } catch {
        My-Logger "Failed to create local content library: $($_.Exception.Message)" "red"
        return $null
    }
}

Function Enable-WorkloadManagement {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$true)][String]$ClusterMoRef,
        [Parameter(Mandatory=$true)][String]$StoragePolicyId,
        [Parameter(Mandatory=$true)][String]$ContentLibraryId,
        [Parameter(Mandatory=$true)][String]$EdgeClusterId,
        [Parameter(Mandatory=$true)][String]$Tier0GatewayPath,
        [Parameter(Mandatory=$true)][String]$DVSwitchUUID
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
        "Content-Type" = "application/json"
    }

    # Build Workload Management spec using config variables
    $wmSpec = [ordered]@{
        "size_hint" = $SupervisorClusterSize
        "service_cidr" = @{
            "address" = ($SupervisorServicesCIDR -split "/")[0]
            "prefix" = [int]($SupervisorServicesCIDR -split "/")[1]
        }
        "network_provider" = "NSXT_CONTAINER_PLUGIN"
        "ncp_cluster_network_spec" = [ordered]@{
            "nsx_edge_cluster" = $EdgeClusterId
            "pod_cidrs" = @(
                @{
                    "address" = ($SupervisorPodCIDRs[0] -split "/")[0]
                    "prefix" = [int]($SupervisorPodCIDRs[0] -split "/")[1]
                }
            )
            "ingress_cidrs" = @(
                @{
                    "address" = ($SupervisorIngressCIDR -split "/")[0]
                    "prefix" = [int]($SupervisorIngressCIDR -split "/")[1]
                }
            )
            "egress_cidrs" = @(
                @{
                    "address" = ($SupervisorEgressCIDR -split "/")[0]
                    "prefix" = [int]($SupervisorEgressCIDR -split "/")[1]
                }
            )
            "cluster_distributed_switch" = $DVSwitchUUID
            "nsx_tier0_gateway" = $Tier0GatewayPath
            "namespace_subnet_prefix" = $SupervisorNamespaceNetworkPrefix
            "routed_mode" = $false
        }
        "master_management_network" = [ordered]@{
            "mode" = $SupervisorMgmtNetworkMode
            "address_range" = @{
                "starting_address" = $SupervisorMgmtNetworkStartIP
                "address_count" = $SupervisorMgmtNetworkAddressCount
                "gateway" = $SupervisorMgmtNetworkGateway
                "subnet_mask" = $SupervisorMgmtNetworkSubnetMask
            }
            "network" = $null
        }
        "master_storage_policy" = $StoragePolicyId
        "ephemeral_storage_policy" = $StoragePolicyId
        "master_DNS" = @($VMDNS)
        "worker_DNS" = @($VMDNS)
        "master_DNS_search_domains" = @($VMDomain)
        "master_NTP_servers" = @($VMNTP)
        "default_kubernetes_service_content_library" = $ContentLibraryId
        "image_storage" = @{
            "storage_policy" = $StoragePolicyId
        }
    }

    # ==========================================================================
    # Get management network from SDDC Manager based on transportType
    # 
    # Note: The transportType (MANAGEMENT, VM_MANAGEMENT, VMOTION, VSAN, etc.)
    # is VCF-specific metadata stored only in SDDC Manager. vCenter/VDS does NOT
    # have this property on portgroups - it only knows name, VLAN, and other 
    # standard vSphere properties.
    # ==========================================================================
    My-Logger "Querying SDDC Manager for management network (transportType = MANAGEMENT or VM_MANAGEMENT)..."
    $mgmtNetworkInfo = Get-WLDManagementNetworkFromSDDCM -DomainName $VCFWorkloadDomainName
    
    $mgmtNetwork = $null
    if ($mgmtNetworkInfo) {
        My-Logger "SDDC Manager returned management portgroup: $($mgmtNetworkInfo.portGroupName)"
        
        # Now get the vCenter MoRef for this portgroup name
        $mgmtNetwork = Get-vCenterNetworkByName -vCenterServer $vCenterServer -SessionToken $SessionToken -NetworkName $mgmtNetworkInfo.portGroupName
    }

    # Fallback: If SDDC Manager query failed, list available networks for manual selection
    if (-not $mgmtNetwork) {
        My-Logger "SDDC Manager lookup failed or returned no result" "yellow"
        My-Logger "Listing all available networks in vCenter for reference..." "yellow"
        
        try {
            $networkResponse = Invoke-WebRequest -Uri "https://${vCenterServer}/api/vcenter/network" -Method GET -SkipCertificateCheck -Headers $headers
            $networks = ($networkResponse.Content | ConvertFrom-Json)
            
            My-Logger "Available networks in vCenter:" "cyan"
            foreach ($net in $networks) {
                My-Logger "  - $($net.name) (Type: $($net.type), MoRef: $($net.network))" "cyan"
            }
            
            # Last resort: try to find by naming pattern (VCF naming convention)
            # Priority: vm_management (for VMs) > management (for ESXi hosts)
            My-Logger "Attempting pattern-based fallback (looking for VM management portgroup)..." "yellow"
            
            # First try: vm_management (this is where Supervisor VMs should go)
            $mgmtNetwork = $networks | Where-Object { 
                $_.name -like "*vm_management*" -and 
                $_.type -eq "DISTRIBUTED_PORTGROUP"
            } | Select-Object -First 1
            
            # Second try: VM_MANAGEMENT with different naming
            if (-not $mgmtNetwork) {
                $mgmtNetwork = $networks | Where-Object { 
                    $_.name -like "*-vm-management*" -and 
                    $_.type -eq "DISTRIBUTED_PORTGROUP"
                } | Select-Object -First 1
            }
            
            # Third try: fall back to management (less ideal but might work)
            if (-not $mgmtNetwork) {
                My-Logger "No vm_management portgroup found, trying management portgroup..." "yellow"
                $mgmtNetwork = $networks | Where-Object { 
                    $_.name -like "*-management" -and 
                    $_.name -notlike "*vm_management*" -and
                    $_.name -notlike "*External*" -and 
                    $_.name -notlike "*edge*" -and
                    $_.type -eq "DISTRIBUTED_PORTGROUP"
                } | Select-Object -First 1
            }
            
        } catch {
            My-Logger "Failed to list networks from vCenter: $($_.Exception.Message)" "red"
        }
    }
    
    if ($mgmtNetwork) {
        $wmSpec.master_management_network.network = $mgmtNetwork.network
        My-Logger "Using management network: $($mgmtNetwork.name) (MoRef: $($mgmtNetwork.network))"
    } else {
        My-Logger "ERROR: Could not determine management network!" "red"
        My-Logger "Please verify:" "red"
        My-Logger "  1. The WLD domain '$VCFWorkloadDomainName' exists in SDDC Manager" "red"
        My-Logger "  2. The domain has a portgroup with transportType = MANAGEMENT or VM_MANAGEMENT" "red"
        My-Logger "  3. SDDC Manager is accessible at $SddcManagerIP" "red"
        return $false
    }

    $body = $wmSpec | ConvertTo-Json -Depth 10

    if ($Debug) {
        My-Logger "DEBUG: Workload Management Spec:" "cyan"
        $body | Out-File -LiteralPath "supervisor-cluster-spec.json"
        My-Logger "Spec saved to supervisor-cluster-spec.json" "cyan"
    }

    My-Logger "Enabling Workload Management on cluster $ClusterMoRef..."

    try {
        $uri = "https://${vCenterServer}/api/vcenter/namespace-management/clusters/${ClusterMoRef}?action=enable"
        $response = Invoke-WebRequest -Uri $uri -Method POST -SkipCertificateCheck -Headers $headers -Body $body
        
        if ($response.StatusCode -eq 204 -or $response.StatusCode -eq 200) {
            My-Logger "Workload Management enablement initiated successfully"
            return $true
        }
    } catch {
        My-Logger "Failed to enable Workload Management: $($_.Exception.Message)" "red"
        
        try {
            $errorContent = $_.ErrorDetails.Message
            My-Logger "Error details: $errorContent" "red"
        } catch {}
        
        return $false
    }
}

Function Wait-SupervisorCluster {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$true)][String]$ClusterMoRef,
        [Parameter(Mandatory=$false)][Int]$TimeoutMinutes = 60
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
    }

    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $TimeoutMinutes
    $lastConditionsHash = ""

    My-Logger "Monitoring Supervisor deployment progress via conditions..."

    while ((Get-Date) - $startTime -lt $timeout) {
        try {
            # Refresh session token every 15 minutes
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalMinutes -gt 0 -and [math]::Floor($elapsed.TotalMinutes) % 15 -eq 0) {
                $newToken = Get-vCenterToken -vCenterServer $vCenterServer -Username "administrator@vsphere.local" -Password $VCFWorkloadDomainVCSASSOPassword
                if ($newToken) {
                    $SessionToken = $newToken
                    $headers = @{ "vmware-api-session-id" = $SessionToken }
                }
            }

            $uri = "https://${vCenterServer}/api/vcenter/namespace-management/clusters/${ClusterMoRef}"
            $response = Invoke-WebRequest -Uri $uri -Method GET -SkipCertificateCheck -Headers $headers
            $status = ($response.Content | ConvertFrom-Json)

            $configStatus = $status.config_status
            $kubernetesStatus = $status.kubernetes_status
            $apiEndpoint = $status.api_server_cluster_endpoint
            $conditions = $status.conditions
            
            # Calculate elapsed time for display
            $elapsedStr = "{0:00}:{1:00}" -f [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

            # Check conditions for real progress
            $conditionsSummary = @()
            $allConditionsTrue = $true
            $conditionsHash = ""
            
            if ($conditions) {
                foreach ($cond in $conditions) {
                    $condStatus = if ($cond.status -eq "TRUE") { "✓" } else { "○" }
                    $condName = $cond.type
                    $conditionsHash += "$condName=$($cond.status);"
                    
                    if ($cond.status -ne "TRUE") {
                        $allConditionsTrue = $false
                    }
                    
                    $conditionsSummary += "$condStatus $condName"
                }
            }

            # Success: config_status is RUNNING or all conditions are TRUE
            if ($configStatus -eq "RUNNING" -or ($allConditionsTrue -and $conditions.Count -gt 0)) {
                Write-Host ""
                My-Logger "═══════════════════════════════════════════════════════════════" "green"
                My-Logger "  Supervisor Cluster is now RUNNING!" "green"
                My-Logger "═══════════════════════════════════════════════════════════════" "green"
                My-Logger "  Config Status: $configStatus"
                My-Logger "  Kubernetes Status: $kubernetesStatus"
                if ($apiEndpoint) {
                    My-Logger "  API Server Endpoint: $apiEndpoint" "cyan"
                }
                Write-Host ""
                My-Logger "  Final Conditions:" "cyan"
                foreach ($summary in $conditionsSummary) {
                    My-Logger "    $summary" "green"
                }
                return $true
            }
            
            # Real failure: config_status is ERROR (not just kubernetes_status)
            if ($configStatus -eq "ERROR") {
                Write-Host ""
                My-Logger "Supervisor Cluster configuration FAILED!" "red"
                if ($status.messages -and $status.messages.Count -gt 0) {
                    My-Logger "Error Messages:" "red"
                    foreach ($msg in $status.messages) {
                        My-Logger "  - $($msg.message)" "red"
                    }
                }
                if ($status.kubernetes_status_messages) {
                    My-Logger "Kubernetes Status Messages:" "yellow"
                    foreach ($msg in $status.kubernetes_status_messages) {
                        My-Logger "  [$($msg.severity)] $($msg.details.default_message)" "yellow"
                    }
                }
                $status | ConvertTo-Json -Depth 10 | Out-File "supervisor-cluster-error.json"
                My-Logger "Full status saved to supervisor-cluster-error.json" "yellow"
                return $false
            }

            # Still in progress - show conditions if changed
            if ($conditionsHash -ne $lastConditionsHash) {
                Write-Host ""
                My-Logger "[$elapsedStr] Deployment Progress (config_status: $configStatus):" "cyan"
                foreach ($cond in $conditions) {
                    $condStatus = if ($cond.status -eq "TRUE") { "✓" } else { "○" }
                    $condColor = if ($cond.status -eq "TRUE") { "green" } else { "yellow" }
                    $condName = $cond.type
                    $condDesc = $cond.description.default_message
                    
                    # Show reason if waiting
                    $extra = ""
                    if ($cond.status -ne "TRUE" -and $cond.reason) {
                        $extra = " ($($cond.reason))"
                    }
                    
                    My-Logger "  $condStatus $condName$extra" $condColor
                }
                
                # Show any kubernetes status messages (informational)
                if ($status.kubernetes_status_messages -and $kubernetesStatus -eq "ERROR") {
                    My-Logger "  K8s Status: Initializing (this is normal during deployment)" "darkgray"
                }
                
                $lastConditionsHash = $conditionsHash
            } else {
                # Just show a heartbeat every 2 minutes
                if ([math]::Floor($elapsed.TotalSeconds) % 120 -eq 0) {
                    $completedCount = ($conditions | Where-Object { $_.status -eq "TRUE" }).Count
                    $totalCount = $conditions.Count
                    My-Logger "[$elapsedStr] Still configuring... ($completedCount/$totalCount conditions complete)" "darkgray"
                }
            }
            
            # Save current status for debugging
            $status | ConvertTo-Json -Depth 10 | Out-File "supervisor-cluster-status.json"
            
            Start-Sleep -Seconds 30
            
        } catch {
            $elapsed = (Get-Date) - $startTime
            $elapsedStr = "{0:00}:{1:00}" -f [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
            My-Logger "[$elapsedStr] Error checking Supervisor status: $($_.Exception.Message)" "yellow"
            
            # Try to refresh token on error
            $newToken = Get-vCenterToken -vCenterServer $vCenterServer -Username "administrator@vsphere.local" -Password $VCFWorkloadDomainVCSASSOPassword
            if ($newToken) {
                $SessionToken = $newToken
                $headers = @{ "vmware-api-session-id" = $SessionToken }
            }
            
            Start-Sleep -Seconds 30
        }
    }

    My-Logger "Supervisor Cluster deployment timed out after $TimeoutMinutes minutes" "red"
    My-Logger "Check vCenter UI for actual status - deployment may still be in progress" "yellow"
    My-Logger "Current conditions saved to supervisor-cluster-status.json" "yellow"
    return $false
}

Function Create-Namespace {
    param(
        [Parameter(Mandatory=$true)][String]$vCenterServer,
        [Parameter(Mandatory=$true)][String]$SessionToken,
        [Parameter(Mandatory=$true)][String]$ClusterMoRef,
        [Parameter(Mandatory=$true)][String]$NamespaceName,
        [Parameter(Mandatory=$true)][String]$StoragePolicyId
    )

    $headers = @{
        "vmware-api-session-id" = $SessionToken
        "Content-Type" = "application/json"
    }

    $namespaceSpec = @{
        "namespace" = $NamespaceName
        "cluster" = $ClusterMoRef
        "description" = "Workload Domain Namespace"
        "storage_specs" = @(
            @{
                "policy" = $StoragePolicyId
            }
        )
    }

    $body = $namespaceSpec | ConvertTo-Json -Depth 5

    try {
        $uri = "https://${vCenterServer}/api/vcenter/namespaces/instances"
        $response = Invoke-WebRequest -Uri $uri -Method POST -SkipCertificateCheck -Headers $headers -Body $body
        
        if ($response.StatusCode -eq 204 -or $response.StatusCode -eq 201) {
            My-Logger "Namespace '$NamespaceName' created successfully"
            return $true
        }
    } catch {
        if ($_.Exception.Message -like "*already exists*") {
            My-Logger "Namespace '$NamespaceName' already exists" "yellow"
            return $true
        }
        My-Logger "Failed to create namespace: $($_.Exception.Message)" "red"
        return $false
    }
}

# Main Execution
$modeIndicator = if ($WhatIf) { " [WHATIF MODE]" } elseif ($ValidateOnly) { " [VALIDATE ONLY]" } else { "" }

Write-Host -ForegroundColor Cyan @"

╔═══════════════════════════════════════════════════════════════════╗
║     VCF 9 Supervisor Cluster Deployment Script$modeIndicator
╠═══════════════════════════════════════════════════════════════════╣
║  Target vCenter: $wldVCenterFQDN
║  Target Cluster: $VCFWorkloadDomainVCSAClusterName
║  Supervisor Size: $SupervisorClusterSize
║  SDDC Manager: $SddcManagerIP
╚═══════════════════════════════════════════════════════════════════╝

"@

# Derive NSX Manager IP from config
$wldNSXManagerIP = $VCFWorkloadDomainNSXManagerNode1IP

if (-not $SkipPreChecks) {
    Write-Host -ForegroundColor Yellow "=== Pre-Deployment Checks ==="
    
    My-Logger "Checking WLD vCenter connectivity..."
    $sessionToken = Get-vCenterToken -vCenterServer $VCFWorkloadDomainVCSAIP -Username "administrator@vsphere.local" -Password $VCFWorkloadDomainVCSASSOPassword
    
    if (-not $sessionToken) {
        My-Logger "Failed to connect to WLD vCenter at $VCFWorkloadDomainVCSAIP" "red"
        exit 1
    }
    My-Logger "Successfully connected to WLD vCenter"
    
    $clusterMoRef = Get-WLDClusterMoRef -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -ClusterName $VCFWorkloadDomainVCSAClusterName
    if (-not $clusterMoRef) {
        My-Logger "Failed to find cluster '$VCFWorkloadDomainVCSAClusterName'" "red"
        exit 1
    }
    My-Logger "Found cluster with MoRef: $clusterMoRef"
    
    $storagePolicyId = Get-StoragePolicy -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -PolicyName $SupervisorStoragePolicy
    if (-not $storagePolicyId) {
        My-Logger "Storage policy '$SupervisorStoragePolicy' not found, trying 'vSAN'..." "yellow"
        $storagePolicyId = Get-StoragePolicy -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -PolicyName "vSAN"
    }
    My-Logger "Using storage policy ID: $storagePolicyId"
    
    # Check DVS - auto-discover
    My-Logger "Looking up Distributed Virtual Switch..."
    $dvsInfo = Get-DVSwitchUUID -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken
    if (-not $dvsInfo) {
        My-Logger "Failed to find any DVS" "red"
        exit 1
    }
    My-Logger "Found DVS '$($dvsInfo.name)' with UUID: $($dvsInfo.uuid)"
    
    # Check management network from SDDC Manager (this is where transportType lives)
    My-Logger "Checking management network from SDDC Manager (source of transportType metadata)..."
    $mgmtNetworkInfo = Get-WLDManagementNetworkFromSDDCM -DomainName $VCFWorkloadDomainName
    if ($mgmtNetworkInfo) {
        My-Logger "Found management network: $($mgmtNetworkInfo.portGroupName) (TransportType: $($mgmtNetworkInfo.transportType))"
    } else {
        My-Logger "WARNING: Could not retrieve management network from SDDC Manager" "yellow"
        My-Logger "The script will attempt pattern-based fallback during deployment" "yellow"
    }
    
    My-Logger "Checking NSX Manager connectivity at $wldNSXManagerIP..."
    
    $edgeClusterId = Get-NSXEdgeClusterId -NSXManager $wldNSXManagerIP -NSXPassword $VCFWorkloadDomainNSXAdminPassword -EdgeClusterName $SupervisorNSXEdgeCluster
    if (-not $edgeClusterId) {
        My-Logger "Failed to find NSX Edge Cluster '$SupervisorNSXEdgeCluster'" "red"
        My-Logger "Please ensure the Edge Cluster is deployed before running this script" "yellow"
        exit 1
    }
    My-Logger "Found NSX Edge Cluster with ID: $edgeClusterId"
    
    $tier0Id = Get-NSXTier0Id -NSXManager $wldNSXManagerIP -NSXPassword $VCFWorkloadDomainNSXAdminPassword -Tier0Name $SupervisorTier0Gateway
    if (-not $tier0Id) {
        My-Logger "Failed to find NSX Tier-0 Gateway '$SupervisorTier0Gateway'" "red"
        exit 1
    }
    My-Logger "Found NSX Tier-0 Gateway with ID: $tier0Id"
}

if ($ValidateOnly) {
    My-Logger "`nValidation completed successfully. Use -ValidateOnly:`$false to proceed with deployment."
    exit 0
}

# ==========================================================================
# WhatIf Mode - Display all discovered values without deploying
# ==========================================================================
if ($WhatIf) {
    Write-Host -ForegroundColor Magenta @"

╔═══════════════════════════════════════════════════════════════════╗
║                    WHATIF MODE - DRY RUN                          ║
║         Querying SDDC Manager, vCenter, and NSX...                ║
╚═══════════════════════════════════════════════════════════════════╝

"@

    # Get session token
    $sessionToken = Get-vCenterToken -vCenterServer $VCFWorkloadDomainVCSAIP -Username "administrator@vsphere.local" -Password $VCFWorkloadDomainVCSASSOPassword
    
    if (-not $sessionToken) {
        My-Logger "Failed to connect to WLD vCenter" "red"
        exit 1
    }

    # ==================== SDDC MANAGER INFO ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  SDDC MANAGER NETWORK CONFIGURATION                             │"
    Write-Host -ForegroundColor Yellow "│  Source: https://$SddcManagerIP/v1/clusters/{id}                │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"
    
    $sddcmNetworks = Get-AllNetworksFromSDDCM -DomainName $VCFWorkloadDomainName
    
    if ($sddcmNetworks.domain) {
        Write-Host -ForegroundColor Cyan "`n  Domain Information:"
        Write-Host -ForegroundColor White "    Name:   $($sddcmNetworks.domain.name)"
        Write-Host -ForegroundColor White "    ID:     $($sddcmNetworks.domain.id)"
        Write-Host -ForegroundColor White "    Type:   $($sddcmNetworks.domain.type)"
        Write-Host -ForegroundColor White "    Status: $($sddcmNetworks.domain.status)"
    }
    
    if ($sddcmNetworks.cluster) {
        Write-Host -ForegroundColor Cyan "`n  Cluster Information:"
        Write-Host -ForegroundColor White "    Name:     $($sddcmNetworks.cluster.name)"
        Write-Host -ForegroundColor White "    ID:       $($sddcmNetworks.cluster.id)"
        Write-Host -ForegroundColor White "    Storage:  $($sddcmNetworks.cluster.primaryDatastoreType)"
    }
    
    if ($sddcmNetworks.allPortgroups.Count -gt 0) {
        Write-Host -ForegroundColor Cyan "`n  Portgroups with TransportType (from SDDC Manager):"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        Write-Host -ForegroundColor DarkGray "  VDS Name                  | Portgroup Name              | TransportType"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        
        foreach ($pg in $sddcmNetworks.allPortgroups) {
            $transportColor = switch ($pg.transportType) {
                "MANAGEMENT" { "Green" }
                "VM_MANAGEMENT" { "Green" }
                "VMOTION" { "Yellow" }
                "VSAN" { "Cyan" }
                default { "White" }
            }
            $vdsFormatted = $pg.vdsName.PadRight(25)
            $pgFormatted = $pg.portGroupName.PadRight(27)
            Write-Host -NoNewline -ForegroundColor White "  $vdsFormatted | $pgFormatted | "
            Write-Host -ForegroundColor $transportColor "$($pg.transportType)"
        }
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        
        # Highlight the selected management network
        $selectedMgmtPg = $sddcmNetworks.allPortgroups | Where-Object { $_.transportType -eq "MANAGEMENT" -or $_.transportType -eq "VM_MANAGEMENT" } | Select-Object -First 1
        if ($selectedMgmtPg) {
            Write-Host -ForegroundColor Green "`n  ► Selected for Supervisor: $($selectedMgmtPg.portGroupName) (TransportType: $($selectedMgmtPg.transportType))"
        } else {
            Write-Host -ForegroundColor Red "`n  ✗ No portgroup with MANAGEMENT or VM_MANAGEMENT transportType found!"
            Write-Host -ForegroundColor Yellow "    Available transportTypes: $(($sddcmNetworks.allPortgroups | Select-Object -ExpandProperty transportType -Unique) -join ', ')"
        }
    } else {
        Write-Host -ForegroundColor Red "`n  No portgroup information retrieved from SDDC Manager"
        
        if ($sddcmNetworks.error) {
            Write-Host -ForegroundColor Red "  Error: $($sddcmNetworks.error)"
        }
        
        # Show raw cluster data for debugging
        if ($sddcmNetworks.rawClusterData) {
            Write-Host -ForegroundColor Yellow "`n  DEBUG: Raw cluster data properties:"
            $clusterProps = $sddcmNetworks.rawClusterData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            foreach ($prop in $clusterProps) {
                $val = $sddcmNetworks.rawClusterData.$prop
                if ($val -is [array]) {
                    Write-Host -ForegroundColor DarkGray "    $prop : [Array with $($val.Count) items]"
                } elseif ($val -is [PSCustomObject]) {
                    Write-Host -ForegroundColor DarkGray "    $prop : [Object]"
                } else {
                    Write-Host -ForegroundColor DarkGray "    $prop : $val"
                }
            }
            
            # Save raw data to file for inspection
            $debugFile = "sddc-manager-cluster-debug.json"
            $sddcmNetworks.rawClusterData | ConvertTo-Json -Depth 10 | Out-File $debugFile
            Write-Host -ForegroundColor Yellow "`n  DEBUG: Full cluster data saved to: $debugFile"
        }
    }

    # ==================== VCENTER INFO ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  vCENTER NETWORK INFORMATION                                    │"
    Write-Host -ForegroundColor Yellow "│  Source: https://$VCFWorkloadDomainVCSAIP/api/vcenter/network   │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"
    
    $vcNetworks = Get-AllNetworksFromvCenter -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken
    
    if ($vcNetworks.Count -gt 0) {
        Write-Host -ForegroundColor Cyan "`n  Available Networks in vCenter:"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        Write-Host -ForegroundColor DarkGray "  Network Name                        | Type                | MoRef"
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        
        foreach ($net in $vcNetworks) {
            $netNameFormatted = $net.name.PadRight(37)
            $netTypeFormatted = $net.type.PadRight(19)
            # Highlight vm_management (best for Supervisor) in green, regular management in yellow
            $netColor = if ($net.name -like "*vm_management*") { "Green" } 
                       elseif ($net.name -like "*-management" -and $net.name -notlike "*vm_management*") { "Yellow" } 
                       else { "White" }
            Write-Host -ForegroundColor $netColor "  $netNameFormatted | $netTypeFormatted | $($net.network)"
        }
        Write-Host -ForegroundColor DarkGray "  ─────────────────────────────────────────────────────────────────"
        Write-Host -ForegroundColor DarkGray "  Note: vCenter does NOT have transportType - that's VCF metadata"
        
        # Show the MoRef that would be used
        if ($selectedMgmtPg) {
            $matchingVcNet = $vcNetworks | Where-Object { $_.name -eq $selectedMgmtPg.portGroupName }
            if ($matchingVcNet) {
                Write-Host -ForegroundColor Green "`n  ► vCenter MoRef for '$($selectedMgmtPg.portGroupName)': $($matchingVcNet.network)"
            }
        } else {
            # No SDDC Manager match - use name pattern match
            # Priority: vm_management (for VMs) > management (for ESXi hosts)
            $mgmtNetByName = $vcNetworks | Where-Object { $_.name -like "*vm_management*" } | Select-Object -First 1
            
            if (-not $mgmtNetByName) {
                $mgmtNetByName = $vcNetworks | Where-Object { $_.name -like "*-vm-management*" } | Select-Object -First 1
            }
            
            if (-not $mgmtNetByName) {
                $mgmtNetByName = $vcNetworks | Where-Object { 
                    $_.name -like "*-management" -and 
                    $_.name -notlike "*vm_management*" -and
                    $_.name -notlike "*External*" 
                } | Select-Object -First 1
            }
            
            if ($mgmtNetByName) {
                Write-Host -ForegroundColor Yellow "`n  ► Fallback: Found network by name pattern: $($mgmtNetByName.name) ($($mgmtNetByName.network))"
                $selectedMgmtPg = @{ "portGroupName" = $mgmtNetByName.name }
            }
        }
    } else {
        Write-Host -ForegroundColor Red "  No networks retrieved from vCenter"
    }

    # ==================== DVS INFO ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  DISTRIBUTED VIRTUAL SWITCH (for Supervisor)                    │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"
    
    $dvsInfo = Get-DVSwitchUUID -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken
    if ($dvsInfo) {
        Write-Host -ForegroundColor White "`n  DVS Name: $($dvsInfo.name)"
        Write-Host -ForegroundColor White "  DVS UUID: $($dvsInfo.uuid)"
    } else {
        Write-Host -ForegroundColor Red "  No DVS found"
    }

    # ==================== CLUSTER INFO ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  vSPHERE CLUSTER                                                │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"
    
    $clusterMoRef = Get-WLDClusterMoRef -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -ClusterName $VCFWorkloadDomainVCSAClusterName
    Write-Host -ForegroundColor White "`n  Cluster Name: $VCFWorkloadDomainVCSAClusterName"
    Write-Host -ForegroundColor White "  Cluster MoRef: $clusterMoRef"

    # ==================== STORAGE POLICY ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  STORAGE POLICY                                                 │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"
    
    $storagePolicyId = Get-StoragePolicy -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -PolicyName $SupervisorStoragePolicy
    if (-not $storagePolicyId) {
        $storagePolicyId = Get-StoragePolicy -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -PolicyName "vSAN"
    }
    Write-Host -ForegroundColor White "`n  Policy Name: $SupervisorStoragePolicy"
    Write-Host -ForegroundColor White "  Policy ID: $storagePolicyId"

    # ==================== NSX INFO ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  NSX CONFIGURATION                                              │"
    Write-Host -ForegroundColor Yellow "│  Source: https://$wldNSXManagerIP                               │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"
    
    $edgeClusterId = Get-NSXEdgeClusterId -NSXManager $wldNSXManagerIP -NSXPassword $VCFWorkloadDomainNSXAdminPassword -EdgeClusterName $SupervisorNSXEdgeCluster
    $tier0Id = Get-NSXTier0Id -NSXManager $wldNSXManagerIP -NSXPassword $VCFWorkloadDomainNSXAdminPassword -Tier0Name $SupervisorTier0Gateway
    
    Write-Host -ForegroundColor White "`n  NSX Manager: $wldNSXManagerIP"
    Write-Host -ForegroundColor White "  Edge Cluster Name: $SupervisorNSXEdgeCluster"
    Write-Host -ForegroundColor White "  Edge Cluster ID: $edgeClusterId"
    Write-Host -ForegroundColor White "  Tier-0 Gateway Name: $SupervisorTier0Gateway"
    Write-Host -ForegroundColor White "  Tier-0 Gateway ID: $tier0Id"

    # ==================== SUPERVISOR SPEC PREVIEW ====================
    Write-Host -ForegroundColor Yellow "`n┌─────────────────────────────────────────────────────────────────┐"
    Write-Host -ForegroundColor Yellow "│  SUPERVISOR CLUSTER SPEC (would be sent to vCenter API)        │"
    Write-Host -ForegroundColor Yellow "└─────────────────────────────────────────────────────────────────┘"

    # Get management network MoRef
    $mgmtNetworkMoRef = "NOT_FOUND"
    $mgmtNetworkName = "NOT_FOUND"
    if ($selectedMgmtPg) {
        $mgmtNetworkName = $selectedMgmtPg.portGroupName
        $matchingVcNet = $vcNetworks | Where-Object { $_.name -eq $selectedMgmtPg.portGroupName }
        if ($matchingVcNet) {
            $mgmtNetworkMoRef = $matchingVcNet.network
        }
    }

    $previewSpec = [ordered]@{
        "size_hint" = $SupervisorClusterSize
        "service_cidr" = "$SupervisorServicesCIDR"
        "network_provider" = "NSXT_CONTAINER_PLUGIN"
        "ncp_cluster_network_spec" = [ordered]@{
            "nsx_edge_cluster" = $edgeClusterId
            "pod_cidrs" = $SupervisorPodCIDRs
            "ingress_cidrs" = $SupervisorIngressCIDR
            "egress_cidrs" = $SupervisorEgressCIDR
            "cluster_distributed_switch" = $dvsInfo.uuid
            "nsx_tier0_gateway" = $tier0Id
            "namespace_subnet_prefix" = $SupervisorNamespaceNetworkPrefix
        }
        "master_management_network" = [ordered]@{
            "mode" = $SupervisorMgmtNetworkMode
            "network" = $mgmtNetworkMoRef
            "network_name" = $mgmtNetworkName
            "starting_address" = $SupervisorMgmtNetworkStartIP
            "address_count" = $SupervisorMgmtNetworkAddressCount
            "gateway" = $SupervisorMgmtNetworkGateway
            "subnet_mask" = $SupervisorMgmtNetworkSubnetMask
        }
        "master_storage_policy" = $storagePolicyId
        "master_DNS" = @($VMDNS)
        "master_NTP_servers" = @($VMNTP)
    }

    Write-Host -ForegroundColor Cyan "`n"
    $previewSpec | ConvertTo-Json -Depth 5 | ForEach-Object { Write-Host -ForegroundColor White "  $_" }

    # ==================== SUMMARY ====================
    Write-Host -ForegroundColor Magenta @"

╔═══════════════════════════════════════════════════════════════════╗
║                    WHATIF SUMMARY                                 ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    
    $allGood = $true
    
    Write-Host -ForegroundColor White "`n  Checklist:"
    
    # Check how management network was discovered
    $mgmtFromSDDCM = $sddcmNetworks.allPortgroups | Where-Object { $_.transportType -eq "MANAGEMENT" -or $_.transportType -eq "VM_MANAGEMENT" } | Select-Object -First 1
    
    if ($mgmtFromSDDCM) {
        Write-Host -ForegroundColor Green "  [✓] Management network found via SDDC Manager transportType: $($mgmtFromSDDCM.portGroupName)"
    } elseif ($selectedMgmtPg) {
        Write-Host -ForegroundColor Yellow "  [~] Management network found via name pattern fallback: $($selectedMgmtPg.portGroupName)"
    } else {
        Write-Host -ForegroundColor Red "  [✗] Management network NOT found"
        $allGood = $false
    }
    
    if ($mgmtNetworkMoRef -ne "NOT_FOUND") {
        Write-Host -ForegroundColor Green "  [✓] Management network exists in vCenter: $mgmtNetworkMoRef"
    } else {
        Write-Host -ForegroundColor Red "  [✗] Management network NOT found in vCenter"
        $allGood = $false
    }
    
    if ($dvsInfo) {
        Write-Host -ForegroundColor Green "  [✓] DVS found: $($dvsInfo.name)"
    } else {
        Write-Host -ForegroundColor Red "  [✗] DVS NOT found"
        $allGood = $false
    }
    
    if ($clusterMoRef) {
        Write-Host -ForegroundColor Green "  [✓] Cluster found: $clusterMoRef"
    } else {
        Write-Host -ForegroundColor Red "  [✗] Cluster NOT found"
        $allGood = $false
    }
    
    if ($edgeClusterId) {
        Write-Host -ForegroundColor Green "  [✓] NSX Edge Cluster found: $edgeClusterId"
    } else {
        Write-Host -ForegroundColor Red "  [✗] NSX Edge Cluster NOT found"
        $allGood = $false
    }
    
    if ($tier0Id) {
        Write-Host -ForegroundColor Green "  [✓] NSX Tier-0 Gateway found: $tier0Id"
    } else {
        Write-Host -ForegroundColor Red "  [✗] NSX Tier-0 Gateway NOT found"
        $allGood = $false
    }
    
    if ($storagePolicyId) {
        Write-Host -ForegroundColor Green "  [✓] Storage Policy found: $storagePolicyId"
    } else {
        Write-Host -ForegroundColor Red "  [✗] Storage Policy NOT found"
        $allGood = $false
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

Write-Host -ForegroundColor Yellow "`n=== Supervisor Cluster Deployment ==="

# Get fresh session token
$sessionToken = Get-vCenterToken -vCenterServer $VCFWorkloadDomainVCSAIP -Username "administrator@vsphere.local" -Password $VCFWorkloadDomainVCSASSOPassword

# Get required IDs
$clusterMoRef = Get-WLDClusterMoRef -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -ClusterName $VCFWorkloadDomainVCSAClusterName
$storagePolicyId = Get-StoragePolicy -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -PolicyName $SupervisorStoragePolicy
if (-not $storagePolicyId) {
    $storagePolicyId = Get-StoragePolicy -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken -PolicyName "vSAN"
}

# Get DVS UUID - auto-discover
$dvsInfo = Get-DVSwitchUUID -vCenterServer $VCFWorkloadDomainVCSAIP -SessionToken $sessionToken
if (-not $dvsInfo) {
    My-Logger "Failed to find any DVS" "red"
    exit 1
}
My-Logger "Using DVS '$($dvsInfo.name)' with UUID: $($dvsInfo.uuid)"

$edgeClusterId = Get-NSXEdgeClusterId -NSXManager $wldNSXManagerIP -NSXPassword $VCFWorkloadDomainNSXAdminPassword -EdgeClusterName $SupervisorNSXEdgeCluster
$tier0Id = Get-NSXTier0Id -NSXManager $wldNSXManagerIP -NSXPassword $VCFWorkloadDomainNSXAdminPassword -Tier0Name $SupervisorTier0Gateway
$tier0Path = $tier0Id

# Create Content Library
# Note: In air-gapped/nested labs without internet, subscribed library will fail
# Set $SupervisorSkipSubscribedLibrary = $true in config to skip the attempt
My-Logger "Creating TKG Content Library..."
$skipSubscribed = if ($SupervisorSkipSubscribedLibrary) { $true } else { $false }
$contentLibraryId = Create-ContentLibrary `
    -vCenterServer $VCFWorkloadDomainVCSAIP `
    -SessionToken $sessionToken `
    -LibraryName $SupervisorContentLibraryName `
    -SubscriptionURL $SupervisorContentLibraryURL `
    -DatastoreName "vsan" `
    -SkipSubscribed:$skipSubscribed

if (-not $contentLibraryId) {
    My-Logger "Failed to create content library" "red"
    exit 1
}

# Enable Workload Management
$success = Enable-WorkloadManagement `
    -vCenterServer $VCFWorkloadDomainVCSAIP `
    -SessionToken $sessionToken `
    -ClusterMoRef $clusterMoRef `
    -StoragePolicyId $storagePolicyId `
    -ContentLibraryId $contentLibraryId `
    -EdgeClusterId $edgeClusterId `
    -Tier0GatewayPath $tier0Path `
    -DVSwitchUUID $dvsInfo.uuid

if ($success) {
    My-Logger "Waiting for Supervisor Cluster to become ready (this may take 20-30 minutes)..."
    
    $ready = Wait-SupervisorCluster `
        -vCenterServer $VCFWorkloadDomainVCSAIP `
        -SessionToken $sessionToken `
        -ClusterMoRef $clusterMoRef `
        -TimeoutMinutes 45

    if ($ready) {
        My-Logger "Creating initial namespace '$SupervisorNamespace'..."
        
        $sessionToken = Get-vCenterToken -vCenterServer $VCFWorkloadDomainVCSAIP -Username "administrator@vsphere.local" -Password $VCFWorkloadDomainVCSASSOPassword
        
        Create-Namespace `
            -vCenterServer $VCFWorkloadDomainVCSAIP `
            -SessionToken $sessionToken `
            -ClusterMoRef $clusterMoRef `
            -NamespaceName $SupervisorNamespace `
            -StoragePolicyId $storagePolicyId
    }
} else {
    My-Logger "Failed to enable Workload Management" "red"
}

$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

Write-Host -ForegroundColor Cyan @"

╔═══════════════════════════════════════════════════════════════════╗
║               Deployment Summary                                  ║
╚═══════════════════════════════════════════════════════════════════╝
"@

My-Logger "Supervisor Cluster Deployment Complete!"
My-Logger "  StartTime: $StartTime"
My-Logger "  EndTime: $EndTime"
My-Logger "  Duration: $duration minutes"

if ($success -and $ready) {
    Write-Host -ForegroundColor Green @"

Next Steps:
1. Log into vCenter at https://$VCFWorkloadDomainVCSAIP
2. Navigate to Menu > Workload Management
3. Verify the Supervisor Cluster status is 'Running'
4. Download the Kubernetes CLI tools from the Supervisor Cluster
5. Use 'kubectl vsphere login' to authenticate to the Supervisor

Example login command:
kubectl vsphere login --server=$SupervisorMgmtNetworkStartIP -u administrator@vsphere.local --insecure-skip-tls-verify

"@
}