# Contract-driven projections and dataset presentation

## Purpose

This document records the assembler repo's intended design for SDT rendering so agents and maintainers do not keep expanding the invoke/orchestration scripts with technology-specific normalization logic.

## Design summary

Assembler should remain a **generic contract consumer**.

Collectors and contracts should tell assembler:
- which dataset is being used
- what the dataset is intended to represent in a document
- which projection/view should shape the data
- how empty, structured, and evidence/debug outputs should behave

Assembler should then execute that declarative intent deterministically.

## Ownership boundaries

### Owned here
- assembler runtime scripts
- skeleton templates and runtime-facing mapping copies
- repo-local documentation
- tests proving assembler behavior
- export mirrors under `exports/LNV.AsBuiltDoc.Contracts/...` for offline handoff

### Not owned here
- `.deps/contracts` as a long-term source-of-truth authoring location

The `.deps/contracts` tree is a synced runtime dependency. If assembler work needs a contract edit in this repo, mirror the owned files into `exports/LNV.AsBuiltDoc.Contracts/...` so they can be moved into the contracts repo offline.

## Current contract facts in this repo

The repo already contains the main contract building blocks for the projection/view direction:

### 1. Mapping render hints
`mapping.dataset-to-sdt` supports render-hint fields including:
- `projectionRef`
- `renderAs`
- `view`
- `renderMode`
- `structuredValuePolicy`
- `missingProjectionPolicy`

Relevant files:
- `.deps/contracts/standards/mapping.dataset-to-sdt.schema.v1.json`
- `.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`

### 1b. Mapping sync policy (contract-owned)
`mapping.dataset-to-sdt` also carries sync policy for generating runtime skeleton mapping copies:
- `syncPolicy.collectorSkeletonMapping.allowedRenderAs`: allowed render shapes for this sync target
- `syncPolicy.collectorSkeletonMapping.selectors.defaultByRenderAs`: default selectors by render shape
- `syncPolicy.collectorSkeletonMapping.unsupportedRenderShape.documentFacing`: explicit policy (`fail`, `warn`, or `skip`) for required/document-facing mappings
- `syncPolicy.collectorSkeletonMapping.unsupportedRenderShape.nonDocumentFacing`: explicit policy (`fail`, `warn`, or `skip`) for optional/non-document mappings

The sync script must consume this policy instead of hardcoding render shape assumptions (`table`) or selector defaults (`items`).
For document-facing mappings, fail-closed behavior is the default unless policy explicitly changes it.

### 2. Projection/view contracts
Projection definitions now carry more than just column lists. They are the right place for:
- alias resolution
- output mode such as `table`, `scalar`, `list`, `json-evidence`, or `json-debug`
- empty-state handling
- row ordering
- identity keys
- formatting profiles
- column/filter shaping

Relevant files:
- `.deps/contracts/standards/assembler/assembler.projections.schema.v1.json`
- `.deps/contracts/standards/assembler/assembler.transform-semantics.v1.md`
- `.deps/contracts/tech/Lenovo.DE/assembler.projections.v1.json`

### 3. Dataset presentation sidecars
Collectors can inform assembler of upstream document intent through dataset presentation metadata sidecars such as:
- `presentationKind`
- `defaultItemRoot`
- `preferredProjectionViews`

Relevant files:
- `.deps/contracts/tech/Lenovo.DE/dataset/systems.assembler.meta.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/host-ports.assembler.meta.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/volume-mappings.assembler.meta.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/capabilities-normalized.assembler.meta.json`

## Practical guidance for assembler changes

When a rendered table is not converging or raw JSON leaks into output:

1. Check whether the dataset should be represented as a document-facing table, list, scalar, or evidence/debug payload.
2. Prefer fixing or extending:
   - dataset presentation metadata
   - mapping render hints
   - projection/view definitions
3. Only change invoke/orchestration scripts when the runtime lacks a **generic** capability needed to consume those contracts.
4. Avoid adding Lenovo-specific or tech-specific alias/fallback logic directly to the renderer when the rule can be declared in contracts.

## Lenovo.DE alignment

For Lenovo.DE, the intended model is:
- collector emits normalized, document-facing datasets plus raw evidence datasets
- mapping entries declare which SDTs are document-facing tables and which projection/view they use
- projection contracts define the actual table shapes
- evidence/debug JSON output remains explicit rather than accidental

This is especially important for:
- controller, tray, drive, host, and relationship tables
- DNS/time/management interface tables
- capability summary/limits/key-feature views
- low-level host access evidence vs reader-facing relationship tables

### Lenovo.DE host-ports FC TODO (contract backlog)

Current `host-ports` dataset rows in this repo snapshot do not emit `portWwn` / `nodeWwn`.
FC table projections may keep `PortWWN` / `NodeWWN` columns, but renderer resolution for missing source fields must remain null-safe so bundle rendering does not throw `ASB-ASM-SDT-UNHANDLED`.

TODO for Lenovo.DE contracts (when collector normalization is available):
- validate populated `PortWWN` (`source: portWwn`) values in `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC`
- validate populated `NodeWWN` (`source: nodeWwn`) values in `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC`
- optionally add FC narrative WWN fields only after the same normalized fields are present in `host-ports` dataset output

## Runtime-facing mapping copy

The file:
- `templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json`

is the assembler runtime-facing copy used with the skeleton/template pack. It should remain aligned with the authoritative contract mapping at:
- `.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`

When onboarding a new technology, update mapping contracts (including `syncPolicy`) and dataset metadata first; do not add technology-specific branches to sync scripts for render-shape handling.

## Sync quality-gate behavior (per technology)

`scripts/Sync-AssemblerContractsToRepo.ps1` now emits per-tech generation diagnostics and quality gates that must remain contract-driven:

- `generationStatus` is emitted per tech as one of:
  - `ok`: runtime mapping count matches expected contract outcome
  - `partial`: runtime mapping generated, but fewer entries than contract mappings
  - `empty`: contract mappings exist but zero runtime mappings were generated
  - `skipped`: mapping contract was not found for a discovered tech
- Per-tech dashboard JSON includes skip-reason counters:
  - `missingDataset`
  - `missingTag`
  - `missingDatasetTemplate`
  - `unsupportedShape`
- Invariant check: if `contract.total > 0` and `runtime.total == 0`, sync emits a high-severity warning or fails based on strict policy.
  - Strict policy can be forced with `-StrictEmptyGeneration`.
  - When strict mode is not supplied, sync warns and continues so operators can inspect skip-reason telemetry in the final dashboard JSON.

Do not document or implement a design where the template-local mapping becomes the only source of truth.

## Anti-patterns to avoid

- Adding more tech-specific normalization branches into `Invoke-AssemblerSdtRender.ps1`
- Treating raw JSON fallback as acceptable for document-facing table SDTs
- Editing `.deps/contracts` without mirroring owned changes into `exports/LNV.AsBuiltDoc.Contracts/...`
- Letting runtime skeleton mappings drift from the authoritative contract mapping

## Expected future behavior

The preferred end state is:
- collectors inform assembler through dataset metadata and normalized datasets
- mappings bind SDTs to explicit render intent and projection/view references
- projections define how rows are filtered, ordered, formatted, and rendered
- assembler remains small, deterministic, and generic
