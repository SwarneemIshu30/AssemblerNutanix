# Lenovo XCC Contribution SDT Inventory (v1)

The XCC collector owns the `LNV.Lenovo.XCC` tag namespace. These tags are stable
contribution points that may be placed in a Lenovo.DE or other host skeleton.
XCC does not require a dedicated document skeleton.

Target scope uses `TargetName`, resolved from the selected Core target folder.

## Canonical tags

- `LNV.Lenovo.XCC.Target[TargetName].Document.VitalProductDataGrouped`
- `LNV.Lenovo.XCC.Target[TargetName].Document.FirmwareSummary`
- `LNV.Lenovo.XCC.Target[TargetName].Document.HardwareSummary`
- `LNV.Lenovo.XCC.Target[TargetName].Document.MemoryExceptions`
- `LNV.Lenovo.XCC.Target[TargetName].Document.ManagementEthernetPorts`
- `LNV.Lenovo.XCC.Target[TargetName].Document.HostEthernetPorts`
- `LNV.Lenovo.XCC.Target[TargetName].Document.HostFcPorts`
- `LNV.Lenovo.XCC.Target[TargetName].Summary`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.CollectionStatus`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Managers`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Chassis`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Firmware`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Processors`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Memory`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.NetworkInterfaces`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.StorageControllers`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.StorageDrives`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.StorageVolumes`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Power`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Thermal`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.EventLog`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Security`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Users`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.Bios`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.SecureBoot`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.PcieDevices`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.PcieFunctions`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ManagerNetworkProtocol`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ManagerEthernetInterfaces`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ManagerHostInterfaces`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ManagerSerialInterfaces`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.VirtualMedia`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ChassisSensors`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ChassisNetworkAdapters`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ChassisPcieSlots`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ChassisEnvironment`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ChassisPowerSubsystem`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ChassisThermalSubsystem`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.HostEthernetPorts`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.HostFcPorts`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ManagementEthernetPorts`
- `LNV.Lenovo.XCC.Target[TargetName].Tables.ServerPortInventory`
- `LNV.Lenovo.XCC.Target[TargetName].Diagrams.ServerPortGraph`
- `LNV.Lenovo.XCC.Target[TargetName].Diagrams.StorageConnectivityGraph`

`network-interfaces` remains a compatibility/evidence dataset. The document-facing
network tag uses `ethernet-interfaces` to avoid duplicate rendered content.

The `Document.*` tags are the preferred customer-facing projection set. The
`Tables.*`, `Appendix.*`, and raw graph summary tags remain available for
diagnostic or collector-blueprint skeletons.
