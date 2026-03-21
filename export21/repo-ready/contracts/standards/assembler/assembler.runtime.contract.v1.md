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

## Determinism requirements
- Stable ordering for sections, tables, and rows
- Stable null/empty rendering policy
- Stable sort keys must be documented per mapped dataset

## Outputs
- Rendered document(s)
- Render report JSON (schema-bound)
- Optional diagnostics log bundle
