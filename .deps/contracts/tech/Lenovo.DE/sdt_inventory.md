# Lenovo.DE SDT Inventory (v1)

Tag taxonomy baseline:
`LNV.<TechId>.<Domain>[<Key>].<BlockType>`

TechId:
- `Lenovo.DE`

## System scope
Key (`<Key>`):
- system id or name (prefer stable id when available)

### Summary
- `LNV.Lenovo.DE.System[<SystemId>].Summary`

### Tables (core)
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Systems` (systems inventory / identity)
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Controllers` (controllers if collected)
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Drives`
- `LNV.Lenovo.DE.System[<SystemId>].Tables.StorageContainers` (VG + DDP)
- `LNV.Lenovo.DE.System[<SystemId>].Tables.Volumes`

### Findings (optional v1 placeholder)
- `LNV.Lenovo.DE.System[<SystemId>].Findings`

### Evidence placeholder
- `LNV.Lenovo.DE.System[<SystemId>].Evidence.Placeholder`

## Example rendering notes

### Placement and ordering (example)
Recommended per-system order in rendered output:
1. `LNV.Lenovo.DE.System[<SystemId>].Summary`
2. `LNV.Lenovo.DE.System[<SystemId>].Findings` (when present)
3. Core tables in this order:
   - `...Tables.Systems`
   - `...Tables.Controllers`
   - `...Tables.StorageContainers`
   - `...Tables.Volumes`
   - `...Tables.Drives`

Practical placement guidance:
- Keep Summary and Findings in the main narrative section.
- Keep `Tables.Systems`, `Tables.Controllers`, and `Tables.StorageContainers` in main body unless row counts are large.
- Move `Tables.Volumes` and `Tables.Drives` to appendix for large estates, while leaving a short summary in main body.

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
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Systems`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Controllers`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Drives`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.StorageContainers`
- [ ] `LNV.Lenovo.DE.System[<SystemId>].Tables.Volumes`

## Notes
- Volume Groups and Disk Pools (DDP) are presented together as StorageContainers in v1.
- Future datasets (events/alerts) may add:
  - `LNV.Lenovo.DE.System[<SystemId>].Tables.Events`
  - `LNV.Lenovo.DE.System[<SystemId>].Tables.Alerts`
