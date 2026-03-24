# Lenovo.DE manual tag placement (easy format)

Use this as:

# Heading
<<SDT: tag>>

## Replace in document order

# System Overview / Platform Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Summary>>

# System Overview / Platform Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Controllers>>

# System Overview / Controller Topology
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces>>

# System Overview / Controller Topology
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Transport>>

# System Overview / Version Matrix
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.DNS>>

# System Overview / Version Matrix
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Time>>

# System Overview / Management Context
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>

# Architecture / Logical Architecture
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI>>

# Architecture / SAN Fabric Architecture (Conditional)
<<SDT: LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Summary>>

# Platform Configuration / Hardware Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC>>

# Platform Configuration / Hardware Configuration
<<SDT: LNV.Lenovo.XCC.Node[NodeName].Tables.Hardware>>

# Platform Configuration / Controller Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Hosts>>

# Platform Configuration / Controller Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostGroups>>

# Platform Configuration / Controller Configuration
<<SDT: LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory>>

# Platform Configuration / Storage Configuration
<<SDT: LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory>>

# Platform Configuration / Storage Configuration
<<SDT: LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory>>

# Platform Configuration / Storage Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.VolumeMappings>>

# Platform Configuration / Storage Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostsToHostGroups>>

# Platform Configuration / Host Connectivity
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostGroupsToVolumes>>

# Platform Configuration / Host Connectivity
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostsToVolumes>>

# Platform Configuration / Host Connectivity
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport>>

# Platform Configuration / Performance & Cache Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary>>

# Platform Configuration / Security Configuration / Authentication Sources
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesKeyFeatures>>

# Platform Configuration / Security Configuration / RBAC
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesLimits>>

# Appendices / SAN Fabric Detail (Conditional) / Shelf Failure
<<SDT: LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Tables.Zones>>

# Appendices / Firmware & Component Inventory (XCC) / Emergency Shutdown
<<SDT: LNV.Lenovo.XCC.Node[NodeName].Tables.FirmwareInventory>>

# Appendices / Node-Level Driver Alignment (Critical Components) / Emergency Shutdown
<<SDT: LNV.Microsoft.WindowsS2D.Node[NodeName].Tables.CriticalDrivers>>

# Appendices / Node-Level Driver Alignment (Critical Components) / Emergency Shutdown
<<SDT: LNV.VMware.vSphere.Host[HostFQDN].Tables.CriticalDrivers>>

## Available but not placed in template (for future insertion)

# System Overview / Key Design Decisions (optional future)
<<SDT: LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>

# Platform Configuration / Controller Configuration / Host Port Configuration - iSCSI (optional future transport callout)
<<SDT: LNV.Lenovo.DE.System[ArrayName].Narrative.ActiveTransport>>
