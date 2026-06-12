# Nutanix.Prism Skeleton Blueprint (v1)

This blueprint describes how Nutanix.Prism content plugs into the common
AsBuilt document spine.

## Canonical SDT convention
- Target summary: `LNV.Nutanix.Prism.Target[<TargetKey>].Summary`
- Target tables: `LNV.Nutanix.Prism.Target[<TargetKey>].Tables.<BlockName>`
- Group tables: `LNV.Nutanix.Prism.Group[<GroupKey>].Tables.<BlockName>`

## Placement in Common Spine
Recommended placement:
- Virtualization / HCI technology section
  - Prism environment overview
  - Prism Central targets and managed clusters
  - Prism Element cluster-local inventory
  - Compute inventory: hosts, host NICs, CVMs, VMs, VM NICs
  - Network inventory: networks/subnets and virtual switches
  - Storage inventory: containers, pools, disks, datastores, virtual disks
  - Protection/replication inventory
  - Configuration: SMTP, SNMP, auth, NFS whitelist, witness, license
  - Health and alert configuration
  - Collection sources and relationship/correlation evidence

## SDT Blocks
Per target, insert:

1. Summary
- `LNV.Nutanix.Prism.Target[<TargetKey>].Summary`

2. Core tables
- Clusters
- Hosts
- Host NICs
- CVMs
- VMs
- Networks
- Virtual switches
- Storage containers
- Storage pools
- Disks
- Relationships

3. Configuration and optional inventory
- Alert configuration
- SMTP
- SNMP
- Auth config
- NFS whitelist
- Witness
- Images
- Templates
- SSL certificates
- Health checks
- Protection domains
- Remote sites
- Snapshots
- Virtual disks
- Replication
- Unprotected VMs
- License

4. Evidence
- Collection sources
- Raw evidence references

Per target group, insert:
- `LNV.Nutanix.Prism.Group[<GroupKey>].Tables.Relationships`

## Rendering Guidance
- Present Prism Central and Prism Element as separate collection sources.
- Use group relationship tables to explain hybrid correlation.
- Keep unresolved correlations visible with warnings; do not hide records simply because a UUID join failed.
- Put large raw/evidence-oriented tables in appendices.

## v1 Limits
- Prism Central v4 is the preferred source for PC-owned datasets, with Prism Central v3 and Prism Element retained for fallback and cluster-local coverage.
- Target groups are optional and must not be required for target-only plans.
- The assembler remains dataset-driven and target-group agnostic.
