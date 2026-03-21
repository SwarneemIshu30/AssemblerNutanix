# Assembler Handoff (Core staging -> standalone repo)

## Why this exists
`/Assembler` and `/export/repo-ready` were created in Core as a temporary development and transfer location.

Target state:
- Assembler code moves to `LNV.AsBuiltDoc.Assembler`
- Contract artifacts move to `LNV.AsBuiltDoc.Contracts` (or are vendored by Assembler)

## Locked Direct-v1 assumptions
- Bundle structure and collector isolation come from Core Direct-v1.
- Dataset contract relies on `lnv.collector.dataset.v1` envelope.
- Tech mappings are contract-driven (`mapping.dataset-to-sdt.v1.yaml`).

## Delivered in this handoff

### Staging workspace
- `/Assembler/*` with move-ready folder scaffold and documentation placeholders.

### Repo-ready export package
- `/export/repo-ready/contracts/standards/*`
  - Assembler runtime contract doc
  - Assembler input schema
  - Assembler render report schema
  - Assembler error model
  - Transformation semantics spec
- `/export/repo-ready/contracts/manifest.json`
- `/export/repo-ready/handoff/assembler-knowledge-pack.v1.json`
- `/export/repo-ready/handoff/assembler-knowledge-pack.schema.v1.json`
- `/export/repo-ready/handoff/duplication-audit.v1.json`
- `/export/repo-ready/handoff/merged-items-audit.v1.json`

## Migration steps
1. Copy `/Assembler/*` into new Assembler repository root.
2. Copy `/export/repo-ready/contracts/standards/*` into Contracts standards location.
3. Copy knowledge pack + schema into Assembler `docs/handoff/`.
4. Update destination repos with final semantic versioning and commit SHA metadata.
5. Validate knowledge pack JSON against schema.

## Post-move acceptance checks
- Assembler can ingest a Direct-v1 bundle root.
- Required contracts load successfully.
- Mapping resolution follows `assembler.transform-semantics.v1.md`.
- Render report validates against `assembler.render-report.schema.v1.json`.

## Known assumptions
- This is a bootstrap contract set; expect refinement before GA.
- Contract ownership boundaries must be finalized between Contracts and Assembler repos.


## Delta-only / merged-items check
- `merged-items-audit.v1.json` records the already-merged authoritative repo files reused by Assembler handoff artifacts.
- This export intentionally adds only Assembler-specific contracts absent from current standards snapshot.
