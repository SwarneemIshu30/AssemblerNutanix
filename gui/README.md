# Assembler GUI launchers

This folder contains side-by-side launcher options for bundle rendering via
`scripts/Invoke-AssemblerBundleRender.ps1`.

## Standard GUI input locations

Both GUI launchers now initialize with the same canonical defaults:
- `BundleRoot`: `<repo>/bundle`
- `CatalogPath`: `templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json` (or first `*.catalog.json` under `templates/`)
- `OutputRoot`: `<repo>/out`
- `ContractsRoot`: `<repo>/.deps/contracts` (fallback `<repo>/export/repo-ready/contracts` if present)

Mandatory inputs for execution are:
- `BundleRoot` (existing folder)
- `CatalogPath` (existing file)
- `OutputRoot` (created if missing)

## `Start-AssemblerGui.ps1` (cross-platform launcher)

Supports mode selection with `-Mode Auto|WinForms|Terminal`:
- `Auto`: uses WinForms on Windows, falls back to Terminal elsewhere.
- `WinForms`: launches a Windows WinForms form with **Browse** buttons for bundle, catalog, output, and contracts paths.
- `Terminal`: prompts in shell (showing defaults) and runs bundle render non-graphically.

## `Start-AssemblerGui.Wpf.ps1` (Windows-only WPF launcher)

A dedicated WPF launcher for Windows desktop environments. It loads WPF assemblies
(`PresentationFramework`, `PresentationCore`, `WindowsBase`), renders a native
WPF window, provides **Browse** buttons for path fields, and invokes
`Invoke-AssemblerBundleRender.ps1` with the provided inputs.

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
