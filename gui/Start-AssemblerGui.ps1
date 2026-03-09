#!/usr/bin/env pwsh
<#
.SYNOPSIS
Interactive launcher for bundle-aware Assembler rendering.
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'WinForms', 'Terminal')]
    [string]$Mode = 'Auto',

    [Parameter(Mandatory = $false)][string]$BundleRoot,
    [Parameter(Mandatory = $false)][string]$CatalogPath,
    [Parameter(Mandatory = $false)][string]$OutputRoot,
    [Parameter(Mandatory = $false)][string]$ContractsRoot,
    [Parameter(Mandatory = $false)][string[]]$TechId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'

function Resolve-DefaultBundleRoot {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $bundleRoot = Join-Path $RepoRoot 'bundle'
    if (Test-Path -LiteralPath $bundleRoot -PathType Container) { return $bundleRoot }

    return $null

    }

function Resolve-DefaultCatalogPath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $preferredCatalogs = @(
        (Join-Path $RepoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'),
        (Join-Path $RepoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json')
    )

    foreach ($preferred in $preferredCatalogs) {
        if (Test-Path -LiteralPath $preferred -PathType Leaf) { return $preferred }
    }

    $firstCatalog = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'templates') -Recurse -Filter '*.catalog.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $firstCatalog) { return $firstCatalog.FullName }

    return $null
}

function Resolve-DefaultContractsRoot {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $candidates = @(
        (Join-Path $RepoRoot '.deps/contracts'),
        (Join-Path $RepoRoot 'export/repo-ready/contracts')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    return (Join-Path $RepoRoot '.deps/contracts')
}

$defaultBundleRoot = Resolve-DefaultBundleRoot -RepoRoot $repoRoot
$defaultCatalogPath = Resolve-DefaultCatalogPath -RepoRoot $repoRoot
$defaultOutputRoot = Join-Path $repoRoot 'out'
$defaultContractsRoot = Resolve-DefaultContractsRoot -RepoRoot $repoRoot

if ([string]::IsNullOrWhiteSpace($BundleRoot)) { $BundleRoot = $defaultBundleRoot }
if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = $defaultCatalogPath }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = $defaultOutputRoot }
if ([string]::IsNullOrWhiteSpace($ContractsRoot)) { $ContractsRoot = $defaultContractsRoot }

function Invoke-BundleRender {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $false)][string[]]$TechId
    )

    if ([string]::IsNullOrWhiteSpace($BundleRoot) -or -not (Test-Path -LiteralPath $BundleRoot -PathType Container)) {
        throw "BundleRoot not found: $BundleRoot"
    }

    if ([string]::IsNullOrWhiteSpace($CatalogPath) -or -not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "CatalogPath not found: $CatalogPath"
    }

    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
        New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
    }

    $params = @{
        BundleRoot = $BundleRoot
        CatalogPath = $CatalogPath
        OutputRoot = $OutputRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ContractsRoot)) {
        $params.ContractsRoot = $ContractsRoot
    }
    if ($TechId -and $TechId.Count -gt 0) {
        $params.TechId = $TechId
    }

    & $invokeScript @params
}

function Invoke-TerminalMode {
    param(
        [string]$BundleRoot,
        [string]$CatalogPath,
        [string]$OutputRoot,
        [string]$ContractsRoot,
        [string[]]$TechId
    )

    if ([string]::IsNullOrWhiteSpace($BundleRoot)) {
        $BundleRoot = Read-Host "BundleRoot [$defaultBundleRoot]"
        if ([string]::IsNullOrWhiteSpace($BundleRoot)) { $BundleRoot = $defaultBundleRoot }
    }
    if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
        $CatalogPath = Read-Host "CatalogPath [$defaultCatalogPath]"
        if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = $defaultCatalogPath }
    }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Read-Host "OutputRoot [$defaultOutputRoot]"
        if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = $defaultOutputRoot }
    }
    if ([string]::IsNullOrWhiteSpace($ContractsRoot)) {
        $ContractsRoot = Read-Host "ContractsRoot [$defaultContractsRoot]"
        if ([string]::IsNullOrWhiteSpace($ContractsRoot)) { $ContractsRoot = $defaultContractsRoot }
    }
    if (-not $TechId -or $TechId.Count -eq 0) {
        $techInput = Read-Host 'TechId list (optional, comma-separated)'
        if (-not [string]::IsNullOrWhiteSpace($techInput)) {
            $TechId = @($techInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    Invoke-BundleRender -BundleRoot $BundleRoot -CatalogPath $CatalogPath -OutputRoot $OutputRoot -ContractsRoot $ContractsRoot -TechId $TechId
}

function Invoke-WinFormsMode {
    param(
        [string]$BundleRoot,
        [string]$CatalogPath,
        [string]$OutputRoot,
        [string]$ContractsRoot,
        [string[]]$TechId
    )

    if (-not $IsWindows) {
        throw 'WinForms mode is supported on Windows only.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Assembler Bundle Renderer (WinForms)'
    $form.Width = 900
    $form.Height = 460
    $form.StartPosition = 'CenterScreen'

    $labels = @(
        @{ Text = 'Bundle Root'; Top = 20 },
        @{ Text = 'Catalog Path'; Top = 70 },
        @{ Text = 'Output Root'; Top = 120 },
        @{ Text = 'Contracts Root'; Top = 170 },
        @{ Text = 'Tech IDs (optional, comma-separated)'; Top = 220 }
    )

    foreach ($labelDef in $labels) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $labelDef.Text
        $label.Left = 20
        $label.Top = $labelDef.Top
        $label.Width = 280
        $form.Controls.Add($label)
    }

    function New-TextBox([int]$top, [string]$value) {
        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Left = 20
        $textBox.Top = $top
        $textBox.Width = 730
        $textBox.Text = $value
        return $textBox
    }

    function New-BrowseButton([int]$top, [string]$text, [scriptblock]$onClick) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $text
        $button.Left = 770
        $button.Top = $top
        $button.Width = 90
        $button.Add_Click($onClick)
        return $button
    }

    $bundleTextBox = New-TextBox -top 40 -value $BundleRoot
    $catalogTextBox = New-TextBox -top 90 -value $CatalogPath
    $outputTextBox = New-TextBox -top 140 -value $OutputRoot
    $contractsTextBox = New-TextBox -top 190 -value $ContractsRoot
    $techTextBox = New-TextBox -top 240 -value (($TechId ?? @()) -join ',')

    $bundleBrowse = New-BrowseButton -top 38 -text 'Browse' -onClick {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $bundleTextBox.Text = $dialog.SelectedPath }
    }
    $catalogBrowse = New-BrowseButton -top 88 -text 'Browse' -onClick {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Catalog JSON (*.catalog.json)|*.catalog.json|JSON (*.json)|*.json|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $catalogTextBox.Text = $dialog.FileName }
    }
    $outputBrowse = New-BrowseButton -top 138 -text 'Browse' -onClick {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $outputTextBox.Text = $dialog.SelectedPath }
    }
    $contractsBrowse = New-BrowseButton -top 188 -text 'Browse' -onClick {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $contractsTextBox.Text = $dialog.SelectedPath }
    }

    $runButton = New-Object System.Windows.Forms.Button
    $runButton.Text = 'Run Render'
    $runButton.Left = 20
    $runButton.Top = 300
    $runButton.Width = 150

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Left = 190
    $statusLabel.Top = 305
    $statusLabel.Width = 670
    $statusLabel.Text = 'Ready'

    $runButton.Add_Click({
        try {
            $techSelection = @($techTextBox.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $resultJson = Invoke-BundleRender -BundleRoot $bundleTextBox.Text -CatalogPath $catalogTextBox.Text -OutputRoot $outputTextBox.Text -ContractsRoot $contractsTextBox.Text -TechId $techSelection
            $statusLabel.Text = 'Render completed successfully.'
            [System.Windows.Forms.MessageBox]::Show(($resultJson | Out-String), 'Assembler Result') | Out-Null
        }
        catch {
            $statusLabel.Text = "Render failed: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), 'Assembler Error') | Out-Null
        }
    })

    foreach ($control in @($bundleTextBox, $catalogTextBox, $outputTextBox, $contractsTextBox, $techTextBox, $bundleBrowse, $catalogBrowse, $outputBrowse, $contractsBrowse, $runButton, $statusLabel)) {
        $form.Controls.Add($control)
    }

    [void]$form.ShowDialog()
}

$effectiveMode = $Mode
if ($Mode -eq 'Auto') {
    $effectiveMode = if ($IsWindows) { 'WinForms' } else { 'Terminal' }
}

switch ($effectiveMode) {
    'WinForms' { Invoke-WinFormsMode -BundleRoot $BundleRoot -CatalogPath $CatalogPath -OutputRoot $OutputRoot -ContractsRoot $ContractsRoot -TechId $TechId }
    'Terminal' { Invoke-TerminalMode -BundleRoot $BundleRoot -CatalogPath $CatalogPath -OutputRoot $OutputRoot -ContractsRoot $ContractsRoot -TechId $TechId }
    default { throw "Unsupported mode: $effectiveMode" }
}
