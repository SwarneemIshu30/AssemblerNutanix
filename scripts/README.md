# Assembler scripts

Runtime direction is **PowerShell 7**.

## Implemented scripts

- `Invoke-AssemblerPipeline.ps1` - bootstraps Direct-v1 input ingest and minimum contract checks; by default it validates-only and emits explicit next-step render guidance. Optional render handoff parameters can invoke bundle render directly.
- `Invoke-AssemblerSdtRender.ps1` - reads a dataset-to-SDT mapping and skeleton template, validates mapping contract shape, resolves dataset selectors, and renders SDT placeholders.
- `Invoke-AssemblerBundleRender.ps1` - bundle-aware orchestration skeleton that discovers tech in bundle and runs renderer once per TemplateCatalog entry.
- `New-AssemblerSkeleton.ps1` - copies a built-in skeleton pack (mapping + template) into a local ingest folder.
- `Sync-AssemblerContractsToRepo.ps1` - syncs contracts into deterministic repo-local ingest path (`.deps/contracts`) and regenerates `templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json` from `tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`.
  - Collector mapping generation now honors contract-owned `syncPolicy.collectorSkeletonMapping` (allowed `renderAs`, selector defaults, and unsupported-shape behavior) instead of script-side hardcoded render assumptions.
  - Supports explicit rollout control via `-OutputShapeMode legacy|dual|target` and logs migration dashboard counts (`sdtTag`-only, dual, target-only) for both contract and runtime mapping shapes.
- `Test-AssemblerMappingShapeMode.ps1` - CI validation helper that enforces a selected rollout mode against both mapping contract and runtime mapping files.
- `internal/AssemblerSchemaValidation.psm1` - shared helper for JSON schema validation against contracts under `standards/`.

## Contract path resolution

`Invoke-AssemblerSdtRender.ps1` and `Invoke-AssemblerBundleRender.ps1` resolve contracts in this order:
1. explicit `-ContractsRoot`
2. `./.deps/contracts`

The SDT render script loads `standards/mapping.dataset-to-sdt.schema.v1.json` and `standards/assembler/assembler.render-report.schema.v1.json` from the resolved root and performs schema validation for mapping input and single-render output. It also requires a tech-specific projection contract at `tech/<techId>/assembler.projections.v1.json`; if that file is missing for the selected tech, render fails with an error explaining that contracts sync is incomplete so operators know to sync `tech/<techId>/assembler.projections.v1.json` into `.deps/contracts` outside this repo. Bundle orchestration separately validates `standards/assembler/assembler.bundle-render-report.schema.v1.json` for its aggregate report.

Repo ownership note: tracked contract handoff artifacts live under `exports/LNV.AsBuiltDoc.Contracts/...`, including `exports/LNV.AsBuiltDoc.Contracts/tech/Lenovo.DE/assembler.projections.v1.json` and dataset presentation sidecars under `exports/LNV.AsBuiltDoc.Contracts/tech/Lenovo.DE/dataset/*.assembler.meta.json`. The `.deps/contracts` tree is a repo-local synced runtime dependency populated by `Sync-AssemblerContractsToRepo.ps1`; do not make repo-managed contract edits there unless you also mirror the owned contract changes into `exports/...` for offline handoff.

## Projection/view ownership direction

Assembler documentation and runtime behavior should align to these rules:
- `mapping.dataset-to-sdt` entries may declare render hints such as `projectionRef`, `renderAs`, `view`, `structuredValuePolicy`, and `missingProjectionPolicy`.
- `tech/<techId>/assembler.projections.v1.json` is where projection/view behavior belongs, including aliases, ordering, empty-state behavior, and table shaping.
- `tech/<techId>/dataset/*.assembler.meta.json` carries dataset presentation intent so collectors can inform assembler how normalized data should be treated without pushing more tech logic into invoke scripts.
- `tech/<techId>/dataset/*.assembler.meta.json` also owns dataset path templates for skeleton mapping generation via `datasetPath.template` (for example `datasets/__TECH_ID__/__TARGET__/__SYSTEM__/__DATASET__.json`). Supported placeholders are `__TECH_ID__` and `__DATASET__` (expanded during sync) plus `__TARGET__`, `__SYSTEM__`, and similar runtime placeholders (passed through for bundle-time expansion). Missing templates now fail mapping generation.
- document-facing table outputs should be driven by explicit view/projection metadata; raw JSON output should be limited to declared evidence/debug scenarios.

For Lenovo.DE, the authoritative contract mapping source is `.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`; `templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json` is the runtime-facing/generated copy that must stay aligned with it.

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

## `Invoke-AssemblerPipeline.ps1`

Required parameters:
- `-BundleRoot`
- `-ContractsRoot`

Optional:
- `-OutputPath`
- `-RenderCatalogPath` + `-RenderOutputRoot` (must be supplied together; enables render handoff to `Invoke-AssemblerBundleRender.ps1`)
- `-RenderTechId` (optional tech filter forwarded during render handoff)
- `-MappingShapeMode` (`legacy`, `dual`, `target`) to enforce rollout mode for mapping shape validation
- `-ContractMappingPath` optional contract mapping override for shape validation (requires `-MappingShapeMode`)
- `-RuntimeMappingPath` optional runtime mapping override for shape validation (requires `-MappingShapeMode`)

Behavior:
- always performs bootstrap load + schema validation for `manifest.json`, `objectIndex.json`, and `config/solution.plan.json`
- when `-MappingShapeMode` is supplied, runs `Test-AssemblerMappingShapeMode.ps1` to enforce the selected mode in both contract and runtime mapping files
- emits migration dashboard diagnostics with counts of `sdtTag`-only, dual, and target-only entries for contract/runtime mappings
- when render handoff options are **not** supplied, marks render as skipped and emits an explicit diagnostic with the next command (`Invoke-AssemblerBundleRender.ps1`)
- when render handoff options are supplied, invokes `Invoke-AssemblerBundleRender.ps1` and includes handoff status/details in pipeline output

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
- `-OutputShapeMode legacy|dual|target` to force runtime mapping output shape and enforce the same mode against contract/runtime mapping files during sync

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

# Force target-only rollout mode and validate both contract/runtime mapping shape
pwsh ./scripts/Sync-AssemblerContractsToRepo.ps1 -ExportContractsPath ./contracts-source -OutputShapeMode target -Clean
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
