# Lenovo.DE Skeleton Blueprint (v1)

This blueprint describes how Lenovo.DE content plugs into the common AsBuilt spine.

## Placement in Common Spine
Recommended placement:
- **Storage** technology module section within the common spine
  - Executive summary (storage overview)
  - System inventory and health
  - Drives and capacity layout
  - Pools / Volume Groups / DDP containers
  - Volumes/LUNs
  - (Future) Alerts/Events, Replication, Hosts/Host groups

## SDT Blocks
Per storage system, insert these SDTs:

1) Summary
- `LNV.Lenovo.DE.System[<SystemId>].Summary`

2) Core tables
- Systems: `...Tables.Systems`
- Drives: `...Tables.Drives`
- Storage Containers: `...Tables.StorageContainers`
- Volumes: `...Tables.Volumes`

3) Findings
- `...Findings` (optional)

4) Evidence
- `...Evidence.Placeholder` (optional)

## Rendering Guidance
- Main body: Summary + Findings + small tables
- Appendix: large inventory tables (drives, volumes) if large environment

## v1 Limitations
- Events/alerts not included yet.
- Host mappings not included yet.
