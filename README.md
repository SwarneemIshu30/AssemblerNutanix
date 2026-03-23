# LNV.AsBuiltDoc.Assembler

`LNV.AsBuiltDoc.Assembler` is the standalone assembler runtime for turning Direct-v1 bundle data into deterministic SDT-backed document output.

## Scope

Assembler is responsible for:
- Reading a Direct-v1 bundle output
- Validating required contracts and mappings
- Building a deterministic render plan from datasets and mappings
- Rendering SDT-populated documents and a machine-readable render report

Assembler is not responsible for:
- Running collectors
- Defining collector plan semantics
- Producing bundle capture artifacts

## Repository layout

- `src/` runtime entrypoints and pipeline stages
- `scripts/` local orchestration and contract utilities
- `gui/` launcher scripts and UX notes
- `tests/` deterministic tests for transform and lifecycle behavior
- `docs/` architecture, runbook, and troubleshooting content
- `.deps/contracts/` repo-local contract snapshot used by the assembler

## Contracts

The assembler resolves contracts from:
1. an explicit `-ContractsRoot` argument
2. `./.deps/contracts`

The historical export-based handoff layout is no longer used in this repository.

## Current runtime coverage

The repository includes PowerShell 7 scaffolding for SDT rendering:
- pipeline bootstrap validation (`scripts/Invoke-AssemblerPipeline.ps1`)
- contract sync to deterministic local path (`scripts/Sync-AssemblerContractsToRepo.ps1`)
- SDT render invoke script with mapping schema checks (`scripts/Invoke-AssemblerSdtRender.ps1`)
- bundle-aware orchestration (`scripts/Invoke-AssemblerBundleRender.ps1`)
- skeleton ingest bootstrap (`scripts/New-AssemblerSkeleton.ps1`)
- interactive launchers (`gui/Start-AssemblerGui.ps1`, `gui/Start-AssemblerGui.Wpf.ps1`)
- built-in Lenovo.DE skeletons (`templates/skeletons/Lenovo.DE`)

## Template catalog contract

Template catalog validation uses:
- `.deps/contracts/standards/assembler/assembler.template-catalog.schema.v1.json`
