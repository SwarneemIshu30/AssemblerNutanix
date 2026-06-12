# Contract-driven projections and dataset presentation

## Purpose

This document records the assembler repo's intended design for SDT rendering so agents and maintainers do not keep expanding the invoke/orchestration scripts with technology-specific normalization logic.

## Design summary

Assembler should remain a **generic contract consumer**.

Collectors and contracts should tell assembler:
- which dataset is being used
- what the dataset is intended to represent in a document
- which projection/view should shape the data
- which diagram view should shape graph/topology output
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

The `.deps/contracts` tree is a synced runtime dependency. If assembler work needs a contract edit in this repo, update `.deps/contracts` for immediate runtime testing and mirror the same changed owned files into `exports/LNV.AsBuiltDoc.Contracts/...` so they can be moved into the contracts repo offline.

## Current contract facts in this repo

The repo already contains the main contract building blocks for the projection/view direction:

### 1. Mapping render hints
`mapping.dataset-to-sdt` supports render-hint fields including:
- `projectionRef`
- `diagramRef`
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

### 3. Diagram contracts
Diagram definitions are separate from table projections. They are the right place for graph/topology intent:
- rendering engine and diagram kind
- input datasets and item roots
- nodes, fields, grouping, and edges
- layout and fallback policy

Mappings should declare `renderAs: diagram`, `renderMode: diagram`, and `diagramRef`; assembler should then resolve the diagram definition and render an image for DOCX output. Text/debug output should use a concise placeholder with diagram metadata, not raw JSON.

Relevant files:
- `.deps/contracts/standards/assembler/assembler.diagrams.schema.v1.json`
- `.deps/contracts/tech/Lenovo.DE/assembler.diagrams.v1.json`

The first implemented engine is `diagrammer.core` for topology-style diagrams. DE physical front-view drive SVGs are intentionally out of this contract family for now and should be handled as a later physical-layout diagram type.

### 4. Dataset presentation sidecars
Collectors can inform assembler of upstream document intent through dataset presentation metadata sidecars such as:
- `presentationKind`
- `defaultItemRoot`
- `preferredProjectionViews`

Relevant files:
- `.deps/contracts/tech/Lenovo.DE/dataset/systems.assembler.meta.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/host-ports.assembler.meta.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/volume-mappings.assembler.meta.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/capabilities-normalized.assembler.meta.json`

## Direct-v1 dependency chain

The intended dependency chain in this repo is:

1. Collector emits Direct-v1 datasets in `lnv.collector.dataset.v1` envelopes.
2. `mapping.dataset-to-sdt` binds those datasets to SDT destinations and declares render intent through `renderHint` fields such as `renderAs`, `projectionRef`, and `view`.
3. Dataset sidecars under `tech/<techId>/dataset/*.assembler.meta.json` describe upstream document intent and dataset path templates used by sync/runtime generation.
4. `Sync-AssemblerContractsToRepo.ps1` consumes `renderAs` and `syncPolicy` to generate the runtime-facing skeleton mapping copy.
5. `Invoke-AssemblerSdtRender.ps1` resolves the selected projection or diagram through `projectionRef`, `diagramRef`, `view`, tag, and alias lookup, then executes the currently implemented projection/diagram subset against DOCX or text output.

## Current runtime subset

The current renderer already consumes the Direct-v1 contract model, but only a subset is fully implemented.

Current supported runtime behavior:
- Direct-v1 facts are read from `lnv.collector.dataset.v1` envelopes, with a narrow compatibility path for legacy `run_summary.json`.
- Mapping contracts already declare `renderHint.renderAs`, `projectionRef`, and `view`.
- Sync already consumes `renderAs` and `syncPolicy.collectorSkeletonMapping`.
- Projection lookup already supports direct tag lookup, alias lookup, `projectionRef`, and `view`.
- Current projection execution supports aliases, `filter`, legacy `sortBy`, `columns`, and column formats `bytesHuman` and `join`.
- Current table empty-state handling is partial: `emptyBehavior=placeholder` can synthesize a placeholder row, but the full `emptyBehavior` model is not yet enforced.
- Diagram lookup supports direct tag lookup, alias lookup, and `diagramRef`.
- Current diagram execution supports `diagrammer.core` topology diagrams with dataset inputs, simple field/template expansion, equality filters, node groups, and edges.
- DOCX diagram output embeds a PNG image; text output renders a placeholder such as `[diagram: ...]`.

Current runtime mode precedence:
- projection `renderMode`
- mapping `renderMode`
- mapping `renderAs`
- `_TABLE_JSON` suffix heuristic
- fallback `scalar`

Current unsupported or partial areas:
- `renderAs` is not yet authoritative
- `list` is not yet a distinct runtime rendering mode
- `rowOrder`, `identityKeys`, and `formatProfiles` are defined in contracts but not yet executed by the renderer
- `renderAs`/`renderMode` disagreement is not yet enforced as a contract error
- `emptyBehavior` values other than the current placeholder path are not yet fully implemented
- Diagram expressions are intentionally minimal and do not execute arbitrary script.
- Physical front-view drive diagrams are not implemented in this pass.

## Why `renderAs` does not win today

`renderAs` is the more mature Direct-v1 contract form, but it cannot be described as authoritative today because the runtime dependency chain is still mixed:

- The contract layer already uses `renderAs` heavily in Lenovo.DE mappings.
- Sync depends on `renderAs` today through `allowedRenderAs` and `selectors.defaultByRenderAs`.
- The renderer still depends on legacy `renderMode` precedence because the execution engine and validation rules have not yet caught up to the richer projection contract surface.
- Lenovo.DE currently works because mappings and projections mostly duplicate intent safely, with `renderAs`, `projectionRef`, `view`, and projection `renderMode` aligned instead of conflicting.

Mode differences in the current repo:
- `renderMode`: legacy runtime execution switch still consumed first by the renderer.
- `renderAs`: newer declarative contract intent already used by mappings and sync.
- `projectionRef`: explicit projection identity for shaping rows/values.
- `diagramRef`: explicit diagram identity for shaping graph/topology image output.
- `view`: named projection/view selector used during projection lookup.

## Target semantics and backlog

The intended Direct-v1 end state is still:
- `renderAs` becomes canonical and wins over legacy `renderMode`.
- `renderAs`/`renderMode` disagreement becomes a contract error.
- Projection execution grows to support `list`, `rowOrder`, `identityKeys`, `formatProfiles`, and complete `emptyBehavior`.

Dependencies before that transition should be described as backlog items, not implied as current behavior:
- update runtime mode resolution
- update explicitness and mismatch validation
- extend projection execution semantics
- add focused regression tests before changing precedence

## Practical guidance for assembler changes

When a rendered table is not converging or raw JSON leaks into output:

1. Check whether the dataset should be represented as a document-facing table, list, scalar, or evidence/debug payload.
2. Prefer fixing or extending:
   - dataset presentation metadata
   - mapping render hints
   - projection/view definitions
   - diagram definitions
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

### Cross-technology contribution composition TODO

Support applying multiple technology mappings sequentially to one host skeleton
and output. Preserve each contributing technology's own tag namespace,
contracts, and projections; resolve targets independently; use deterministic
contribution ordering; and emit one aggregate render report.
