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

Packaged assembler runtime distributions bundle the checked-in `.deps/contracts` snapshot by default so the extracted package is runnable without a first-run sync. `scripts/Sync-AssemblerContractsToRepo.ps1` remains the supported way to refresh or replace that bundled snapshot after extraction, and `-ContractsRoot` remains the explicit runtime override when operators need to point at a different contracts tree.

When assembler work requires editing or adding contract files under `.deps/contracts` in this repo, mirror the same owned artifacts under:
- `exports/LNV.AsBuiltDoc.Contracts/...`

That export tree exists so contract changes can be handed off offline to the contracts repo that owns them. For immediate testing, owned contract changes may be applied in `.deps/contracts`, but the same changed artifacts must also be mirrored into `exports/...` in the same change. Do not assume `exports/...` is a complete mirror unless the files are actually present there.

## Contract-driven projection model

The current assembler direction is to keep rendering behavior declarative and contract-owned:

- dataset-to-SDT mappings may declare render intent such as `projectionRef`, `renderAs`, and `view`
- tech projection contracts declare aliases, filters, ordering, columns, and output behavior
- dataset presentation sidecars under `tech/<techId>/dataset/*.assembler.meta.json` describe document intent such as `summary`, `table`, `relationshipTable`, or `evidence`
- document-facing SDTs should resolve through explicit projection/view metadata rather than ad hoc technology-specific renderer logic
- raw JSON output is reserved for evidence/debug use cases, not as the preferred fallback for document-facing tables
- current runtime execution still uses legacy-compatible mode precedence: projection `renderMode`, then mapping `renderMode`, then mapping `renderAs`
- current projection execution supports aliases, `filter`, `sortBy`, `columns`, supported column formats, and partial `emptyBehavior` handling; `renderAs`-first precedence, `list`, `rowOrder`, `identityKeys`, `formatProfiles`, and full `emptyBehavior` remain target semantics rather than fully implemented runtime behavior

For Lenovo.DE specifically, the authoritative mapping and projection intent now lives in the contracts snapshot under:
- `.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`
- `.deps/contracts/tech/Lenovo.DE/assembler.projections.v1.json`
- `.deps/contracts/tech/Lenovo.DE/dataset/*.assembler.meta.json`

The runtime skeleton mapping under `templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json` should stay aligned with that contract data.
See `docs/contract-driven-projections.md` for the repo-level explanation of current runtime support versus roadmap semantics.

## Public entrypoints and chaining

Entry-point map:
- **Pipeline -> BundleRender -> SdtRender**
  - `scripts/Invoke-AssemblerPipeline.ps1` -> `scripts/Invoke-AssemblerBundleRender.ps1` -> `scripts/Invoke-AssemblerSdtRender.ps1`
- **GUI -> BundleRender**
  - `gui/Start-AssemblerGui.ps1` / `gui/Start-AssemblerGui.Wpf.ps1` -> `scripts/Invoke-AssemblerBundleRender.ps1`

Bundle render is the required hop whenever mapping files contain runtime placeholders such as `__TARGET__` and `__SYSTEM__`.

## Output-selection controls

Output selection is controlled in layers:
1. **Template catalog `enabled`** flag controls baseline inclusion.
2. **CLI filter parameters** on bundle render (`-TechId`, `-EntryId`, `-OutputType docx|text`) provide run-time narrowing.
3. **GUI debug/advanced toggles** expose equivalent filtering (Entry IDs and DOCX/TXT toggles).

Current default behavior is **DOCX-only**. TXT output is still available through explicit CLI filters or GUI debug/advanced toggles.

## Current DOCX behavior

- GUI and bundle-render flows currently expose document-property inputs for `Title`, `Customer`, `CustomerAbbr`, `Location`, `Subsidiary`, `Environment`, `DocumentReference`, `LNV.Version`, `LNV.ConfigSnapDate`, `LNV.ReferenceID`, and classification.
- In the WPF launcher, those three additional document-property inputs are presented as `Document Version`, `Configuration Snapshot Date`, and `Reference ID`.
- `Document Version` currently defaults to `v1.0.0`, and `Configuration Snapshot Date` is refreshed from the loaded bundle capture date when one can be resolved from bundle metadata.
- DOCX matching currently supports `literal-token`, `content-control-tag`, and `both`.
- `literal-token` populates dataset-driven `<<SDT:...>>` placeholders, while `content-control-tag` populates document controls and `DOCPROPERTY`-backed fields. `both` runs both paths.
- When `DocTitle` and `DocCustomer` are supplied, generated DOCX filenames currently resolve to `Title - Customer.docx`.

## WPF Mapping Studio status

The Windows WPF launcher now includes a dedicated `Mapping Studio` tab for contract-driven mapping inspection and editing. This work is still in progress.

Current implemented direction:
- WPF only
- DOCX template collections only
- nested `Overview`, `Datasets`, `Targets`, `Connector`, and `Changes` tabs
- connector-first inspection flow for viewing current dataset-to-target connections before editing
- bundle-backed example preview for current mappings and draft changes
- save path that updates `.deps/contracts/...`, mirrors the owned artifact under `exports/LNV.AsBuiltDoc.Contracts/...`, and regenerates the runtime skeleton mapping JSON

Current work-in-progress boundaries:
- mapping authoring is still evolving and should be treated as WIP
- scalar and table authoring are the current focus; unsupported mapping shapes remain inspect-only
- staged targets are valid contract targets, but they are not automatic DOCX template placements

See `docs/mapping-studio-wip.md` for the current GUI status, implemented scope, and known limitations.

## Current runtime coverage

The repository includes PowerShell 7 scaffolding for SDT rendering:
- pipeline bootstrap validation (`scripts/Invoke-AssemblerPipeline.ps1`)
- contract sync to deterministic local path (`scripts/Sync-AssemblerContractsToRepo.ps1`) with per-tech generation dashboard/status and strict empty-generation quality gates
- SDT render invoke script with mapping schema checks (`scripts/Invoke-AssemblerSdtRender.ps1`)
- bundle-aware orchestration (`scripts/Invoke-AssemblerBundleRender.ps1`)
- skeleton ingest bootstrap (`scripts/New-AssemblerSkeleton.ps1`)
- interactive launchers (`gui/Start-AssemblerGui.ps1`, `gui/Start-AssemblerGui.Wpf.ps1`)
- built-in Lenovo.DE skeletons (`templates/skeletons/Lenovo.DE`)

## Operator warning: unresolved mapping placeholders

If your mapping contains runtime placeholders like `__TARGET__` or `__SYSTEM__`, do **not** call `Invoke-AssemblerSdtRender.ps1` directly against that unresolved mapping.

Use `Invoke-AssemblerBundleRender.ps1` (or a resolved-mapping helper) so placeholders are expanded before SDT render.

Common symptoms of using the wrong entrypoint are:
- `ASB-ASM-SDT-DATASET-MISSING` for paths like `datasets/.../__TARGET__/...`
- many `ASB-ASM-SDT-UNRESOLVED-TAG` errors from cascading unresolved inputs

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

## Template catalog contract

Template catalog validation uses:
- `.deps/contracts/standards/assembler/assembler.template-catalog.schema.v1.json`
