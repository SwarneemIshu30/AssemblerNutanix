# Lenovo.DE SDT Inventory (v1)

Tag taxonomy baseline:
`LNV.<TechId>.System[<SystemId>].<BlockType>`

TechId:
- `Lenovo.DE`

## Canonical convention
Use a per-system SDT convention consistently for every Lenovo.DE dataset:
- Summary block: `LNV.Lenovo.DE.System[<SystemId>].Summary`
- Table blocks: `LNV.Lenovo.DE.System[<SystemId>].Tables.<BlockName>`

## System scope
Key (`<SystemId>`):
- system id or name (prefer stable id when available)

### Summary
- `LNV.Lenovo.DE.System[<SystemId>].Summary`

### Tables (all mapped datasets)
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Controllers`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.ManagementInterfaces`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Transport`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.DNS`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Time`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Trays`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.HostPortsiSCSI`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.HostPortsFC`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Hosts`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.HostGroups`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.HostsToHostGroups`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.HostGroupsToVolumes`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.HostsToVolumes`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Drives`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.StorageContainers`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Volumes`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.VolumeMappings`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.ASUP`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesSummary`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesKeyFeatures`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesLimits`

### Findings (optional v1 placeholder)
- `LNV.Lenovo.DE.System[<SystemId>].Findings`

### Evidence placeholder
- `LNV.Lenovo.DE.System[<SystemId>].Evidence.Placeholder`

## Example rendering notes

### Placement and ordering (example)
Recommended per-system order in rendered output:
1. `LNV.Lenovo.DE.System[<SystemId>].Summary`
2. `LNV.Lenovo.DE.System[<SystemId>].Findings` (when present)
3. Tables in this order:
   - `...Tables.Controllers`
   - `...Tables.ManagementInterfaces`
   - `...Tables.Transport`
   - `...Tables.DNS`
   - `...Tables.Time`
   - `...Tables.StorageContainers`
   - `...Tables.Volumes`
   - `...Tables.Trays`
   - `...Tables.HostPortsiSCSI`
   - `...Tables.HostPortsFC`
   - `...Tables.Hosts`
   - `...Tables.HostGroups`
   - `...Tables.HostsToHostGroups`
   - `...Tables.HostGroupsToVolumes`
   - `...Tables.HostsToVolumes`
   - `...Tables.Drives`
   - `...Tables.ASUP`
   - `...Tables.VolumeMappings`
   - `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesSummary`
   - `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesKeyFeatures`
   - `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesLimits`

Practical placement guidance:
- Keep Summary, Findings, and operational tables needed for the main narrative in the main body, including the capability tables that surface feature posture and limits.
- Keep large inventory tables, low-priority support tables, and feature/license detail in the appendix when row counts are high.
- Keep table ordering stable even when some tables are omitted from the main narrative.

### Empty or missing dataset behavior
- If a dataset file is missing/unavailable, do not render a broken table; render a short "not collected" note in the corresponding SDT block.
- If a dataset is present but has zero rows, render the table title and a "No data returned" row/state.
- Do not fail document generation solely because optional blocks (`Findings`, `Evidence.Placeholder`) are absent.
- Keep table ordering stable even when some tables are empty or omitted.

### `<SystemId>` naming/keying guidance
- Use a stable storage-system identity key for `<SystemId>` (array/system id preferred over display name).
- Normalize `<SystemId>` consistently across all tags for the same system (case, separators, and formatting must match).
- Avoid ephemeral values (temporary hostnames, session ids, or mutable labels) as `<SystemId>`.
- If a stable id is unavailable, use a deterministic fallback (for example normalized management FQDN/IP), and use the same fallback everywhere for that system.

### Required tag coverage checklist (must match `mapping.dataset-to-sdt.v1.yaml`)
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Summary`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Controllers`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.ManagementInterfaces`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Transport`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.DNS`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Time`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Trays`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.HostPortsiSCSI`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.HostPortsFC`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Hosts`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.HostGroups`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.HostsToHostGroups`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.HostGroupsToVolumes`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.HostsToVolumes`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Drives`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.StorageContainers`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Volumes`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.VolumeMappings`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.ASUP`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesSummary`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesKeyFeatures`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.CapabilitiesLimits`

## Notes
- The `systems` dataset maps to the per-system Summary block rather than a separate `Tables.Systems` table.
- Volume Groups and Disk Pools (DDP) are presented together as StorageContainers in v1.
- Host, host-group, and host-access projection tables are included so SDTs can render end-to-end host/host-group to LUN relationships from the normalized bundle.
- `Tables.HostGroups` is now suitable for direct rendering because the collector already materializes membership summaries on each host-group row (for example `memberRefs` and `memberNames`), so renderers do not need to reconstruct group membership before presenting that table.
- For host-access content, prefer `Tables.HostsToHostGroups`, `Tables.HostGroupsToVolumes`, and `Tables.HostsToVolumes` as the report-facing tables because they present the host/group/volume story in reader-friendly sections.
- `Tables.VolumeMappings` remains the canonical low-level evidence/fact source for raw mapping rows, while `Tables.HostsToHostGroups`, `Tables.HostGroupsToVolumes`, and `Tables.HostsToVolumes` are now formal collector-emitted relationship datasets with their own Lenovo.DE dataset contracts.
- Future datasets (events/alerts) may add:
  - `LNV.Lenovo.DE.System[<SystemId>].Tables.Events`
  - `LNV.Lenovo.DE.System[<SystemId>].Tables.Alerts`
