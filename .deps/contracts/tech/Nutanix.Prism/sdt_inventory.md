# Nutanix.Prism SDT Inventory (v1)

Tag taxonomy baseline:
`LNV.Nutanix.Prism.<Scope>[<Id>].<BlockType>`

TechId:
- `Nutanix.Prism`

## Canonical convention
Use target-scoped SDTs for per-endpoint datasets and group-scoped SDTs for
hybrid correlation outputs.

## Target Scope
Target key:
- `targets[].key`

Target summary:
- `LNV.Nutanix.Prism.Target[<TargetKey>].Summary`

Target tables:
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Clusters`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Hosts`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.HostNics`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.CVMs`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.VMs`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Networks`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.VirtualSwitches`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.StorageContainers`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.StoragePools`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Disks`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.ProtectionDomains`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.RemoteSites`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Images`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Templates`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.HealthChecks`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.AlertsConfiguration`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.SMTP`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.SNMP`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.AuthConfig`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.SslCertificates`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.NfsWhitelist`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Witness`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Snapshots`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.VirtualDisks`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Replication`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.UnprotectedVMs`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.VMNics`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.License`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.CollectionSources`
- `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.Relationships`

## Target Group Scope
Group key:
- `targetGroups[].key`

Group tables:
- `LNV.Nutanix.Prism.Group[<GroupKey>].Tables.Relationships`

## Notes
- Assemblers consume normalized datasets and relationships only.
- Assemblers must not call Prism APIs or infer Prism Central/Element topology.
- Large inventory tables should move to appendix sections when document size warrants it.
