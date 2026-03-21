# Assembler Runtime Contract (Direct-v1) — v1

## Purpose
Defines normative behavior for Assembler consumption of Direct-v1 bundles and production of SDT-populated outputs.

## Inputs
Required:
- Bundle root containing `manifest.json`, `objectIndex.json`, `config/solution.plan.json`
- Contracts root containing standards schemas and tech mapping artifacts
- Selected document template/profile for render target

Optional:
- `coverage.json` datasets
- finding datasets
- strictness override flags

## Lifecycle
1. Load
2. Validate
3. Transform
4. Render
5. Finalize

Each stage MUST emit stage diagnostics with UTC timestamps.

## Failure policy
- Fatal: invalid JSON, schema mismatch for required artifacts, required mapping unresolved, document write failure
- Warning: optional dataset absent, optional mapping unresolved, non-fatal format fallback
- Skipped: mapping intentionally inapplicable for selected profile/scope

## Compatibility policy
- Assembler SHOULD prefer native `lnv.collector.dataset.v1` envelopes for every dataset input.
- Assembler MAY apply a narrowly-scoped compatibility path for known legacy summary artifacts such as Lenovo.DE `run_summary.json` so required renders do not fail solely on envelope validation while collector/Core output is being corrected.
- Any compatibility path MUST preserve existing mapped values, emit a warning in the render report, and remain limited to the named legacy artifact shape.

## Determinism requirements
- Stable ordering for sections, tables, and rows
- Stable null/empty rendering policy
- Stable sort keys must be documented per mapped dataset

## Outputs
- Rendered document(s)
- Render report JSON (schema-bound)
- Optional diagnostics log bundle
