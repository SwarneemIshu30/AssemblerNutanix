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

## Current PS7 readiness status

The repository now includes end-to-end PowerShell 7 scaffolding for SDT rendering:
- pipeline bootstrap validation (`scripts/Invoke-AssemblerPipeline.ps1`)
- contract sync to deterministic local path (`scripts/Sync-AssemblerContractsToRepo.ps1`)
- SDT render invoke script with mapping schema checks (`scripts/Invoke-AssemblerSdtRender.ps1`)
- skeleton ingest bootstrap (`scripts/New-AssemblerSkeleton.ps1`)
- interactive launcher (`gui/Start-AssemblerGui.ps1`)
- built-in dummy Lenovo DE skeleton (`templates/skeletons/Lenovo.DE`)

Current contract source/ingest strategy:
- source of truth during buildout: `export/repo-ready/contracts`
- determinable local ingest path: `.deps/contracts` (via sync script)
- sync supports local export copy now and published pack sync for future default



### Bundle-aware orchestration (next-step skeleton now included)

Assembler now includes a bundle orchestration skeleton (`scripts/Invoke-AssemblerBundleRender.ps1`)
that consumes a TemplateCatalog contract and invokes SDT render once per selected mapping/template
entry. This allows multi-tech bundles to be rendered by intent (`-TechId`) instead of assuming
a single template mapping file.

TemplateCatalog schema:
- `export/repo-ready/contracts/standards/assembler/assembler.template-catalog.schema.v1.json`

