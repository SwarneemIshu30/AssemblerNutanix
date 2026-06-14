# Lenovo XCC Contribution SDT Inventory (v1)

The XCC collector owns the `LNV.Lenovo.XCC` tag namespace. These tags are stable
contribution points that may be placed in a Lenovo.DE or other host skeleton.
XCC does not require a dedicated document skeleton.

Target scope uses `TargetName`, resolved from the selected Core target folder.

## Canonical tags

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

`network-interfaces` remains a compatibility/evidence dataset. The document-facing
network tag uses `ethernet-interfaces` to avoid duplicate rendered content.
