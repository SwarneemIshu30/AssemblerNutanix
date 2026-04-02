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
  - Per-tech quality dashboard now includes `generationStatus` (`ok`, `partial`, `empty`, `skipped`) and skip-reason counters (`missingDataset`, `missingTag`, `missingDatasetTemplate`, `unsupportedShape`) so root cause is explicit in final JSON output.
  - Enforces post-generation invariant checks per tech (`contract.total > 0` while `runtime.total == 0`) with a high-severity warning in non-strict mode and fail-closed behavior in strict mode.
- `Test-AssemblerMappingShapeMode.ps1` - CI validation helper that enforces a selected rollout mode against both mapping contract and runtime mapping files.
- `internal/AssemblerSchemaValidation.psm1` - shared helper for JSON schema validation against contracts under `standards/`.

## Entrypoints and flow

### Entrypoint matrix

| Category | Entrypoints | Notes |
| --- | --- | --- |
| Public/operator entrypoints | `Sync-AssemblerContractsToRepo.ps1`; `Invoke-AssemblerPipeline.ps1`; `Invoke-AssemblerBundleRender.ps1`; GUI launchers | Preferred operator-facing path for sync/orchestration. |
| Conditional/manual entrypoint | `Invoke-AssemblerSdtRender.ps1` | Use only with fully resolved mapping paths; no `__TARGET__` / `__SYSTEM__` placeholders. |
| Internal modules/helpers | `internal/AssemblerSchemaValidation.psm1`; mapping-shape helpers | Shared internals consumed by entrypoint scripts and validation flows. |

### Operator warning: unresolved mapping placeholders

If a mapping includes runtime placeholders such as `__TARGET__` or `__SYSTEM__`, do **not** run `Invoke-AssemblerSdtRender.ps1` directly on that unresolved mapping file.

Run `Invoke-AssemblerBundleRender.ps1` (or a resolved-mapping helper) so placeholders are expanded first.

`Invoke-AssemblerSdtRender.ps1` now includes a preflight guard that fails fast with `ASB-ASM-SDT-PREFLIGHT-UNRESOLVED-MAPPING-PATH` when unresolved `__TARGET__` / `__SYSTEM__` placeholders are detected in mapping dataset paths. This prevents large cascades of downstream `ASB-ASM-SDT-DATASET-MISSING` and `ASB-ASM-SDT-UNRESOLVED-TAG` diagnostics for this operator mistake.

Common failure symptoms when the wrong entrypoint is used:
- `ASB-ASM-SDT-DATASET-MISSING` for `datasets/.../__TARGET__/...`
- many `ASB-ASM-SDT-UNRESOLVED-TAG` errors

Wrong vs right:

```powershell
# Wrong: direct SDT render with unresolved __TARGET__/__SYSTEM__ placeholders
pwsh ./scripts/Invoke-AssemblerSdtRender.ps1 \
  -BundleRoot ./bundle/<id> \
  -MappingPath ./templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json \
  -TemplatePath ./templates/skeletons/Lenovo.DE/DE-SDT-Collector.docx \
  -OutputPath ./out/direct.docx

# Right: bundle orchestration resolves mapping paths before SDT render
pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 \
  -BundleRoot ./bundle/<id> \
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json \
  -OutputRoot ./out/bundle-render
```

### Flow

`Sync -> (optional Pipeline) -> BundleRender -> SdtRender (per resolved variant)`

### Public entrypoint map

- **Pipeline path:** `Invoke-AssemblerPipeline.ps1` -> `Invoke-AssemblerBundleRender.ps1` -> `Invoke-AssemblerSdtRender.ps1`
- **GUI path:** `gui/Start-AssemblerGui.ps1` or `gui/Start-AssemblerGui.Wpf.ps1` -> `Invoke-AssemblerBundleRender.ps1`

Both paths converge on **bundle render** before SDT render. This is required whenever mappings include runtime placeholders such as `__TARGET__` and `__SYSTEM__`.

## Contract path resolution

`Invoke-AssemblerSdtRender.ps1` and `Invoke-AssemblerBundleRender.ps1` resolve contracts in this order:
1. explicit `-ContractsRoot`
2. `./.deps/contracts`

The SDT render script loads `standards/mapping.dataset-to-sdt.schema.v1.json` and `standards/assembler/assembler.render-report.schema.v1.json` from the resolved root and performs schema validation for mapping input and single-render output. It also requires a tech-specific projection contract at `tech/<techId>/assembler.projections.v1.json`; if that file is missing for the selected tech, render fails with an error explaining that contracts sync is incomplete so operators know to sync `tech/<techId>/assembler.projections.v1.json` into `.deps/contracts` outside this repo. Bundle orchestration separately validates `standards/assembler/assembler.bundle-render-report.schema.v1.json` for its aggregate report.

Repo ownership note: `.deps/contracts` is the runtime snapshot used for immediate testing. Owned contract artifacts changed there should be mirrored into `exports/LNV.AsBuiltDoc.Contracts/...` for offline handoff to the contracts repo in the same change. Do not claim a complete export mirror unless those files actually exist under `exports/...`.

## Projection/view ownership direction

Assembler documentation and runtime behavior should align to these rules:
- `mapping.dataset-to-sdt` entries may declare render hints such as `projectionRef`, `renderAs`, `view`, `structuredValuePolicy`, and `missingProjectionPolicy`.
- `tech/<techId>/assembler.projections.v1.json` is where projection/view behavior belongs, including aliases, ordering, empty-state behavior, and table shaping.
- `tech/<techId>/dataset/*.assembler.meta.json` carries dataset presentation intent so collectors can inform assembler how normalized data should be treated without pushing more tech logic into invoke scripts.
- `tech/<techId>/dataset/*.assembler.meta.json` also owns dataset path templates for skeleton mapping generation via `datasetPath.template` (for example `datasets/__TECH_ID__/__TARGET__/__SYSTEM__/__DATASET__.json`). Supported placeholders are `__TECH_ID__` and `__DATASET__` (expanded during sync) plus `__TARGET__`, `__SYSTEM__`, and similar runtime placeholders (passed through for bundle-time expansion). Missing templates now fail mapping generation.
- document-facing table outputs should be driven by explicit view/projection metadata; raw JSON output should be limited to declared evidence/debug scenarios.

Current runtime subset versus target semantics:
- Direct-v1 contracts already use `renderAs`, `projectionRef`, `view`, projection contracts, and dataset presentation sidecars.
- Sync already consumes `renderAs` and `syncPolicy` when generating runtime-facing mapping copies.
- The renderer still executes with legacy-compatible precedence: projection `renderMode`, then mapping `renderMode`, then mapping `renderAs`.
- Current projection execution supports aliases, `filter`, `sortBy`, `columns`, supported column formats, and partial `emptyBehavior` handling.
- `renderAs`-first precedence, `renderAs`/`renderMode` mismatch validation, `list`, `rowOrder`, `identityKeys`, `formatProfiles`, and full `emptyBehavior` remain target semantics until the renderer catches up.

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
- `-EntryId` (one or more catalog entry IDs; debug/advanced filter)
- `-OutputType docx|text` (one or both output variants; debug/advanced filter)
- `-DocTitle`, `-DocCustomer`, `-DocCustomerAbbr`, `-DocLocation`, `-DocSubsidiary`, `-DocEnvironment`, `-DocDocumentReference`, `-DocClassification` (DOCX document-property/content-control inputs)
- `-DocxMatchMode content-control-tag|literal-token|both` (default `both`; controls whether DOCX render processes literal dataset tokens, document controls/DOCPROPERTY fields, or both)
- `-AnnotateResolvedTags` (when rendering text output, prefix resolved `<<SDT:...>>` replacements with debug trace markers)
- `-UnresolvedTokenPolicy retain|remove` (default `retain`; `remove` strips unresolved `<<SDT:...>>` tokens from rendered output)

Behavior:
- reads `objectIndex.json` to detect tech present in bundle
- validates catalog against `assembler.template-catalog` schema
- validates aggregate bundle report contract against dedicated `assembler.bundle-render-report` schema
- filters enabled catalog entries by detected/requested `techId`
- invokes `Invoke-AssemblerSdtRender.ps1` once per selected entry
- when DOCX output is selected, forwards document-property inputs to DOCX content-control/DOCPROPERTY population and literal dataset token replacement according to `DocxMatchMode`
- when `DocTitle` and `DocCustomer` are supplied for DOCX output, prefers the generated filename `Title - Customer.docx`
- writes aggregate report to `assembler-bundle-render-report.json`
- when a run fails due to nested renderer issues, wrapper diagnostics now preserve a distinct `issue codes: CODE=n` breakdown (for example both `ASB-ASM-SDT-DOCX-NO-POPULATION` and `ASB-ASM-DOCPROP-DOCX-NO-POPULATION` when both appear) so downstream parsers can classify root causes without collapsing them by severity alone

### Output selection controls

Bundle render output can be narrowed in three layers:

1. **Catalog defaults (`enabled`)**
   - `entries[].enabled` in the catalog determines baseline inclusion/exclusion.
2. **CLI filters (`Invoke-AssemblerBundleRender.ps1`)**
   - `-TechId` filters by technology.
   - `-EntryId` filters by specific catalog IDs.
   - `-OutputType docx|text` filters by output variant.
3. **GUI debug/advanced toggles**
   - GUI launchers pass `EntryId` and DOCX/TXT toggles through to bundle render filters.

Current default behavior is **DOCX-only**. TXT output remains available through `-OutputType text` or GUI debug/advanced toggles.

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
- `-StrictEmptyGeneration` fail sync when a tech resolves to `generationStatus=empty`; if omitted, sync emits high-severity warnings and continues

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
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json \
  -OutputRoot ./out/bundle-render
```

```powershell
# Run orchestration only for Lenovo.DE
pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 \
  -BundleRoot ./bundle/417f4663-0922-423b-92a9-34d4e33ecd0e \
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json \
  -OutputRoot ./out/bundle-render \
  -TechId Lenovo.DE
```

```powershell
# Debug text output by annotating resolved SDT tags
pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 \
  -BundleRoot ./bundle/417f4663-0922-423b-92a9-34d4e33ecd0e \
  -CatalogPath ./templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json \
  -OutputRoot ./out/bundle-render \
  -OutputType text \
  -AnnotateResolvedTags
```
