# Assembler scripts

Runtime direction is **PowerShell 7**.

## Implemented scripts

- `Invoke-AssemblerPipeline.ps1` - bootstraps Direct-v1 input ingest and minimum contract checks.
- `Invoke-AssemblerSdtRender.ps1` - reads a dataset-to-SDT mapping and skeleton template, validates mapping contract shape, resolves dataset selectors, and renders SDT placeholders.
- `Invoke-AssemblerBundleRender.ps1` - bundle-aware orchestration skeleton that discovers tech in bundle and runs renderer once per TemplateCatalog entry.
- `New-AssemblerSkeleton.ps1` - copies a built-in skeleton pack (mapping + template) into a local ingest folder.
- `Sync-AssemblerContractsToRepo.ps1` - syncs contracts into deterministic repo-local ingest path (`.deps/contracts`).
- `internal/AssemblerSchemaValidation.psm1` - shared helper for JSON schema validation against contracts under `standards/`.

## Contract path resolution

`Invoke-AssemblerSdtRender.ps1` and `Invoke-AssemblerBundleRender.ps1` resolve contracts in this order:
1. explicit `-ContractsRoot`
2. `./.deps/contracts`

The SDT render script loads `standards/mapping.dataset-to-sdt.schema.v1.json` and `standards/assembler/assembler.render-report.schema.v1.json` from the resolved root and performs schema validation for mapping input and single-render output. It also loads tech-specific projection contracts from `tech/<techId>/assembler.projections.v1.json` when present so table shaping remains contract-owned. Bundle orchestration separately validates `standards/assembler/assembler.bundle-render-report.schema.v1.json` for its aggregate report.

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
- optional: `tech/` (sync continues if absent)

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
