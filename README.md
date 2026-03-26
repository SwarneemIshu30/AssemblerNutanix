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

`.deps/contracts` is a synced runtime dependency used by the assembler at render time. It is **not** the long-term source of truth for contract authoring.

When assembler work requires editing or adding contract files under `.deps/contracts` in this repo, mirror the same owned artifacts under:
- `exports/LNV.AsBuiltDoc.Contracts/...`

That export tree exists so contract changes can be handed off offline to the contracts repo that owns them.

## Contract-driven projection model

The current assembler direction is to keep rendering behavior declarative and contract-owned:

- dataset-to-SDT mappings may declare render intent such as `projectionRef`, `renderAs`, and `view`
- tech projection contracts declare aliases, filters, ordering, columns, and output behavior
- dataset presentation sidecars under `tech/<techId>/dataset/*.assembler.meta.json` describe document intent such as `summary`, `table`, `relationshipTable`, or `evidence`
- document-facing SDTs should resolve through explicit projection/view metadata rather than ad hoc technology-specific renderer logic
- raw JSON output is reserved for evidence/debug use cases, not as the preferred fallback for document-facing tables

For Lenovo.DE specifically, the authoritative mapping and projection intent now lives in the contracts snapshot under:
- `.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`
- `.deps/contracts/tech/Lenovo.DE/assembler.projections.v1.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/*.assembler.meta.json`

The runtime skeleton mapping under `templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json` should stay aligned with that contract data.

## Current runtime coverage

The repository includes PowerShell 7 scaffolding for SDT rendering:
- pipeline bootstrap validation (`scripts/Invoke-AssemblerPipeline.ps1`)
- contract sync to deterministic local path (`scripts/Sync-AssemblerContractsToRepo.ps1`) with per-tech generation dashboard/status and strict empty-generation quality gates
- SDT render invoke script with mapping schema checks (`scripts/Invoke-AssemblerSdtRender.ps1`)
- bundle-aware orchestration (`scripts/Invoke-AssemblerBundleRender.ps1`)
- skeleton ingest bootstrap (`scripts/New-AssemblerSkeleton.ps1`)
- interactive launchers (`gui/Start-AssemblerGui.ps1`, `gui/Start-AssemblerGui.Wpf.ps1`)
- built-in Lenovo.DE skeletons (`templates/skeletons/Lenovo.DE`)

## Template catalog contract

Template catalog validation uses:
- `.deps/contracts/standards/assembler/assembler.template-catalog.schema.v1.json`
