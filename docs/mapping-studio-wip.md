# Mapping Studio WIP Status

`Mapping Studio` is the current Windows WPF workbench for viewing and editing assembler dataset-to-SDT connections. It is intentionally being built contract-first and should be treated as a work in progress.

## Current status

- Scope is currently `Start-AssemblerGui.Wpf.ps1` only.
- The workbench is aimed at DOCX template collections only.
- Lenovo.DE is the current reference implementation, with other techs lighting up when they have the required catalog, mapping, dataset metadata, and example bundle content.
- The first goal of the current UX is inspection: see what is connected now, then change it when needed.

## Current WPF tab layout

The WPF launcher currently exposes three top-level tabs:

1. `Document Properties`
2. `Render Workflow`
3. `Mapping Studio`

Within `Mapping Studio`, the current nested tabs are:

1. `Overview`
2. `Datasets`
3. `Targets`
4. `Connector`
5. `Changes`

## Current implemented behavior

### Document Properties progress

The WPF document-property tab now includes user-facing fields for the underlying DOCX property names below:

- `Document Version` -> `LNV.Version`
- `Configuration Snapshot Date` -> `LNV.ConfigSnapDate`
- `Reference ID` -> `LNV.ReferenceID`

Current defaults and behavior:

- `Document Version` defaults to `v1.0.0`
- `Configuration Snapshot Date` is refreshed from the currently loaded bundle capture date when bundle metadata is available
- `Reference ID` is available for manual entry
- `CoverKey.png` and `HeadFootKey.png` are shown as visual references under the property grid

### Mapping Studio progress

Current implemented Mapping Studio behavior includes:

- template collection selection backed by the catalog, filtered to DOCX entries
- workbench assembly from contract mappings, runtime skeleton mapping, dataset presentation sidecars, and example bundle data
- `Overview` summary of mapped targets, staged targets, unmapped targets, dataset coverage, and warnings
- `Datasets` inspection view with dataset metadata and example data summary
- `Targets` inspection view with placement and mapping-type grouping detail
- a connection-first `Connector` tab that lists current connections before editing
- read-only connection inspection with explicit actions to `Edit mapping`, `Replace target`, or create a `New connection`
- example preview for scalar and table authoring using current bundle/example resolution rules
- queued-change review and save flow

### Connector UX direction

The current `Connector` tab is optimized around viewing live mappings first:

- the main list shows one row per current mapping entry
- rows summarize `dataset -> target` plus selector/projection context
- quick filters currently cover `All`, `Mapped`, `Placed`, `Staged`, `Scalar`, and `Table`
- selecting a row shows a read-only detail inspector and example preview
- editing is secondary and is entered explicitly from the selected connection

## Save and contract behavior

When Mapping Studio authoring is available, the save flow is intended to:

1. update `.deps/contracts/tech/<techId>/mapping.dataset-to-sdt.v1.yaml`
2. mirror the same owned change under `exports/LNV.AsBuiltDoc.Contracts/...`
3. regenerate the runtime skeleton mapping JSON under `templates/skeletons/...`

The runtime skeleton mapping remains a generated/runtime-facing artifact and should stay aligned with the contract mapping.

## Work in progress boundaries

The current implementation should still be treated as WIP:

- authoring support currently focuses on `scalar` and `table`; diagram views should be edited later as a separate contract surface backed by `assembler.diagrams.v1.json`
- unsupported render shapes are surfaced for inspection, not silently converted to raw JSON
- if YAML support is unavailable in the current PowerShell session, Mapping Studio falls back to read-only mode
- staged targets are valid contract targets, but they are not automatically inserted into the DOCX template
- connector UX, preview detail, and authoring ergonomics are still being refined

## Current documentation intent

This page exists to reflect the current in-repo state while the Mapping Studio work continues. Update it when the implemented WPF behavior changes, especially around:

- connector UX
- authoring support level
- save-path behavior
- bundle/example preview behavior
- supported document-property fields
