# Lenovo.DE skeleton heading-to-tag replacement map

Manual apply guide using current document heading context and active mapping tags.

| # | Heading 1 | Heading 2 | Heading 3 | Current placeholder | New placeholder |
|---:|---|---|---|---|---|
| 1 | System Overview | Platform Summary |  | `LNV.Lenovo.DE.System[ArrayName].Summary` | `LNV.Lenovo.DE.System[ArrayName].Summary` |
| 2 | System Overview | Platform Summary |  | `LNV.Lenovo.DE.Controller[ControllerID].Summary` | `LNV.Lenovo.DE.System[ArrayName].Tables.Controllers` |
| 3 | System Overview | Controller Topology |  | `LNV.Lenovo.DE.Controller[ControllerID].Tables.Inventory` | `LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces` |
| 4 | System Overview | Controller Topology |  | `LNV.Lenovo.DE.Controller[ControllerID].Tables.HostInterfaces` | `LNV.Lenovo.DE.System[ArrayName].Tables.Transport` |
| 5 | System Overview | Version Matrix |  | `LNV.Lenovo.DE.System[ArrayName].Tables.Version` | `LNV.Lenovo.DE.System[ArrayName].Tables.DNS` |
| 6 | System Overview | Version Matrix |  | `LNV.Lenovo.DE.Controller[ControllerID].Tables.Firmware` | `LNV.Lenovo.DE.System[ArrayName].Tables.Time` |
| 7 | System Overview | Management Context |  | `LNV.Lenovo.DE.System[ArrayName].Summary` | `LNV.Lenovo.DE.System[ArrayName].Tables.Trays` |
| 8 | Architecture | Logical Architecture |  | `LNV.Lenovo.DE.System[ArrayName].Config` | `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI` |
| 9 | Architecture | SAN Fabric Architecture (Conditional) |  | `LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Summary` | `LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Summary` |
| 10 | Platform Configuration | Hardware Configuration |  | `LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory` | `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC` |
| 11 | Platform Configuration | Hardware Configuration |  | `LNV.Lenovo.XCC.Node[NodeName].Tables.Hardware` | `LNV.Lenovo.XCC.Node[NodeName].Tables.Hardware` |
| 12 | Platform Configuration | Controller Configuration |  | `LNV.Lenovo.DE.Controller[ControllerID].Tables.NetworkInterfaces` | `LNV.Lenovo.DE.System[ArrayName].Tables.Hosts` |
| 13 | Platform Configuration | Controller Configuration |  | `LNV.Lenovo.DE.Controller[ControllerID].Tables.HostPorts` | `LNV.Lenovo.DE.System[ArrayName].Tables.HostGroups` |
| 14 | Platform Configuration | Controller Configuration |  | `LNV.Lenovo.DE.Controller[ControllerID].Tables.Pathing` | `LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory` |
| 15 | Platform Configuration | Storage Configuration |  | `LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory` | `LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory` |
| 16 | Platform Configuration | Storage Configuration |  | `LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory` | `LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory` |
| 17 | Platform Configuration | Storage Configuration |  | `LNV.Lenovo.DE.Pool[PoolName].Tables.Capacity` | `LNV.Lenovo.DE.System[ArrayName].Tables.VolumeMappings` |
| 18 | Platform Configuration | Storage Configuration |  | `LNV.Lenovo.DE.Volume[VolumeName].Tables.CachePolicy` | `LNV.Lenovo.DE.System[ArrayName].Tables.HostsToHostGroups` |
| 19 | Platform Configuration | Host Connectivity |  | `LNV.Lenovo.DE.Host[HostName].Tables.Mappings` | `LNV.Lenovo.DE.System[ArrayName].Tables.HostGroupsToVolumes` |
| 20 | Platform Configuration | Host Connectivity |  | `LNV.Lenovo.DE.HostGroup[GroupName].Tables.Inventory` | `LNV.Lenovo.DE.System[ArrayName].Tables.HostsToVolumes` |
| 21 | Platform Configuration | Host Connectivity |  | `LNV.Lenovo.DE.Host[HostName].Tables.HostType` | `LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport` |
| 22 | Platform Configuration | Performance & Cache Configuration |  | `LNV.Lenovo.DE.System[ArrayName].Tables.Cache` | `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary` |
| 23 | Platform Configuration | Security Configuration | Authentication Sources | `LNV.Lenovo.DE.System[ArrayName].Tables.IdentitySources` | `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesKeyFeatures` |
| 24 | Platform Configuration | Security Configuration | RBAC | `LNV.Lenovo.DE.System[ArrayName].Tables.Roles` | `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesLimits` |
| 25 | Platform Configuration | Security Configuration | Certificates | `LNV.Lenovo.DE.System[ArrayName].Tables.Certificates` | `LNV.Lenovo.DE.System[ArrayName].Narrative.Management.ControllerA` |
| 26 | Platform Configuration | Security Configuration | Alerts & AutoSupport | `LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport` | `LNV.Lenovo.DE.System[ArrayName].Narrative.Management.ControllerB` |
| 27 | Platform Configuration | Data Protection | Alerts & AutoSupport | `LNV.Lenovo.DE.System[ArrayName].Tables.Snapshots` | `LNV.Lenovo.DE.System[ArrayName].Narrative.DNS.Scope1` |
| 28 | Platform Configuration | Data Protection | Alerts & AutoSupport | `LNV.Lenovo.DE.System[ArrayName].Tables.Replication` | `LNV.Lenovo.DE.System[ArrayName].Narrative.DNS.Scope2` |
| 29 | Appendices | Detailed Inventory | Shelf Failure | `LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory` | `LNV.Lenovo.DE.System[ArrayName].Narrative.Time.Scope1` |
| 30 | Appendices | Version Summary | Shelf Failure | `LNV.Lenovo.DE.System[ArrayName].Tables.Version` | `LNV.Lenovo.DE.System[ArrayName].Narrative.Time.Scope2` |
| 31 | Appendices | Configuration Exports | Shelf Failure | `LNV.Lenovo.DE.System[ArrayName].Evidence.Placeholder` | `LNV.Lenovo.DE.System[ArrayName].Narrative.HostPorts.Port1` |
| 32 | Appendices | SAN Fabric Detail (Conditional) | Shelf Failure | `LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Tables.Zones` | `LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Tables.Zones` |
| 33 | Appendices | Firmware & Component Inventory (XCC) | Emergency Shutdown | `LNV.Lenovo.XCC.Node[NodeName].Tables.FirmwareInventory` | `LNV.Lenovo.XCC.Node[NodeName].Tables.FirmwareInventory` |
| 34 | Appendices | Node-Level Driver Alignment (Critical Components) | Emergency Shutdown | `LNV.Microsoft.WindowsS2D.Node[NodeName].Tables.CriticalDrivers` | `LNV.Microsoft.WindowsS2D.Node[NodeName].Tables.CriticalDrivers` |
| 35 | Appendices | Node-Level Driver Alignment (Critical Components) | Emergency Shutdown | `LNV.VMware.vSphere.Host[HostFQDN].Tables.CriticalDrivers` | `LNV.VMware.vSphere.Host[HostFQDN].Tables.CriticalDrivers` |

## Additional inserts (after last Lenovo.DE placeholder)
- `LNV.Lenovo.DE.System[ArrayName].Narrative.HostPorts.Port2`
- `LNV.Lenovo.DE.System[ArrayName].Narrative.Version`
- `LNV.Lenovo.DE.System[ArrayName].Narrative.Config`
- `LNV.Lenovo.DE.System[ArrayName].Narrative.Evidence`

## Cross-technology placeholders to keep unchanged
- `LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Summary`
- `LNV.Lenovo.XCC.Node[NodeName].Tables.Hardware`
- `LNV.Lenovo.SAN.Fabric.Fabric[FabricName].Tables.Zones`
- `LNV.Lenovo.XCC.Node[NodeName].Tables.FirmwareInventory`
- `LNV.Microsoft.WindowsS2D.Node[NodeName].Tables.CriticalDrivers`
- `LNV.VMware.vSphere.Host[HostFQDN].Tables.CriticalDrivers`
