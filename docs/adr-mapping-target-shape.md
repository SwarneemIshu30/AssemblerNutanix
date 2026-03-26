# Architecture decision note: Mapping target shape migration

## Status
Accepted — March 25, 2026.

## Context
The mapping contract currently allows either top-level `sdtTag` or `target` (or both) per mapping entry, and `target` itself can represent either `target.sdtTag` or a structured destination (`target.kind` + `target.path`). Runtime mapping copies under skeletons must stay aligned with contract intent and should move toward a canonical shape that is explicit and extensible.

References:
- `docs/contract-driven-projections.md`
- `.deps/contracts/standards/mapping.dataset-to-sdt.schema.v1.json`
- `exports/LNV.AsBuiltDoc.Contracts/standards/mapping.dataset-to-sdt.schema.v1.json`

## Decision

### 1) Canonical destination shape (`target`)
The canonical destination form for each mapping entry is:
- `target.kind`
- `target.path`

This is the preferred long-term shape because it is explicit, extensible, and decouples mapping intent from legacy single-field tag addressing.

### 2) Transitional dual shape (`sdtTag` + `target`)
During migration, dual-shape entries are allowed:
- top-level `sdtTag`
- `target` (preferably `target.kind` + `target.path`, but `target.sdtTag` remains permitted by schema)

When both are present, they must resolve to the same runtime destination.

### 3) Deprecation policy/timeline for `sdtTag`-only entries
- **Phase 0 (now through June 30, 2026):** `sdtTag`-only entries are allowed but discouraged.
- **Phase 1 (July 1, 2026 through September 30, 2026):** new or modified entries must not be `sdtTag`-only; existing untouched legacy entries may remain.
- **Phase 2 (October 1, 2026 onward):** `sdtTag`-only entries are disallowed in contract mappings and generated/runtime-facing mapping copies.

### 4) Acceptance rules per phase (CI policy)

#### Phase 0
- **Contracts (`.deps/contracts/...mapping.dataset-to-sdt...`):** allow `sdtTag`-only, dual-shape, and `target`-only.
- **Runtime mapping copies (`templates/skeletons/...*.mapping.json`):** same as contracts.
- **CI behavior:** pass with warning for `sdtTag`-only entries.

#### Phase 1
- **Contracts:** fail CI if changed lines introduce new `sdtTag`-only entries; allow pre-existing untouched `sdtTag`-only entries.
- **Runtime mapping copies:** fail CI for generated/updated entries that remain `sdtTag`-only.
- **CI behavior:** enforce “no new legacy shape” while allowing staged migration.

#### Phase 2
- **Contracts:** fail CI if any `sdtTag`-only entry exists.
- **Runtime mapping copies:** fail CI if any `sdtTag`-only entry exists.
- **CI behavior:** require canonical `target` destination shape repo-wide.

## Consequences
- Migration is explicit and time-bounded.
- CI prevents regression toward legacy-only mapping entries.
- Runtime-facing mapping copies stay contract-aligned while moving to the canonical target model.
- Contract sync quality gates now expose per-tech generation telemetry (`generationStatus` and skip-reason counters) and support opt-in strict failure for empty generation via `-StrictEmptyGeneration`, so migration drift is visible and enforceable at sync time when desired.
