# Assembler GUI launchers

This folder contains side-by-side launcher options for assembler rendering. The
WPF launcher uses `scripts/Invoke-LnvAssemblerRender.ps1` as the canonical
process boundary, while the legacy cross-platform launcher still calls
`scripts/Invoke-AssemblerBundleRender.ps1` directly.

## Standard GUI input locations

Both GUI launchers initialize with the same canonical defaults:
- `BundleRoot`: the concrete bundle under `<repo>/bundle` when that folder is itself a valid bundle, or the newest valid child bundle under `<repo>/bundle` when staged child bundles exist; otherwise the operator must choose a bundle path manually
- `CatalogPath`: `templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json` (then `DE-SDT-Dummy.catalog.json`, then the first `*.catalog.json` under `templates/`)
- `OutputRoot`: `<repo>/out`
- `ContractsRoot`: `<repo>/.deps/contracts`

Mandatory inputs for execution are:
- `BundleRoot` (existing folder) or `BundleArchivePath` (`.lnvbundle.zip` archive)
- `CatalogPath` (existing file)
- `OutputRoot` (created if missing)

In the WPF launcher, the bundle input mode selects either a folder picker or an archive file picker. Folder mode preselects the newest valid staged bundle when available. Switching to archive mode clears the folder preselection, and both bundle Browse modes start in `<repo>/bundle`. Archive selections are passed to `Invoke-LnvAssemblerRender.ps1` as `-BundleArchivePath`; folder selections remain `-BundleRoot`.

Archive imports are verified before render and extracted into `<repo>/bundle/<archive-base-name>-<guid>/`. The extracted bundle is retained beside existing bundle folders for rerender/debug use. Because `bundle/` is a working staging area, imported bundles may appear as untracked files unless cleaned up separately.

Document-property inputs exposed in the GUI:
- `Title`
- `Customer`
- `CustomerAbbr`
- `Location`
- `Subsidiary`
- `Environment`
- `DocumentReference`
- `Document Version` (`LNV.Version`)
- `Configuration Snapshot Date` (`LNV.ConfigSnapDate`)
- `Reference ID` (`LNV.ReferenceID`)
- `Classification`
- `Support Region` (`SupportRegion`, loaded from the catalog-adjacent support-region sidecar)

Workflow defaults exposed in the GUI:
- DOCX enabled
- TXT disabled
- `DocxMatchMode=both`
- `UnresolvedTokenPolicy=retain`

## `Start-AssemblerGui.ps1` (cross-platform launcher)

Supports mode selection with `-Mode Auto|WinForms|Terminal`:
- `Auto`: uses WinForms on Windows, falls back to Terminal elsewhere.
- `WinForms`: launches a Windows WinForms form with **Browse** buttons for bundle, catalog, output, and contracts paths. Includes **Verbose** and **Debug** checkboxes; default output shows concise status/findings summary, **Verbose** adds matched-tag details, and **Debug** includes the full raw render JSON dump.
- `Terminal`: prompts in shell (showing defaults) and runs bundle render non-graphically.

## `Start-AssemblerGui.Wpf.ps1` (Windows-only WPF launcher)

A dedicated WPF launcher for Windows desktop environments. It loads WPF assemblies
(`PresentationFramework`, `PresentationCore`, `WindowsBase`), renders a native
WPF window, provides **Browse** buttons for path fields, and invokes
`Invoke-LnvAssemblerRender.ps1` with the provided inputs in an out-of-process
`pwsh.exe` child process. It also includes
**Verbose** and **Debug** checkboxes that provide two-step feedback: concise findings summary by default, matched-tag details in Verbose mode, and full raw render JSON in Debug mode.

Current WPF layout:
- `Document Properties` tab for operator-entered document metadata
- `Render Workflow` tab for bundle/catalog/output selection and render execution
- `Mapping Studio` tab for contract-driven mapping inspection and in-progress authoring
- `Rich Views` tab appears when `Microsoft.Web.WebView2.Wpf.dll` has been restored and the Microsoft Edge WebView2 Runtime is available

Current WPF document-property behavior:
- `Document Version` defaults to `v1.0.0`
- `Configuration Snapshot Date` is refreshed from a selected folder bundle capture date when available; archive mode exposes the verified extracted bundle path after render in `archiveImport.extractedBundleRoot`
- `Reference ID` is available as an operator-entered field
- `Support Region` defaults from `templates/skeletons/Lenovo.DE/DE-SDT-SupportRegions.sidecar.json` and is passed to the renderer as `DocSupportRegion`
- DOCX rendering now resolves the same sidecar into support-process fields for literal `<<SDT:...>>` tokens, content controls, or `DOCPROPERTY` fields such as `SupportRegionLabel`, `SupportTier`, `SupportPhoneNumbers`, `SupportServiceRequestUrl`, `SupportPortalUrl`, `SupportPlanUrl`, and `SupportProcessText`
- `CoverKey.png` and `HeadFootKey.png` are shown beneath the document-property fields as a visual key for the cover page and header/footer regions

Current `Mapping Studio` status:
- WPF only
- DOCX template collections only
- nested `Overview`, `Datasets`, `Targets`, `Connector`, and `Changes` tabs
- connector-first inspection flow with read-only details first and explicit edit actions second
- still work in progress for mapping authoring

See `../docs/mapping-studio-wip.md` for the current detailed status.

Current WPF render execution behavior:
- render starts through `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Invoke-LnvAssemblerRender.ps1`
- folder mode passes `-BundleRoot`; archive mode passes `-BundleArchivePath`
- `progress.jsonl` is polled while the render runs so the UI remains responsive
- `render-report.json` is read after completion and points back to the unchanged backend bundle report; archive renders also include `archiveImport.extractedBundleRoot`
- **Cancel** writes the wrapper cancel signal and the wrapper terminates the backend process if it is still running

Current `Rich Views` behavior:
- read-only WebView2 surface for SDT inventory, mapping manifest text, resolved mappings, validation, progress, and render report
- WebView commands are handled by WPF; file IO and render execution do not move into JavaScript
- restore the SDK assembly with `pwsh ./scripts/Restore-WebView2Dependency.ps1`; the restored package is kept under `.deps/nuget` and is not committed

## Quick start

WinForms/terminal-capable launcher:

```powershell
pwsh ./gui/Start-AssemblerGui.ps1 -Mode Auto
pwsh ./gui/Start-AssemblerGui.ps1 -Mode WinForms
pwsh ./gui/Start-AssemblerGui.ps1 -Mode Terminal
```

WPF launcher (Windows only):

```powershell
pwsh ./gui/Start-AssemblerGui.Wpf.ps1
```

## Entrypoints, chaining, and placeholder safety

Public entrypoint map:
- **Pipeline path:** `Invoke-AssemblerPipeline.ps1` -> `Invoke-AssemblerBundleRender.ps1` -> `Invoke-AssemblerSdtRender.ps1`
- **WPF GUI path:** `Start-AssemblerGui.Wpf.ps1` -> `Invoke-LnvAssemblerRender.ps1` -> `Invoke-AssemblerBundleRender.ps1` -> `Invoke-AssemblerSdtRender.ps1`
- **Legacy GUI path:** `Start-AssemblerGui.ps1` -> `Invoke-AssemblerBundleRender.ps1` -> `Invoke-AssemblerSdtRender.ps1`

The WPF process boundary is the wrapper, and the wrapper delegates to bundle render. If mappings contain runtime placeholders such as `__TARGET__` and `__SYSTEM__`, bundle render is still required to resolve those values before SDT rendering.

DOCX behavior exposed through the GUI:
- `literal-token` populates dataset-driven literal `<<SDT:...>>` tokens in DOCX parts.
- `content-control-tag` populates tagged DOCX controls and `DOCPROPERTY`-backed fields such as title, customer, environment, document reference, and classification.
- `both` runs both DOCX paths and is the current default.
- When `Title` and `Customer` are supplied, generated DOCX filenames currently resolve to `Title - Customer.docx`.

## Output selection guidance

The GUI participates in the same output-selection model as CLI orchestration:

1. **Catalog `enabled`** decides baseline participation for each entry.
2. **CLI filters** on bundle render (`-TechId`, `-EntryId`, `-OutputType docx|text`) can further narrow outputs.
3. **GUI Debug/Advanced controls** expose the same narrowing behavior through Entry ID and DOCX/TXT toggles.
4. **GUI Debug/Advanced unresolved-token policy** lets operators keep unresolved `<<SDT:...>>` tokens (`retain`, default) for reruns/troubleshooting or strip them (`remove`) in final output.

Current default behavior is **DOCX-only**. In the WPF launcher, TXT output is currently hidden/disabled and the render flow is effectively DOCX-only.
