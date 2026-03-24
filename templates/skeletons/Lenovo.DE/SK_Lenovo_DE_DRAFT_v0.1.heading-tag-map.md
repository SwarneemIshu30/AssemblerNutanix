# Lenovo.DE manual tag placement (DOCX headings are source of truth)

Use this as:

# Heading path in DOCX
<<SDT: tag>>

## Replace in document order (aligned to current SK DOCX section flow)

# System Overview / Platform Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Summary>>

# System Overview / Platform Summary
<<SDT: LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory>>

# System Overview / Platform Summary
<<SDT: LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory>>

# System Overview / Controller Topology
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Controllers>>

# System Overview / Version Matrix / Validation Block - Version Matrix
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Controllers>>

# System Overview / Version Matrix / Validation Block - Version Matrix
<<SDT: LNV.Lenovo.DE.System[ArrayName].Summary>>

# System Overview / Management Context / Validation Block - Management Context
<<SDT: LNV.Lenovo.DE.System[ArrayName].Summary>>

# System Overview / Management Context / Validation Block - Management Context
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces>>

# System Overview / Management Interfaces
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces>>

# System Overview / DNS Configuration / Validation Block - DNS Effective Settings
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.DNS>>

# System Overview / DNS Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.DNS>>

# System Overview / Time Configuration / Validation Block - Time Effective Settings
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Time>>

# System Overview / Time Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Time>>

# Architecture / Logical Architecture
<<SDT: LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory>>

# Architecture / Logical Architecture
<<SDT: LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory>>

# Architecture / Logical Architecture
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.VolumeMappings>>

# Architecture / Physical Layout
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>

# Architecture / Physical Layout
<<SDT: LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory>>

# Architecture / SAN Fabric Architecture (Conditional)
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC>>

# Platform Configuration / Hardware Configuration / Tray / Shelf Inventory
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>

# Platform Configuration / Hardware Configuration / Drive Inventory
<<SDT: LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory>>

# Platform Configuration / Controller Configuration / Management Interfaces
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces>>

# Platform Configuration / Controller Configuration / Transport Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Transport>>

# Platform Configuration / Controller Configuration / Transport Summary (insert above host-port sections)
Transports configured:
<<SDT: LNV.Lenovo.DE.System[ArrayName].Narrative.ActiveTransport>>

# Platform Configuration / Controller Configuration / Host Port Configuration - iSCSI
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI>>

# Platform Configuration / Controller Configuration / Host Port Configuration - Fibre Channel
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC>>

# Platform Configuration / Storage Configuration / Storage Containers / Pools / Volume Groups
<<SDT: LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory>>

# Platform Configuration / Storage Configuration / Volumes
<<SDT: LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory>>

# Platform Configuration / Storage Configuration / Volume Mapping Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.VolumeMappings>>

# Platform Configuration / Host Connectivity / Host Definitions
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Hosts>>

# Platform Configuration / Host Connectivity / Host Groups
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostGroups>>

# Platform Configuration / Host Connectivity / Host to Host Group Relationships
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostsToHostGroups>>

# Platform Configuration / Host Connectivity / Host Group to Volume Presentation
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostGroupsToVolumes>>

# Platform Configuration / Host Connectivity / Direct Host to Volume Presentation
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostsToVolumes>>

# Platform Configuration / Security Configuration / Alerts & AutoSupport
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport>>

# Platform Configuration / Performance & Cache Configuration / Capabilities Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary>>

# Platform Configuration / Performance & Cache Configuration / Key Features
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesKeyFeatures>>

# Platform Configuration / Performance & Cache Configuration / Feature Limits / Consumption
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesLimits>>

# Operational Behaviour (Day-2) / Access Model / Validation Block - Transport / Access Model
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Transport>>

# Operational Behaviour (Day-2) / Access Model / Validation Block - Transport / Access Model
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI>>

# Operational Behaviour (Day-2) / Access Model / Validation Block - Transport / Access Model
<<SDT: LNV.Lenovo.DE.System[ArrayName].Summary>>

# Operational Behaviour (Day-2) / Monitoring & Alert Flow
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport>>

# Appendix / Detailed Inventory
<<SDT: LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory>>

# Appendix / Detailed Inventory
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>

# Appendix / Detailed Inventory
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Controllers>>

# Appendix / Version Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Summary>>

# Appendix / Validation Block - Controller A / Controller B Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces>>

# Appendix / Validation Block - Controller A / Controller B Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI>>

## Available but not placed in template (for future insertion)

# System Overview / Key Design Decisions (optional future)
<<SDT: LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>
