# Canonical Direct V1 Composition

## Runtime contract

Assembler discovers document datasets only from `manifest.json`. A document
dataset must use:

`datasets/<TechId>/<Domain>/<ObjectKey>/<Dataset>.json`

Each file must be an `lnv.collector.dataset.v1` native envelope. `<ObjectKey>`
must resolve to a target, target group, or solution in the solution plan.
Assembler rejects `collector-out`, `datasets/raw`, `target_*`, `system_*`, unresolved
placeholders, duplicate identities, missing files, and malformed envelopes.

Raw evidence belongs under `evidence/<TechId>/<ObjectKey>/...`. Findings and coverage artifacts
remain evidence and are not projected as document datasets.

## Mapping v2

Runtime mappings use schema v2 and logical dataset keys such as `systems`.
They do not contain physical bundle paths. During composition, Assembler writes
an internal render plan with:

- the original logical `dataset`
- an internal `resolvedDataset` path
- aggregated native envelopes
- `_assembler` provenance on each item

Projection contracts may declare provenance columns by selecting fields such as
`_assembler.displayName`, `_assembler.objectKey`, or `_assembler.tags.site`.
Collectors must not add document labels or columns for this purpose.

## Composition

`assembler.composition-map.json` is the authoritative selection of typed
objects and technology contributions for a document run. When no map is
supplied, the default includes every canonical object and enabled catalog
entry.

The contract-owned default policy is
`standards/assembler/assembler.default-composition-policy.v1.json`. It defines
deterministic append aggregation and the projection-visible provenance fields.
Technology policy variants belong in contracts, not orchestration scripts.

Mapping Studio reads the same canonical catalog. Its preview examples come from
manifest entries rather than collector folder conventions.

## Breaking changes

- Legacy collector discovery and placeholder expansion are unsupported.
- `run_summary.json` has no special rendering or discovery behavior.
- `collector-out`, `datasets/raw`, `target_*`, and `system_*` layouts are rejected.
- Runtime skeleton mappings must use logical schema-v2 dataset keys.
- Missing required canonical inputs fail closed.
- Structured document-facing content must use scalar, list, table, or diagram
  projection intent; raw JSON is evidence only.

## Collector onboarding

1. Write native envelopes directly to the Core-provided canonical object root.
2. Preserve stable object identity in envelope provenance and dataset items.
3. Put raw captures under `evidence/<TechId>/<ObjectKey>`, outside document dataset discovery.
4. Define dataset schemas and presentation sidecars in the contracts repo.
5. Define logical mappings, projections, and any composition policy in contracts.
6. Add canonical multi-target fixtures and packaged-runtime smoke coverage.

## Rollout sequence

1. Publish mapping v2, composition-map, and composition-policy contracts.
2. Release canonical-output collectors.
3. Release Assembler with legacy-layout rejection enabled.
4. Validate representative multi-target bundles for each collector.
5. Enable combined technology catalogs only after every contribution has a
   template, projections, and canonical smoke fixture.

The `.deps/contracts` files in this repository are runtime snapshots. New or
changed contract artifacts are mirrored under `exports/LNV.AsBuiltDoc.Contracts`
for offline handoff to the contracts repository.
