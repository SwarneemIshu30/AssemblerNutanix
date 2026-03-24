# Assembler scripts

Runtime direction is **PowerShell 7**.

## Implemented scripts

- `Invoke-AssemblerPipeline.ps1` - bootstraps Direct-v1 input ingest and minimum contract checks.
- `Invoke-AssemblerSdtRender.ps1` - reads a dataset-to-SDT mapping and skeleton template, validates mapping contract shape, resolves dataset selectors, and renders SDT placeholders.
- `Invoke-AssemblerBundleRender.ps1` - bundle-aware orchestration skeleton that discovers tech in bundle and runs renderer once per TemplateCatalog entry.
- `New-AssemblerSkeleton.ps1` - copies a built-in skeleton pack (mapping + template) into a local ingest folder.
- `Sync-AssemblerContractsToRepo.ps1` - syncs contracts into deterministic repo-local ingest path (`.deps/contracts`) and regenerates `templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json` from `tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`.
- `internal/AssemblerSchemaValidation.psm1` - shared helper for JSON schema validation against contracts under `standards/`.

## Contract path resolution

`Invoke-AssemblerSdtRender.ps1` and `Invoke-AssemblerBundleRender.ps1` resolve contracts in this order:
1. explicit `-ContractsRoot`
2. `./.deps/contracts`

The SDT render script loads `standards/mapping.dataset-to-sdt.schema.v1.json` and `standards/assembler/assembler.render-report.schema.v1.json` from the resolved root and performs schema validation for mapping input and single-render output. It also requires a tech-specific projection contract at `tech/<techId>/assembler.projections.v1.json`; if that file is missing for the selected tech, render fails with an error explaining that contracts sync is incomplete so operators know to sync `tech/<techId>/assembler.projections.v1.json` into `.deps/contracts` outside this repo. Bundle orchestration separately validates `standards/assembler/assembler.bundle-render-report.schema.v1.json` for its aggregate report.

Repo ownership note: tracked contract handoff artifacts live under `exports/LNV.AsBuiltDoc.Contracts/...`, including `exports/LNV.AsBuiltDoc.Contracts/tech/Lenovo.DE/assembler.projections.v1.json` and dataset presentation sidecars under `exports/LNV.AsBuiltDoc.Contracts/tech/Lenovo.DE/dataset/*.assembler.meta.json`. The `.deps/contracts` tree is a repo-local synced runtime dependency populated by `Sync-AssemblerContractsToRepo.ps1`; do not make repo-managed contract edits there unless you also mirror the owned contract changes into `exports/...` for offline handoff.

## TemplateCatalog contract

Schema file:
- `.deps/contracts/standards/assembler/assembler.template-catalog.schema.v1.json`

Purpose:
- external inventory of which template + mapping pair to run per `techId`
- deterministic selection and output naming ahead of render time

Current required entry fields:
- `id`
- `techId`
- `mappingPath`
- `templatePath`
- `outputFileName`

## `Invoke-AssemblerBundleRender.ps1`

Required parameters:
- `-BundleRoot`
- `-CatalogPath`
- `-OutputRoot`

Optional:
- `-ContractsRoot`
- `-TechId` (one or more explicit technologies to render)

Behavior:
- reads `objectIndex.json` to detect tech present in bundle
- validates catalog against `assembler.template-catalog` schema
- validates aggregate bundle report contract against dedicated `assembler.bundle-render-report` schema
- filters enabled catalog entries by detected/requested `techId`
- invokes `Invoke-AssemblerSdtRender.ps1` once per selected entry
- writes aggregate report to `assembler-bundle-render-report.json`

## `Sync-AssemblerContractsToRepo.ps1` modes

Supported sync modes:
- **Published pack sync (default):** resolve the latest contracts release from GitHub and download the matching zip asset to `.deps/contracts`
  - by version: `-ContractsVersion`
  - or by URL: `-ContractsPackUrl`
- **Local copy (explicit source path):** copy a local contracts tree into `.deps/contracts`
  - `-ExportContractsPath <path>`

Shared options:
- `-DepsContractsPath` destination path (default `./.deps/contracts`)
- `-Clean` remove destination before sync

Each run writes or updates `contracts.snapshot.json` in the destination.

Expected contracts layout at destination:
- required: `standards/`
- required at render time for each selected tech: `tech/<techId>/assembler.projections.v1.json`

If `tech/<techId>/assembler.projections.v1.json` is missing from `.deps/contracts`, `Invoke-AssemblerSdtRender.ps1` now fails fast and tells the operator that contracts sync is incomplete.

## Examples

```powershell
# Default: latest published pack -> .deps
pwsh ./scripts/Sync-AssemblerContractsToRepo.ps1

# Copy from an explicit local contracts tree -> .deps
pwsh ./scripts/Sync-AssemblerContractsToRepo.ps1 -ExportContractsPath ./contracts-source -Clean
```

```powershell
# Run orchestration for all detected tech
pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 \
  -BundleRoot ./bundle/417f4663-0922-423b-92a9-34d4e33ecd0e \
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json \
  -OutputRoot ./out/bundle-render
```

```powershell
# Run orchestration only for Lenovo.DE
pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 \
  -BundleRoot ./bundle/417f4663-0922-423b-92a9-34d4e33ecd0e \
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json \
  -OutputRoot ./out/bundle-render \
  -TechId Lenovo.DE
```
