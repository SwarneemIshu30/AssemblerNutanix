# Assembler (staging workspace in Core)

This `/Assembler` folder is a **temporary staging workspace** hosted in `LNV.AsBuiltDoc.Core` for accessibility during initial build-out.

> Destination: this folder is intended to be moved into the standalone `LNV.AsBuiltDoc.Assembler` repository.

## Scope

Assembler is responsible for:
- Reading a Direct-v1 bundle output
- Validating required contracts/mappings
- Building a deterministic render plan from datasets + mapping
- Rendering SDT-populated documents and a machine-readable render report

Assembler is **not** responsible for:
- Running collectors
- Defining collector plan semantics
- Producing bundle capture artifacts

## Portability rules (important)

- Do not hardcode references to Core repo layout.
- Resolve runtime paths from:
  - `ASSEMBLER_ROOT` (module root)
  - explicit input bundle path and contract path arguments
- Treat `/export/repo-ready/*` as the authoritative handoff payload for migration.

## Initial structure

- `src/` runtime entrypoints and pipeline stages
- `scripts/` local orchestrator scripts
- `gui/` GUI starter shell and UX notes
- `tests/` deterministic tests for transform/lifecycle behavior
- `docs/` architecture/runbook content

## Migration to standalone Assembler repo

1. Copy `/Assembler/*` into new repository root.
2. Copy `/export/repo-ready/contracts/*` into target contracts ownership location.
3. Copy `/export/repo-ready/handoff/*` into the new repo (`docs/handoff/`).
4. Validate the knowledge pack against its schema.
5. Execute acceptance checklist in handoff docs.
