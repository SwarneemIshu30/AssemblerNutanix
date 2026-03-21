# Lenovo.DE Skeleton Blueprint (v1)

This blueprint describes how Lenovo.DE content plugs into the common AsBuilt spine.

## Canonical SDT convention
Apply one per-system SDT convention across Lenovo.DE content:
- Summary: `LNV.Lenovo.DE.System[<SystemId>].Summary`
- Tables: `LNV.Lenovo.DE.System[<SystemId>].Tables.<BlockName>`

## Placement in Common Spine
Recommended placement:
- **Storage** technology module section within the common spine
  - Executive summary (storage overview)
  - System inventory and health
  - Management interfaces and transport
  - Name services and time configuration
  - Controllers and enclosure layout
  - Hosts, host groups, host ports, and host-access projections
  - Drives and capacity layout
  - Pools / Volume Groups / DDP containers
  - Volumes/LUNs, mapping evidence, and derived access views
  - Support and capability rollups
  - (Future) Alerts/Events, Replication

## SDT Blocks
Per storage system, insert these SDTs:

1) Summary
- `LNV.Lenovo.DE.System[<SystemId>].Summary`

2) Tables
- Controllers: `LNV.Lenovo.DE.System[<SystemId>].Tables.Controllers`
- Management Interfaces: `LNV.Lenovo.DE.System[<SystemId>].Tables.ManagementInterfaces`
- Transport: `LNV.Lenovo.DE.System[<SystemId>].Tables.Transport`
- DNS: `LNV.Lenovo.DE.System[<SystemId>].Tables.DNS`
- Time: `LNV.Lenovo.DE.System[<SystemId>].Tables.Time`
- Trays: `LNV.Lenovo.DE.System[<SystemId>].Tables.Trays`
- Host Ports (iSCSI): `LNV.Lenovo.DE.System[<SystemId>].Tables.HostPortsiSCSI`
- Host Ports (FC): `LNV.Lenovo.DE.System[<SystemId>].Tables.HostPortsFC`
- Hosts: `LNV.Lenovo.DE.System[<SystemId>].Tables.Hosts`
- Host Groups: `LNV.Lenovo.DE.System[<SystemId>].Tables.HostGroups`
- Hosts to Host Groups: `LNV.Lenovo.DE.System[<SystemId>].Tables.HostsToHostGroups`
- Host Groups to Volumes: `LNV.Lenovo.DE.System[<SystemId>].Tables.HostGroupsToVolumes`
- Hosts to Volumes: `LNV.Lenovo.DE.System[<SystemId>].Tables.HostsToVolumes`
- Drives: `LNV.Lenovo.DE.System[<SystemId>].Tables.Drives`
- Storage Containers: `LNV.Lenovo.DE.System[<SystemId>].Tables.StorageContainers`
- Volumes: `LNV.Lenovo.DE.System[<SystemId>].Tables.Volumes`
- Volume Mappings: `LNV.Lenovo.DE.System[<SystemId>].Tables.VolumeMappings`
- ASUP: `LNV.Lenovo.DE.System[<SystemId>].Tables.ASUP`
- Capability Summary: `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesSummary`
- Capability Key Features: `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesKeyFeatures`
- Capability Limits: `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesLimits`

3) Findings
- `LNV.Lenovo.DE.System[<SystemId>].Findings` (optional)

4) Evidence
- `LNV.Lenovo.DE.System[<SystemId>].Evidence.Placeholder` (optional)

## Rendering Guidance
- Main body: Summary plus the small, reader-critical operational/configuration tables.
- Appendix: large inventory tables and low-priority support/license detail when the environment is large.
- Keep naming keyed per system for every SDT so mixed multi-array documents remain unambiguous.

## v1 Narrative Layout
- Events/alerts are not included yet.
- Host-access narrative should be presented through the split SDTs: `Tables.HostsToHostGroups` for membership context, `Tables.HostGroupsToVolumes` for shared group access, and `Tables.HostsToVolumes` for host-level effective access.
- `Tables.VolumeMappings` remains the broad evidence table for normalized access facts, while the three split host-access tables are the intended reader-friendly projections built from the shared host/group/mapping dataset.
