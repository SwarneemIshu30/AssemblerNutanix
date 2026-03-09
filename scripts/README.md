# Assembler scripts

Runtime direction is **PowerShell 7**.

## Implemented scripts

- `Invoke-AssemblerPipeline.ps1` - bootstraps Direct-v1 input ingest and minimum contract checks.
- `Invoke-AssemblerSdtRender.ps1` - reads a dataset-to-SDT mapping and skeleton template, validates mapping contract shape, resolves dataset selectors, and renders SDT placeholders.
- `Invoke-AssemblerBundleRender.ps1` - bundle-aware orchestration skeleton that discovers tech in bundle and runs renderer once per TemplateCatalog entry.
- `New-AssemblerSkeleton.ps1` - copies a built-in skeleton pack (mapping + template) into a local ingest folder.
- `Sync-AssemblerContractsToRepo.ps1` - syncs contracts into deterministic repo-local ingest path (`.deps/contracts`).

## Contract path resolution (SDT render)

`Invoke-AssemblerSdtRender.ps1` resolves contracts in this order:
1. explicit `-ContractsRoot`
2. `./.deps/contracts`
3. `./export/repo-ready/contracts`

The script loads `standards/mapping.dataset-to-sdt.schema.v1.json` from the resolved root and performs minimum mapping contract checks before rendering.

## TemplateCatalog contract

Schema file:
- `export/repo-ready/contracts/standards/assembler/assembler.template-catalog.schema.v1.json`

Purpose:
- external inventory of which template + mapping pair to run per `techId`
- deterministic selection and output naming ahead of render time

Current required entry fields:
- `id`
- `techId`
- `mappingPath`
- `templatePath`
- `outputFileName`

## `Invoke-AssemblerBundleRender.ps1` (skeleton)

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
- filters enabled catalog entries by detected/requested `techId`
- invokes `Invoke-AssemblerSdtRender.ps1` once per selected entry
- writes aggregate report to `assembler-bundle-render-report.json`

## `Sync-AssemblerContractsToRepo.ps1` modes

Two supported sync modes:

- **Published pack sync (default, no arguments):** resolve latest contracts release from GitHub and download matching zip asset to `.deps/contracts`
  - by version: `-ContractsVersion`
  - or by URL: `-ContractsPackUrl`
- **Local export copy (when options are provided without pack args):** `export/repo-ready/contracts` -> `.deps/contracts`
  - optional override: `-ExportContractsPath`

Shared options:
- `-DepsContractsPath` destination path (default `./.deps/contracts`)
- `-Clean` remove destination before sync

Each run writes/updates `contracts.snapshot.json` in destination.

Expected contracts layout at destination:
- required: `standards/`
- optional: `tech/` (sync continues if absent)

## Examples

```powershell
# Default: latest published pack -> .deps
pwsh ./scripts/Sync-AssemblerContractsToRepo.ps1

# Local export -> .deps (explicit local mode trigger)
pwsh ./scripts/Sync-AssemblerContractsToRepo.ps1 -Clean
```

```powershell
# Run orchestration for all detected tech
pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 \
  -BundleRoot ./sample/66694360-25ba-40de-8fbd-07ebce431c53 \
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json \
  -OutputRoot ./out/bundle-render
```

```powershell
# Run orchestration only for Lenovo.DE
pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 \
  -BundleRoot ./sample/66694360-25ba-40de-8fbd-07ebce431c53 \
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json \
  -OutputRoot ./out/bundle-render \
  -TechId Lenovo.DE
```
