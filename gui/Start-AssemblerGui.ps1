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
    [Parameter(Mandatory = $false)][string[]]$TechId,
    [Parameter(Mandatory = $false)][string[]]$EntryId,
    [Parameter(Mandatory = $false)][bool]$IncludeDocx = $true,
    [Parameter(Mandatory = $false)][bool]$IncludeTxt = $true,
    [Parameter(Mandatory = $false)][bool]$AnnotateResolvedTags = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'

$guiHelpersModule = Join-Path $PSScriptRoot 'internal/AssemblerGuiHelpers.psm1'
Import-Module $guiHelpersModule -Force

$defaultBundleRoot = Resolve-DefaultBundleRoot -RepoRoot $repoRoot
$defaultCatalogPath = Resolve-DefaultCatalogPath -RepoRoot $repoRoot
$defaultOutputRoot = Join-Path $repoRoot 'out'
$defaultContractsRoot = Resolve-DefaultContractsRoot -RepoRoot $repoRoot

if ([string]::IsNullOrWhiteSpace($BundleRoot)) { $BundleRoot = $defaultBundleRoot }
if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = $defaultCatalogPath }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = $defaultOutputRoot }
if ([string]::IsNullOrWhiteSpace($ContractsRoot)) { $ContractsRoot = $defaultContractsRoot }

$includeDocxSpecified = $PSBoundParameters.ContainsKey('IncludeDocx')
$includeTxtSpecified = $PSBoundParameters.ContainsKey('IncludeTxt')

function Invoke-BundleRender {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $false)][string[]]$TechId,
        [Parameter(Mandatory = $false)][string[]]$EntryId,
        [Parameter(Mandatory = $false)][bool]$IncludeDocx = $true,
        [Parameter(Mandatory = $false)][bool]$IncludeTxt = $true,
        [Parameter(Mandatory = $false)][bool]$AnnotateResolvedTags = $false
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
    if ($EntryId -and $EntryId.Count -gt 0) {
        $params.EntryId = $EntryId
    }

    $outputType = @()
    if ($IncludeDocx) { $outputType += 'docx' }
    if ($IncludeTxt) { $outputType += 'text' }
    if ($outputType.Count -eq 0) {
        throw 'At least one output variant must be selected (DOCX and/or TXT).'
    }
    $params.OutputType = $outputType
    if ($AnnotateResolvedTags) {
        $params.AnnotateResolvedTags = $true
    }

    & $invokeScript @params
}

function Invoke-TerminalMode {
    param(
        [string]$BundleRoot,
        [string]$CatalogPath,
        [string]$OutputRoot,
        [string]$ContractsRoot,
        [string[]]$TechId,
        [string[]]$EntryId,
        [bool]$IncludeDocx = $true,
        [bool]$IncludeTxt = $true,
        [bool]$AnnotateResolvedTags = $false,
        [bool]$PromptIncludeDocx = $true,
        [bool]$PromptIncludeTxt = $true
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
    if (-not $EntryId -or $EntryId.Count -eq 0) {
        $entryIdInput = Read-Host 'Debug/Advanced - EntryId list override (optional, comma-separated)'
        if (-not [string]::IsNullOrWhiteSpace($entryIdInput)) {
            $EntryId = @($entryIdInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    if ($PromptIncludeDocx) {
        $docxInput = Read-Host "Debug/Advanced - Include DOCX variant? (Y/n) [$((if ($IncludeDocx) { 'Y' } else { 'N' }))]"
        if (-not [string]::IsNullOrWhiteSpace($docxInput)) {
            $IncludeDocx = -not ($docxInput.Trim() -match '^(n|no|0|false)$')
        }
    }
    if ($PromptIncludeTxt) {
        $txtInput = Read-Host "Debug/Advanced - Include TXT variant? (Y/n) [$((if ($IncludeTxt) { 'Y' } else { 'N' }))]"
        if (-not [string]::IsNullOrWhiteSpace($txtInput)) {
            $IncludeTxt = -not ($txtInput.Trim() -match '^(n|no|0|false)$')
        }
    }
    $annotateInput = Read-Host "Debug/Advanced - Annotate resolved SDT tags in text output? (y/N) [$((if ($AnnotateResolvedTags) { 'Y' } else { 'N' }))]"
    if (-not [string]::IsNullOrWhiteSpace($annotateInput)) {
        $AnnotateResolvedTags = ($annotateInput.Trim() -match '^(y|yes|1|true)$')
    }

    Invoke-BundleRender -BundleRoot $BundleRoot -CatalogPath $CatalogPath -OutputRoot $OutputRoot -ContractsRoot $ContractsRoot -TechId $TechId -EntryId $EntryId -IncludeDocx $IncludeDocx -IncludeTxt $IncludeTxt -AnnotateResolvedTags $AnnotateResolvedTags
}

function Invoke-WinFormsMode {
    param(
        [string]$BundleRoot,
        [string]$CatalogPath,
        [string]$OutputRoot,
        [string]$ContractsRoot,
        [string[]]$TechId,
        [string[]]$EntryId,
        [bool]$IncludeDocx = $true,
        [bool]$IncludeTxt = $true,
        [bool]$AnnotateResolvedTags = $false
    )

    if (-not $IsWindows) {
        throw 'WinForms mode is supported on Windows only.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Assembler Bundle Renderer (WinForms)'
    $form.Width = 900
    $form.Height = 620
    $form.StartPosition = 'CenterScreen'

    $labels = @(
        @{ Text = 'Bundle Root'; Top = 20 },
        @{ Text = 'Catalog Path'; Top = 70 },
        @{ Text = 'Output Root'; Top = 120 },
        @{ Text = 'Contracts Root'; Top = 170 }
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
    $advancedGroup = New-Object System.Windows.Forms.GroupBox
    $advancedGroup.Text = 'Debug/Advanced'
    $advancedGroup.Left = 20
    $advancedGroup.Top = 225
    $advancedGroup.Width = 840
    $advancedGroup.Height = 170

    $techIdLabel = New-Object System.Windows.Forms.Label
    $techIdLabel.Left = 15
    $techIdLabel.Top = 28
    $techIdLabel.Width = 320
    $techIdLabel.Text = 'Tech IDs (optional, comma-separated)'

    $techTextBox = New-Object System.Windows.Forms.TextBox
    $techTextBox.Left = 15
    $techTextBox.Top = 48
    $techTextBox.Width = 800
    $techTextBox.Text = (($TechId ?? @()) -join ',')

    $entryOverrideLabel = New-Object System.Windows.Forms.Label
    $entryOverrideLabel.Left = 15
    $entryOverrideLabel.Top = 78
    $entryOverrideLabel.Width = 320
    $entryOverrideLabel.Text = 'Entry ID override (optional, comma-separated)'

    $entryOverrideTextBox = New-Object System.Windows.Forms.TextBox
    $entryOverrideTextBox.Left = 15
    $entryOverrideTextBox.Top = 98
    $entryOverrideTextBox.Width = 800
    $entryOverrideTextBox.Text = (($EntryId ?? @()) -join ',')

    $docxCheckBox = New-Object System.Windows.Forms.CheckBox
    $docxCheckBox.Left = 15
    $docxCheckBox.Top = 130
    $docxCheckBox.Width = 160
    $docxCheckBox.Text = 'Enable DOCX output'
    $docxCheckBox.Checked = $IncludeDocx

    $txtCheckBox = New-Object System.Windows.Forms.CheckBox
    $txtCheckBox.Left = 190
    $txtCheckBox.Top = 130
    $txtCheckBox.Width = 160
    $txtCheckBox.Text = 'Enable TXT output'
    $txtCheckBox.Checked = $IncludeTxt

    $annotateCheckBox = New-Object System.Windows.Forms.CheckBox
    $annotateCheckBox.Left = 365
    $annotateCheckBox.Top = 130
    $annotateCheckBox.Width = 410
    $annotateCheckBox.Text = 'Annotate resolved SDT tags (text output debug)'
    $annotateCheckBox.Checked = $AnnotateResolvedTags

    foreach ($advancedControl in @($techIdLabel, $techTextBox, $entryOverrideLabel, $entryOverrideTextBox, $docxCheckBox, $txtCheckBox, $annotateCheckBox)) {
        $advancedGroup.Controls.Add($advancedControl)
    }

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
    $runButton.Top = 460
    $runButton.Width = 150

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Left = 190
    $statusLabel.Top = 465
    $statusLabel.Width = 670
    $statusLabel.Text = 'Ready'

    $verboseCheckBox = New-Object System.Windows.Forms.CheckBox
    $verboseCheckBox.Left = 20
    $verboseCheckBox.Top = 495
    $verboseCheckBox.Width = 280
    $verboseCheckBox.Text = 'Verbose (include matched tags)'
    $verboseCheckBox.Checked = $false

    $debugCheckBox = New-Object System.Windows.Forms.CheckBox
    $debugCheckBox.Left = 320
    $debugCheckBox.Top = 495
    $debugCheckBox.Width = 280
    $debugCheckBox.Text = 'Debug (include raw render JSON)'
    $debugCheckBox.Checked = $false

    $runButton.Add_Click({
        try {
            $techSelection = @($techTextBox.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $entrySelection = @($entryOverrideTextBox.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $resultJson = Invoke-BundleRender -BundleRoot $bundleTextBox.Text -CatalogPath $catalogTextBox.Text -OutputRoot $outputTextBox.Text -ContractsRoot $contractsTextBox.Text -TechId $techSelection -EntryId $entrySelection -IncludeDocx $docxCheckBox.Checked -IncludeTxt $txtCheckBox.Checked -AnnotateResolvedTags $annotateCheckBox.Checked
            $statusLabel.Text = 'Render completed successfully.'
            $dialogText = if ($debugCheckBox.Checked) {
                Format-DebugBundleOutput -BundleResultJson $resultJson
            }
            elseif ($verboseCheckBox.Checked) {
                Format-VerboseFindingsOutput -BundleResultJson $resultJson
            }
            else {
                Format-RenderFindingsSummary -BundleResultJson $resultJson
            }
            [System.Windows.Forms.MessageBox]::Show($dialogText, 'Assembler Result') | Out-Null
        }
        catch {
            $statusLabel.Text = "Render failed: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), 'Assembler Error') | Out-Null
        }
    })

    foreach ($control in @($bundleTextBox, $catalogTextBox, $outputTextBox, $contractsTextBox, $techTextBox, $bundleBrowse, $catalogBrowse, $outputBrowse, $contractsBrowse, $advancedGroup, $runButton, $statusLabel, $verboseCheckBox, $debugCheckBox)) {
        $form.Controls.Add($control)
    }

    [void]$form.ShowDialog()
}

$effectiveMode = $Mode
if ($Mode -eq 'Auto') {
    $effectiveMode = if ($IsWindows) { 'WinForms' } else { 'Terminal' }
}

switch ($effectiveMode) {
    'WinForms' { Invoke-WinFormsMode -BundleRoot $BundleRoot -CatalogPath $CatalogPath -OutputRoot $OutputRoot -ContractsRoot $ContractsRoot -TechId $TechId -EntryId $EntryId -IncludeDocx $IncludeDocx -IncludeTxt $IncludeTxt -AnnotateResolvedTags $AnnotateResolvedTags }
    'Terminal' { Invoke-TerminalMode -BundleRoot $BundleRoot -CatalogPath $CatalogPath -OutputRoot $OutputRoot -ContractsRoot $ContractsRoot -TechId $TechId -EntryId $EntryId -IncludeDocx $IncludeDocx -IncludeTxt $IncludeTxt -AnnotateResolvedTags $AnnotateResolvedTags -PromptIncludeDocx (-not $includeDocxSpecified) -PromptIncludeTxt (-not $includeTxtSpecified) }
    default { throw "Unsupported mode: $effectiveMode" }
}
