#VCF 9.0.0

# Physical vCenter Server environment
$VIServer = "labvcsa.lab.io"
$VIUsername = "administrator@vsphere.local"
$VIPassword = "VMwareVCF9!"

# General Deployment Configuration
$VAppLabel = "TSLAB"
$VMDatacenter = "Datacenter"
$VMCluster = "labcluster"
$VMNetwork = "nested_trunk"
$VMDatastore = "DS01"
$ESXMGMTVLAN = "100"
$VMMGMTVLAN = "101"
$ESXWLDVLAN = "200"
$VMVCFInstNetwork = "VLAN100"
$VMNetmask = "255.255.255.0"
$ESXMGMTGateway = "10.2.100.1"
$VMMGMTGateway = "10.2.101.1"
$ESXWLDGateway = "10.2.200.1"
$VMDNS = "10.1.10.10"
$VMNTP = "10.1.10.1"
$VMPassword = "VMwareVCF9!"
$VMDomain = "vcf.lab.io"
$VMSyslog = ""
$VMFolder = "TSLAB"

# Enable Debugging
$Debug = $true

# Full Path to both the Nested ESXi & VCF Installer OVA
$NestedESXiApplianceOVA = "c:\vcf_deploy\images\Nested_ESXi9.1.0.0_Appliance_Template_v1.0.ova"
$VCFInstallerOVA = "c:\vcf_deploy\images\VCF-SDDC-Manager-Appliance-9.1.0.0100.25428926.ova"


# VCF Version
$VCFInstallerProductVersion = "9.1.0.0"
$VCFInstallerProductSKU = "VCF"

# VCF Software Depot Configuration
$VCFInstallerSoftwareDepot = "offline" #online or offline
$VCFInstallerDepotToken = "nmPzsWK3ixq7IT4lsU3UQ3LRBltbF5tJ"

# Offline Depot Configurations (optional)
$VCFInstallerDepotUsername = "depot"
$VCFInstallerDepotPassword = "VMwareVCF9!"
$VCFInstallerDepotHost = "vcfdepot.lab.io"
$VCFInstallerDepotPort = 80
$VCFInstallerDepotHttps = $false

# VCF Fleet Deployment Configuration
$DeploymentInstanceName = "VCF9 Lab Instance"
$DeploymentId = "m01"
$CEIPEnabled = $false
$FIPSEnabled = $false

# VCF Installer Configurations
$VCFInstallerVMName = "vcfinst"
$VCFInstallerFQDN = "vcfinst.vcf.lab.io"
$VCFInstallerIP = "10.2.100.9"
$VCFInstallerAdminUsername = "admin@local"
$VCFInstallerAdminPassword = "VMware1!VMware1!"
$VCFInstallerRootPassword = "VMware1!VMware1!"

# SDDC Manager Configuration
$SddcManagerHostname = "sddcm01"
$SddcManagerIP = "10.2.101.100"
$SddcManagerRootPassword = "VMware1!VMware1!"
$SddcManagerVcfPassword = "VMware1!VMware1!"
$SddcManagerSSHPassword = "VMware1!VMware1!"
$SddcManagerLocalPassword = "VMware1!VMware1!"

# Nested ESXi VMs for Management Domain
$NestedESXiHostnameToIPsForManagementDomain = @{
    "esx01"   = "10.2.100.10"
    "esx02"   = "10.2.100.11"
    "esx03"   = "10.2.100.12"
    "esx04"   = "10.2.100.13"
}

# Nested ESXi VMs for Workload Domain
$NestedESXiHostnameToIPsForWorkloadDomain = @{
    "esx05"   = "10.2.200.10"
    "esx06"   = "10.2.200.11"
    "esx07"   = "10.2.200.12"
}

# Nested ESXi VM Resources for Management Domain
$NestedESXiMGMTvCPU = "24"
$NestedESXiMGMTvMEM = "160" #GB
$NestedESXiMGMTCapacityvDisk = "750" #GB
$NestedESXiMGMTBootDisk = "64" #GB

# Nested ESXi VM Resources for Workload Domain
$NestedESXiWLDvCPU = "24"
$NestedESXiWLDvMEM = "160" #GB
$NestedESXiWLDCapacityvDisk = "1200" #GB
$NestedESXiWLDBootDisk = "64" #GB

# ESXi Network Configuration
$NestedMGMTESXiManagementNetworkCidr = "10.2.100.0/24" # should match $VMNetwork configuration
$NestedMGMTESXiVMNetworkCidr = "10.2.101.0/24"
$NestedMGMTESXivMotionNetworkCidr = "10.2.102.0/24"
$NestedMGMTESXivSANNetworkCidr = "10.2.103.0/24"
$NestedMGMTESXiNSXTepNetworkCidr = "10.2.104.0/24"
$NestedMGMTESXiEdgeTepNetworkCidr = "10.2.105.0/24"

$NestedWLDESXiManagementNetworkCidr = "10.2.200.0/24" # should match $VMNetwork configuration
$NestedWLDESXivMotionNetworkCidr = "10.2.201.0/24"
$NestedWLDESXivSANNetworkCidr = "10.2.202.0/24"
$NestedWLDESXiNSXTepNetworkCidr = "10.2.203.0/24"
$NestedWLDESXiEdgeTepNetworkCidr = "10.2.204.0/24"
$NestedWLDServiceNetworkCidr = "10.96.0.0/24"

$VCFManagementServicesSize                = "small"
$VCFManagementServicesRuntimeHostname          = "msr01.$VMDomain"
$VCFManagementServicesInstanceHostname         = "vcfint01.$VMDomain"
$VCFManagementServicesFleetHostname            = "flt01.$VMDomain"
$VCFManagementServicesSystemPassword           = "VMware1!VMware1!"
$VCFManagementServicesIPStartRange             = "10.2.101.66"
$VCFManagementServicesIPEndRange               = "10.2.101.87"
$VCFManagementServicesInternalClusterCidrIpv4  = "198.18.0.0/15"
$VCFManagementServicesIdentityHostname         = "idb01.$VMDomain"
$VCFLicenseServerHostname                      = "lic01.$VMDomain"
$VCFAutomationServicesRuntimeHostname          = "asr01.$VMDomain"



# vCenter Configuration
$VCSAName = "mgmt-vc"
$VCSAIP = "10.2.101.101"
$VCSARootPassword = "VMware1!VMware1!"
$VCSASSOPassword = "VMware1!VMware1!"
$VCSASize = "small"
$VCSAEnableVCLM = $true
$VCSADatacenterName = "mgmt-dc"
$VCSAClusterName = "mgmt-cl01"

#vSAN Configuration
$VSANFTT = 0
$VSANDedupe = $false
$VSANESAEnabled = $true
$VSANDatastoreName = "vsanDatastore"

# VCF Operations Configuration
$VCFOperationsSize = "small"
$VCFOperationsHostname = "ops"
$VCFOperationsIP = "10.2.101.102"
$VCFOperationsRootPassword = "VMware1!VMware1!"
$VCFOperationsAdminPassword = "VMware1!VMware1!"

# NSX Configuration
$NSXManagerSize = "medium"
$NSXManagerVIPHostname = "nsx01"
$NSXManagerVIPIP = "10.2.101.105"
$NSXManagerNodeHostname = "nsx01a"
$NSXRootPassword = "VMware1!VMware1!"
$NSXAdminPassword = "VMware1!VMware1!"
$NSXAuditPassword = "VMware1!VMware1!"

# VCF Operations Collector
$VCFOperationsCollectorSize = "small"
$VCFOperationsCollectorHostname = "opsproxy01"
$VCFOperationsCollectorRootPassword = "VMware1!VMware1!"

# VCF Operations Fleet Manager
$VCFOperationsFleetManagerHostname = "opsfm01"
$VCFOperationsFleetManagerAdminPassword = "VMware1!VMware1!"
$VCFOperationsFleetManagerRootPassword = "VMware1!VMware1!"

# VCF Automation
$VCFAutomationSize = "small"
$VCFAutomationHostname = "auto01"
$VCFAutomationAdminPassword = "VMware1!VMware1!"
$VCFAutomationIPPool = @("10.2.101.108","10.2.101.109","10.2.101.110","10.2.101.111","10.2.101.112")
$VCFAutomationNodePrefix = "auto01"
$VCFAutomationClusterCIDR = "198.18.0.0/15"

# VCF Workload Domain Configurations
$VCFWorkloadDomainName = "w01"
$VCFWorkloadDomainOrgName = "w01"
$VCFWorkloadDomainEnableVCLM = $true
$VCFWorkloadDomainEnableVSANESA = $true

# WLD vCenter Configuration
$VCFWorkloadDomainVCSAHostname = "wld-vc"
$VCFWorkloadDomainVCSAIP = "10.2.101.200"
$VCFWorkloadDomainVCSARootPassword = "VMware1!VMware1!"
$VCFWorkloadDomainVCSASSOPassword = "VMware1!VMware1!"
$VCFWorkloadDomainVCSADatacenterName = "wld-dc"
$VCFWorkloadDomainVCSAClusterName = "wld-cl01"

# WLD NSX Configuration
$VCFWorkloadDomainNSXManagerVIPHostname = "nsx02"
$VCFWorkloadDomainNSXManagerNode1Hostname = "nsx02a"
$VCFWorkloadDomainNSXManagerNode1IP = "10.2.101.201"
$VCFWorkloadDomainNSXAdminPassword = "VMware1!VMware1!"
$VCFWorkloadDomainSeparateNSXSwitch = $false

$VCFWorkloadDomainPoolName = "w01-np01"

# WLD vMotion network
$WLDvMotionCidr    = "10.10.201.0/24"
$WLDvMotionGateway = "10.10.201.1"
$WLDvMotionStart   = "10.10.201.10"
$WLDvMotionEnd     = "10.10.201.50"
$WLDvMotionVlan    = 201

# WLD vSAN network
$WLDVsanCidr    = "10.10.203.0/24"
$WLDVsanGateway = "10.10.203.1"
$WLDVsanStart   = "10.10.203.10"
$WLDVsanEnd     = "10.10.203.50"
$WLDVsanVlan    = 203

#==============================================================================
# EDGE CLUSTER AND SUPERVISOR CONFIGURATION
# Add this section to your VCFDeploymentConfig.ps1 file
#==============================================================================

#------------------------------------------------------------------------------
# MANAGEMENT DOMAIN EDGE CLUSTER
#------------------------------------------------------------------------------

$MGMTEdgeClusterName = "m01-ec01"
$MGMTEdgeClusterProfileType = "DEFAULT"
$MGMTEdgeFormFactor = "MEDIUM"  # SMALL, MEDIUM, LARGE, XLARGE

# Management Edge Node 1
$MGMTEdgeNode1Name = "m01edge01"
$MGMTEdgeNode1MgmtIP = "10.2.101.150"
$MGMTEdgeNode1TEP1IP = "10.2.105.10"
$MGMTEdgeNode1TEP2IP = "10.2.105.11"

# Management Edge Node 2
$MGMTEdgeNode2Name = "m01edge02"
$MGMTEdgeNode2MgmtIP = "10.2.101.151"
$MGMTEdgeNode2TEP1IP = "10.2.105.12"
$MGMTEdgeNode2TEP2IP = "10.2.105.13"

# Management Edge TEP Network (overlay traffic)
$MGMTEdgeTEPVLAN = 105
$MGMTEdgeTEPCIDR = "10.2.105.0/24"
$MGMTEdgeTEPGateway = "10.2.105.1"
$MGMTEdgeTEPPoolStart = "10.2.105.20"
$MGMTEdgeTEPPoolEnd = "10.2.105.50"

# Management Edge Tier-0 Configuration
$MGMTEdgeTier0Name = "m01-t0-gw01"
$MGMTEdgeTier0ASN = 65001
$MGMTEdgeBGPPeerASN = 65000

# Uplink 1 Network (Primary path)
$MGMTEdgeUplink1VLAN = 106
$MGMTEdgeUplink1Prefix = 24                    # Subnet prefix for uplink IPs
$MGMTEdgeUplink1Gateway = "10.2.106.1"
$MGMTEdgeNode1Uplink1IP = "10.2.106.2"         # Script will add /$Prefix
$MGMTEdgeNode2Uplink1IP = "10.2.106.3"

# Uplink 2 Network (Secondary path - set IPs to "" to disable)
# Use separate VLAN for true redundancy
$MGMTEdgeUplink2VLAN = 107
$MGMTEdgeUplink2Prefix = 24
$MGMTEdgeUplink2Gateway = "10.2.107.1"
$MGMTEdgeNode1Uplink2IP = "10.2.107.2"         # Set to "" for single uplink
$MGMTEdgeNode2Uplink2IP = "10.2.107.3"         # Set to "" for single uplink

#==============================================================================
# EDGE CLUSTER AND SUPERVISOR CONFIGURATION
# Add this section to your VCFDeploymentConfig.ps1 file
#==============================================================================

#------------------------------------------------------------------------------
# MANAGEMENT DOMAIN EDGE CLUSTER
#------------------------------------------------------------------------------

$MGMTEdgeClusterName = "m01-ec01"
$MGMTEdgeClusterProfileType = "DEFAULT"
$MGMTEdgeFormFactor = "MEDIUM"  # SMALL, MEDIUM, LARGE, XLARGE

# Management Edge Node 1
$MGMTEdgeNode1Name = "m01edge01"
$MGMTEdgeNode1MgmtIP = "10.2.101.150"
$MGMTEdgeNode1TEP1IP = "10.2.105.10"
$MGMTEdgeNode1TEP2IP = "10.2.105.11"

# Management Edge Node 2
$MGMTEdgeNode2Name = "m01edge02"
$MGMTEdgeNode2MgmtIP = "10.2.101.151"
$MGMTEdgeNode2TEP1IP = "10.2.105.12"
$MGMTEdgeNode2TEP2IP = "10.2.105.13"

# Management Edge Management Network Prefix (for edge management IPs)
$MGMTEdgeMgmtPrefix = 24

# Management Edge TEP Network (overlay traffic)
$MGMTEdgeTEPVLAN = 105
$MGMTEdgeTEPCIDR = "10.2.105.0/24"
$MGMTEdgeTEPGateway = "10.2.105.1"
$MGMTEdgeTEPPrefix = 24                        # Prefix for TEP IPs
$MGMTEdgeTEPPoolStart = "10.2.105.20"
$MGMTEdgeTEPPoolEnd = "10.2.105.50"

# Management Edge Tier-0 Configuration
$MGMTEdgeTier0Name = "m01-t0-gw01"
$MGMTEdgeTier0ASN = 65001
$MGMTEdgeBGPPeerASN = 65000

# Uplink 1 Network (Primary path)
$MGMTEdgeUplink1VLAN = 90
$MGMTEdgeUplink1Prefix = 24                    # Subnet prefix for uplink IPs
$MGMTEdgeUplink1Gateway = "10.2.90.1"
$MGMTEdgeNode1Uplink1IP = "10.2.90.2"         # Script will add /$Prefix
$MGMTEdgeNode2Uplink1IP = "10.2.90.3"

# Uplink 2 Network (Secondary path - set IPs to "" to disable)
# Use separate VLAN for true redundancy
$MGMTEdgeUplink2VLAN = 91
$MGMTEdgeUplink2Prefix = 24
$MGMTEdgeUplink2Gateway = "10.2.91.1"
$MGMTEdgeNode1Uplink2IP = "10.2.91.2"         # Set to "" for single uplink
$MGMTEdgeNode2Uplink2IP = "10.2.91.3"         # Set to "" for single uplink

#------------------------------------------------------------------------------
# WORKLOAD DOMAIN EDGE CLUSTER
#------------------------------------------------------------------------------

$WLDEdgeClusterName = "wld-ec01"
$WLDEdgeClusterProfileType = "DEFAULT"
$WLDEdgeFormFactor = "MEDIUM"

# Workload Edge Node 1
$WLDEdgeNode1Name = "wldedge01"
$WLDEdgeNode1MgmtIP = "10.2.200.210"
$WLDEdgeNode1TEP1IP = "10.2.204.10"
$WLDEdgeNode1TEP2IP = "10.2.204.11"

# Workload Edge Node 2
$WLDEdgeNode2Name = "wldedge02"
$WLDEdgeNode2MgmtIP = "10.2.200.211"
$WLDEdgeNode2TEP1IP = "10.2.204.12"
$WLDEdgeNode2TEP2IP = "10.2.204.13"

# Workload Edge Management Network Prefix
$WLDEdgeMgmtPrefix = 24

# Workload Edge TEP Network (overlay traffic)
$WLDEdgeTEPVLAN = 204
$WLDEdgeTEPCIDR = "10.2.204.0/24"
$WLDEdgeTEPGateway = "10.2.204.1"
$WLDEdgeTEPPrefix = 24                         # Prefix for TEP IPs
$WLDEdgeTEPPoolStart = "10.2.204.20"
$WLDEdgeTEPPoolEnd = "10.2.204.50"

# Workload Edge Tier-0 Configuration
$WLDEdgeTier0Name = "w01-t0-gw01"
$WLDEdgeTier0ASN = 65002
$WLDEdgeBGPPeerASN = 65000

# Uplink 1 Network (Primary path)
$WLDEdgeUplink1VLAN = 90
$WLDEdgeUplink1Prefix = 24                     # Subnet prefix for uplink IPs
$WLDEdgeUplink1Gateway = "10.2.90.1"
$WLDEdgeNode1Uplink1IP = "10.2.90.4"          # Script will add /$Prefix
$WLDEdgeNode2Uplink1IP = "10.2.90.5"

# Uplink 2 Network (Secondary path - set IPs to "" to disable)
# Use separate VLAN for true redundancy
$WLDEdgeUplink2VLAN = 91
$WLDEdgeUplink2Prefix = 24
$WLDEdgeUplink2Gateway = "10.2.91.1"
$WLDEdgeNode1Uplink2IP = "10.2.91.4"          # Set to "" for single uplink
$WLDEdgeNode2Uplink2IP = "10.2.91.5"          # Set to "" for single uplink

#------------------------------------------------------------------------------
# SUPERVISOR CLUSTER CONFIGURATION
#------------------------------------------------------------------------------

$SupervisorClusterName = "wld-supervisor-01"
$SupervisorClusterSize = "TINY"  # TINY, SMALL, MEDIUM, LARGE

$WLDVCSAUsername = "administrator@vsphere.local"
$VCFWorkloadDomainVCSASSOPassword ="VMware1!VMware1!"

# Supervisor Control Plane Network
$SupervisorMgmtNetworkMode = "STATICRANGE"
$SupervisorMgmtNetworkStartIP = "10.2.200.220"
$SupervisorMgmtNetworkAddressCount = 5
$SupervisorMgmtNetworkGateway = "10.2.200.1"
$SupervisorMgmtNetworkSubnetMask = "255.255.255.0"

# Supervisor Services Network (internal K8s ClusterIP range)
$SupervisorServicesCIDR = "10.96.0.0/24"

# NSX Integration
$SupervisorNSXEdgeCluster = $WLDEdgeClusterName
$SupervisorTier0Gateway = $WLDEdgeTier0Name

# Ingress CIDRs - EXTERNAL/ROUTABLE
# LoadBalancer service VIPs - external clients reach K8s services via these IPs
# Requires VLAN 207 on VyOS with routing to Tier-0
$SupervisorIngressCIDR = "10.2.220.0/24"

# Egress CIDRs - EXTERNAL/ROUTABLE  
# SNAT pool for pods communicating outbound to external networks
# Requires VLAN 208 on VyOS with routing to Tier-0
$SupervisorEgressCIDR = "10.2.221.0/24"

# Pod Network CIDRs - INTERNAL/OVERLAY (no VLAN needed)
# NSX creates overlay segments from this pool for pod networking
# Each namespace gets a /$SupervisorNamespaceNetworkPrefix subnet from this range
$SupervisorPodCIDRs = @("10.244.0.0/20")

# Namespace Subnet Prefix
# Size of subnet allocated to each namespace from PodCIDRs
# /28 = 16 IPs per namespace (14 usable for pods)
$SupervisorNamespaceNetworkPrefix = 28

# Default Namespace
$SupervisorNamespace = "wld-ns-01"

# Storage Policy
$SupervisorStoragePolicy = "vSAN Default Storage Policy"

# Content Library for TKG
$SupervisorContentLibraryName = "TKG-Content-Library"
$SupervisorContentLibraryURL = "https://wp-content.vmware.com/v2/latest/lib.json"

# DNS/NTP for Supervisor Control Plane
# By default uses the same as the rest of VCF ($VMDNS, $VMNTP from base config)
# Uncomment and modify if Supervisor needs different DNS/NTP servers
$SupervisorDNSServers = @($VMDNS)
$SupervisorDNSSearchDomains = @($VMDomain)
$SupervisorNTPServers = @($VMNTP)

# Example: Override with different servers for Supervisor
# $SupervisorDNSServers = @("10.2.101.5", "10.2.101.6")
# $SupervisorDNSSearchDomains = @("vcf.local", "k8s.local")
# $SupervisorNTPServers = @("10.2.101.1")

#==============================================================================
# NETWORK SUMMARY FOR REFERENCE
#==============================================================================
<#
VLAN Assignments (based on your VyOS config):
---------------------------------------------
MGMT Domain:
  VLAN 100: 10.2.100.0/24 - ESXi Management
  VLAN 101: 10.2.101.0/24 - VM Management (vCenter, NSX, SDDC Manager)
  VLAN 102: 10.2.102.0/24 - vMotion
  VLAN 103: 10.2.103.0/24 - vSAN
  VLAN 104: 10.2.104.0/24 - Host TEP (NSX overlay)
  VLAN 105: 10.2.105.0/24 - Edge TEP

WLD Domain:
  VLAN 200: 10.2.200.0/24 - ESXi Management
  VLAN 201: 10.2.201.0/24 - vMotion
  VLAN 202: 10.2.202.0/24 - vSAN (shows as WLD vSAN in VyOS)
  VLAN 203: 10.2.203.0/24 - Host TEP
  VLAN 204: 10.2.204.0/24 - Edge TEP

EDGE:
  VLAN 90: 10.2.90.0/24 Edge Uplink 1/Tier-0
  VLAN 91: 10.2.91.0/24 Edge Uplink 2/Tier-0

Supervisor/Kubernetes:
  VLAN 220: 10.2.220.0/24 - Ingress (LoadBalancer VIPs) [NEW - add to VyOS]
  VLAN 221: 10.2.221.0/24 - Egress (SNAT) [NEW - add to VyOS]
  10.244.0.0/20          - Pod Networking (overlay, no VLAN needed)
  10.96.0.0/24           - Kubernetes Services (internal)
#>