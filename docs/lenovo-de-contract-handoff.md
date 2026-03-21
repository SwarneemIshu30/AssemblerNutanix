# Lenovo.DE contract alignment handoff

## Assembler-side updates applied here

This repository has been updated to better match the current Lenovo.DE contract pack under `.deps/contracts/tech/Lenovo.DE`.

Applied in Assembler:
- kept the legacy `run_summary.json` compatibility path narrowly scoped in `Invoke-AssemblerSdtRender.ps1`
- kept existing Lenovo.DE summary selectors stable for `run_summary.json`
- aligned the Lenovo.DE collector skeleton template with the current contract table layout by adding sections for:
  - Controllers
  - Management Interfaces
  - Transport
  - DNS
  - Time
  - Trays
  - Host Ports (iSCSI)
  - Host Ports (FC)
  - Hosts
  - Host Groups
  - Hosts to Host Groups
  - Host Groups to Volumes
  - Hosts to Volumes
  - Drives
  - Storage Containers
  - Volumes
  - Volume Mappings
  - ASUP
  - Capabilities Summary
  - Capabilities Key Features
  - Capabilities Limits
- added matching dataset-to-SDT mappings and table projections for the newly surfaced Lenovo.DE datasets

## Remaining handoff for Lenovo.DE/Core repo

The following work still belongs in Lenovo.DE/Core rather than this assembler repository:

1. Emit `run_summary.json` as a native `lnv.collector.dataset.v1` envelope.
   - The assembler compatibility path is transitional only.
   - Preferred target shape: standard dataset envelope with the summary object carried inside `items[0]`.

2. Confirm host-port transport coverage in live bundles.
   - The assembler now exposes separate iSCSI and FC table blocks.
   - Collector/Core should confirm whether FC rows are emitted in normalized `host-ports.json` for all supported arrays and firmware versions.

3. Confirm capability projection expectations.
   - Assembler currently renders three views from `capabilities-normalized`:
     - summary
     - key features
     - limits
   - Lenovo.DE/Core should confirm the intended filtering/sorting contract if the capability taxonomy evolves.

4. Confirm optional dataset behavior for empty relationship tables.
   - The template now includes host/group/volume relationship sections.
   - Collector/Core should continue emitting valid envelopes with `item_count: 0` when those relationship datasets are empty.

## Source contracts reviewed
- `.deps/contracts/tech/Lenovo.DE/sdt_inventory.md`
- `.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`
- `.deps/contracts/tech/Lenovo.DE/skeleton_blueprint.md`
- `.deps/contracts/tech/Lenovo.DE/collector_spec.md`
