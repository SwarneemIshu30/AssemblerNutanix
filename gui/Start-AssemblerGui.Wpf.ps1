#!/usr/bin/env pwsh
<#
.SYNOPSIS
Windows-only WPF launcher for bundle-aware Assembler rendering.
#>
param(
    [Parameter(Mandatory = $false)][string]$BundleRoot,
    [Parameter(Mandatory = $false)][string]$CatalogPath,
    [Parameter(Mandatory = $false)][string]$OutputRoot = './out',
    [Parameter(Mandatory = $false)][string]$ContractsRoot,
    [Parameter(Mandatory = $false)][string[]]$TechId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Start-AssemblerGui.Wpf.ps1 is Windows-only and requires desktop .NET/WPF support.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Invoke-BundleRender {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $false)][string[]]$TechId
    )

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

$xaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='Assembler Bundle Renderer (WPF launcher)' Height='420' Width='780' WindowStartupLocation='CenterScreen'>
  <Grid Margin='12'>
    <Grid.RowDefinitions>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='*'/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width='220'/>
      <ColumnDefinition Width='*'/>
    </Grid.ColumnDefinitions>

    <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Bundle Root</TextBlock>
    <TextBox Name='BundleRootText' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8'/>

    <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Catalog Path</TextBlock>
    <TextBox Name='CatalogPathText' Grid.Row='1' Grid.Column='1' Margin='0,0,0,8'/>

    <TextBlock Grid.Row='2' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Output Root</TextBlock>
    <TextBox Name='OutputRootText' Grid.Row='2' Grid.Column='1' Margin='0,0,0,8'/>

    <TextBlock Grid.Row='3' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Contracts Root (optional)</TextBlock>
    <TextBox Name='ContractsRootText' Grid.Row='3' Grid.Column='1' Margin='0,0,0,8'/>

    <TextBlock Grid.Row='4' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Tech IDs (comma-separated)</TextBlock>
    <TextBox Name='TechIdText' Grid.Row='4' Grid.Column='1' Margin='0,0,0,8'/>

    <StackPanel Grid.Row='5' Grid.Column='1' Orientation='Horizontal' HorizontalAlignment='Left'>
      <Button Name='RunButton' Width='140' Margin='0,6,10,6'>Run Render</Button>
      <TextBlock Name='StatusText' VerticalAlignment='Center'>Ready</TextBlock>
    </StackPanel>

    <TextBox Name='OutputText' Grid.Row='6' Grid.ColumnSpan='2' Margin='0,8,0,0' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$bundleRootText = $window.FindName('BundleRootText')
$catalogPathText = $window.FindName('CatalogPathText')
$outputRootText = $window.FindName('OutputRootText')
$contractsRootText = $window.FindName('ContractsRootText')
$techIdText = $window.FindName('TechIdText')
$runButton = $window.FindName('RunButton')
$statusText = $window.FindName('StatusText')
$outputText = $window.FindName('OutputText')

$bundleRootText.Text = $BundleRoot
$catalogPathText.Text = $CatalogPath
$outputRootText.Text = $OutputRoot
$contractsRootText.Text = $ContractsRoot
$techIdText.Text = (($TechId ?? @()) -join ',')

$runButton.Add_Click({
    try {
        $techSelection = @($techIdText.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $resultJson = Invoke-BundleRender -BundleRoot $bundleRootText.Text -CatalogPath $catalogPathText.Text -OutputRoot $outputRootText.Text -ContractsRoot $contractsRootText.Text -TechId $techSelection
        $statusText.Text = 'Render completed successfully.'
        $outputText.Text = $resultJson | Out-String
    }
    catch {
        $statusText.Text = 'Render failed.'
        $outputText.Text = $_.Exception.ToString()
    }
})

[void]$window.ShowDialog()
