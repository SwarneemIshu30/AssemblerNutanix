#!/usr/bin/env pwsh
<#
.SYNOPSIS
Windows-only WPF launcher for bundle-aware Assembler rendering.
#>
param(
    [Parameter(Mandatory = $false)][string]$BundleRoot,
    [Parameter(Mandatory = $false)][string]$CatalogPath,
    [Parameter(Mandatory = $false)][string]$OutputRoot,
    [Parameter(Mandatory = $false)][string]$ContractsRoot,
    [Parameter(Mandatory = $false)][string[]]$TechId,
    [Parameter(Mandatory = $false)][string[]]$EntryId,
    [Parameter(Mandatory = $false)][string]$DocTitle = 'Solution Name [Lenovo DE]',
    [Parameter(Mandatory = $false)][string]$DocCustomer = 'Customer',
    [Parameter(Mandatory = $false)][string]$DocCustomerAbbr = 'CustomerAbbr',
    [Parameter(Mandatory = $false)][string]$DocLocation = 'Australia',
    [Parameter(Mandatory = $false)][string]$DocSubsidiary = 'subsid',
    [Parameter(Mandatory = $false)][string]$DocEnvironment = 'Production',
    [Parameter(Mandatory = $false)][string]$DocDocumentReference = 'Lenovo ThinkSystem DE As Built',
    [Parameter(Mandatory = $false)][string]$DocClassification = 'PROTECTED',
    [Parameter(Mandatory = $false)][bool]$IncludeDocx = $true,
    [Parameter(Mandatory = $false)][bool]$IncludeTxt = $false,
    [Parameter(Mandatory = $false)][bool]$AnnotateResolvedTags = $false,
    [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
    [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Start-AssemblerGui.Wpf.ps1 is Windows-only and requires desktop .NET/WPF support.'
}

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

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Invoke-BundleRender {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $false)][string[]]$TechId,
        [Parameter(Mandatory = $false)][string[]]$EntryId,
        [Parameter(Mandatory = $false)][string]$DocTitle,
        [Parameter(Mandatory = $false)][string]$DocCustomer,
        [Parameter(Mandatory = $false)][string]$DocCustomerAbbr,
        [Parameter(Mandatory = $false)][string]$DocLocation,
        [Parameter(Mandatory = $false)][string]$DocSubsidiary,
        [Parameter(Mandatory = $false)][string]$DocEnvironment,
        [Parameter(Mandatory = $false)][string]$DocDocumentReference,
        [Parameter(Mandatory = $false)][string]$DocClassification,
        [Parameter(Mandatory = $false)][bool]$IncludeDocx = $true,
        [Parameter(Mandatory = $false)][bool]$IncludeTxt = $false,
        [Parameter(Mandatory = $false)][bool]$AnnotateResolvedTags = $false,
        [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
        [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
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

    $params = @{ BundleRoot = $BundleRoot; CatalogPath = $CatalogPath; OutputRoot = $OutputRoot }
    if (-not [string]::IsNullOrWhiteSpace($ContractsRoot)) { $params.ContractsRoot = $ContractsRoot }
    if ($TechId -and $TechId.Count -gt 0) { $params.TechId = $TechId }
    if ($EntryId -and $EntryId.Count -gt 0) { $params.EntryId = $EntryId }
    if (-not [string]::IsNullOrWhiteSpace($DocTitle)) { $params.DocTitle = $DocTitle }
    if (-not [string]::IsNullOrWhiteSpace($DocCustomer)) { $params.DocCustomer = $DocCustomer }
    if (-not [string]::IsNullOrWhiteSpace($DocCustomerAbbr)) { $params.DocCustomerAbbr = $DocCustomerAbbr }
    if (-not [string]::IsNullOrWhiteSpace($DocLocation)) { $params.DocLocation = $DocLocation }
    if (-not [string]::IsNullOrWhiteSpace($DocSubsidiary)) { $params.DocSubsidiary = $DocSubsidiary }
    if (-not [string]::IsNullOrWhiteSpace($DocEnvironment)) { $params.DocEnvironment = $DocEnvironment }
    if (-not [string]::IsNullOrWhiteSpace($DocDocumentReference)) { $params.DocDocumentReference = $DocDocumentReference }
    if (-not [string]::IsNullOrWhiteSpace($DocClassification)) { $params.DocClassification = $DocClassification }

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
    $params.DocxMatchMode = [string]$DocxMatchMode
    $params.UnresolvedTokenPolicy = [string]$UnresolvedTokenPolicy

    & $invokeScript @params
}

$xaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='Assembler Bundle Renderer (WPF launcher)' Height='760' Width='960' WindowStartupLocation='CenterScreen'>
  <Grid Margin='12'>
    <Grid.RowDefinitions>
      <RowDefinition Height='*'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='*'/>
    </Grid.RowDefinitions>

    <TabControl Grid.Row='0' Name='MainTabs' Margin='0,34,0,0'>
      <TabItem Header='Document Properties'>
        <Grid Margin='12'>
          <Grid.RowDefinitions>
            <RowDefinition Height='Auto'/>
            <RowDefinition Height='Auto'/>
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

          <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Title (core property)</TextBlock>
          <TextBox Name='DocTitleText' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Customer (custom property)</TextBlock>
          <TextBox Name='DocCustomerText' Grid.Row='1' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='2' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>CustomerAbbr (custom property)</TextBlock>
          <TextBox Name='DocCustomerAbbrText' Grid.Row='2' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='3' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Location (custom property)</TextBlock>
          <TextBox Name='DocLocationText' Grid.Row='3' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='4' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Subsidiary (custom property)</TextBlock>
          <TextBox Name='DocSubsidiaryText' Grid.Row='4' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='5' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Environment (custom property)</TextBlock>
          <TextBox Name='DocEnvironmentText' Grid.Row='5' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='6' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>DocumentReference (custom property)</TextBlock>
          <TextBox Name='DocDocumentReferenceText' Grid.Row='6' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='7' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Classification (custom property)</TextBlock>
          <TextBox Name='DocClassificationText' Grid.Row='7' Grid.Column='1' Margin='0,0,0,8'/>
        </Grid>
      </TabItem>

      <TabItem Header='Render Workflow'>
        <Grid Margin='12'>
          <Grid.RowDefinitions>
            <RowDefinition Height='Auto'/>
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
            <ColumnDefinition Width='100'/>
          </Grid.ColumnDefinitions>

          <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Bundle Root</TextBlock>
          <TextBox Name='BundleRootText' Grid.Row='0' Grid.Column='1' Margin='0,0,8,8'/>
          <Button Name='BundleBrowseButton' Grid.Row='0' Grid.Column='2' Margin='0,0,0,8'>Browse</Button>

          <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Catalog Path</TextBlock>
          <TextBox Name='CatalogPathText' Grid.Row='1' Grid.Column='1' Margin='0,0,8,8'/>
          <Button Name='CatalogBrowseButton' Grid.Row='1' Grid.Column='2' Margin='0,0,0,8'>Browse</Button>

          <TextBlock Grid.Row='2' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Output Root</TextBlock>
          <TextBox Name='OutputRootText' Grid.Row='2' Grid.Column='1' Margin='0,0,8,8'/>
          <Button Name='OutputBrowseButton' Grid.Row='2' Grid.Column='2' Margin='0,0,0,8'>Browse</Button>

          <TextBlock Grid.Row='3' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Contracts Root</TextBlock>
          <TextBox Name='ContractsRootText' Grid.Row='3' Grid.Column='1' Margin='0,0,8,8'/>
          <Button Name='ContractsBrowseButton' Grid.Row='3' Grid.Column='2' Margin='0,0,0,8'>Browse</Button>

          <GroupBox Grid.Row='5' Grid.Column='0' Grid.ColumnSpan='3' Header='Debug/Advanced' Margin='0,0,0,8'>
            <Grid Margin='8,6,8,8'>
              <Grid.RowDefinitions>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
              </Grid.RowDefinitions>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width='220'/>
                <ColumnDefinition Width='*'/>
              </Grid.ColumnDefinitions>

              <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Tech IDs (comma-separated)</TextBlock>
              <TextBox Name='TechIdText' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8'/>

              <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Entry IDs (comma-separated)</TextBlock>
              <TextBox Name='EntryIdText' Grid.Row='1' Grid.Column='1' Margin='0,0,0,8'/>

              <StackPanel Grid.Row='2' Grid.Column='1' Orientation='Horizontal' HorizontalAlignment='Left'>
                <CheckBox Name='DocxCheckBox' Margin='0,0,16,0' VerticalAlignment='Center'>Enable DOCX output</CheckBox>
                <CheckBox Name='TxtCheckBox' Margin='0,0,16,0' VerticalAlignment='Center'>Enable TXT output</CheckBox>
                <CheckBox Name='AnnotateCheckBox' Margin='0,0,16,0' VerticalAlignment='Center'>Annotate resolved SDT tags (text debug)</CheckBox>
              </StackPanel>

              <TextBlock Grid.Row='3' Grid.Column='0' Margin='0,0,8,0' VerticalAlignment='Center'>Matching mode</TextBlock>
                <StackPanel Grid.Row='3' Grid.Column='1' Orientation='Horizontal' HorizontalAlignment='Left'>
                <StackPanel Margin='0,0,24,0'>
                  <TextBlock Margin='0,0,0,4'>DOCX</TextBlock>
                  <ComboBox Name='DocxMatchModeCombo' Width='190' SelectedIndex='0'>
                    <ComboBoxItem>both</ComboBoxItem>
                    <ComboBoxItem>content-control-tag</ComboBoxItem>
                    <ComboBoxItem>literal-token</ComboBoxItem>
                  </ComboBox>
                </StackPanel>
                <StackPanel Margin='0,0,24,0'>
                  <TextBlock Margin='0,0,0,4'>Unresolved tokens</TextBlock>
                  <ComboBox Name='UnresolvedTokenPolicyCombo' Width='170' SelectedIndex='0'>
                    <ComboBoxItem>retain</ComboBoxItem>
                    <ComboBoxItem>remove</ComboBoxItem>
                  </ComboBox>
                </StackPanel>
                <StackPanel>
                  <TextBlock Margin='0,0,0,4'>TXT</TextBlock>
                  <ComboBox Name='TxtMatchModeCombo' Width='160' IsEnabled='False' SelectedIndex='0'>
                    <ComboBoxItem>literal-token</ComboBoxItem>
                  </ComboBox>
                </StackPanel>
              </StackPanel>
            </Grid>
          </GroupBox>
        </Grid>
      </TabItem>
    </TabControl>

    <Border Grid.Row='0'
            HorizontalAlignment='Right'
            VerticalAlignment='Top'
            Margin='0,2,4,0'
            Background='#CCFFFFFF'
            CornerRadius='4'
            Padding='8,6,8,6'
            Panel.ZIndex='10'
            IsHitTestVisible='False'>
      <StackPanel Orientation='Vertical'>
        <Image Name='BrandLogoImage'
               Height='22'
               Stretch='Uniform'
               HorizontalAlignment='Right'/>
        <TextBlock Margin='0,4,0,0'
                   Text='Professional Services AsBuilt Document Creation Toolset'
                   FontSize='11'
                   TextAlignment='Right'
                   Foreground='#FF1F1F1F'/>
      </StackPanel>
    </Border>

    <StackPanel Grid.Row='1' Orientation='Horizontal' HorizontalAlignment='Left'>
      <Button Name='RunButton' Width='140' Margin='0,6,10,6'>Run Render</Button>
      <CheckBox Name='VerboseCheckBox' Margin='0,6,10,6' VerticalAlignment='Center'>Verbose (include matched tags)</CheckBox>
      <CheckBox Name='DebugCheckBox' Margin='0,6,10,6' VerticalAlignment='Center'>Debug (include raw render JSON)</CheckBox>
      <TextBlock Name='StatusText' VerticalAlignment='Center'>Ready</TextBlock>
    </StackPanel>

    <TextBox Name='OutputText' Grid.Row='2' Margin='0,8,0,0' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$bundleRootText = $window.FindName('BundleRootText')
$catalogPathText = $window.FindName('CatalogPathText')
$outputRootText = $window.FindName('OutputRootText')
$contractsRootText = $window.FindName('ContractsRootText')
$docTitleText = $window.FindName('DocTitleText')
$docCustomerText = $window.FindName('DocCustomerText')
$docCustomerAbbrText = $window.FindName('DocCustomerAbbrText')
$docLocationText = $window.FindName('DocLocationText')
$docSubsidiaryText = $window.FindName('DocSubsidiaryText')
$docEnvironmentText = $window.FindName('DocEnvironmentText')
$docDocumentReferenceText = $window.FindName('DocDocumentReferenceText')
$docClassificationText = $window.FindName('DocClassificationText')
$brandLogoImage = $window.FindName('BrandLogoImage')

$brandLogoPath = Join-Path $PSScriptRoot 'internal/lenovo-logo.png'
if ($brandLogoImage -and (Test-Path -LiteralPath $brandLogoPath -PathType Leaf)) {
    $brandLogoUri = [System.Uri]::new($brandLogoPath, [System.UriKind]::Absolute)
    $brandBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $brandBitmap.BeginInit()
    $brandBitmap.UriSource = $brandLogoUri
    $brandBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $brandBitmap.EndInit()
    $brandLogoImage.Source = $brandBitmap
}
$techIdText = $window.FindName('TechIdText')
$entryIdText = $window.FindName('EntryIdText')
$bundleBrowseButton = $window.FindName('BundleBrowseButton')
$catalogBrowseButton = $window.FindName('CatalogBrowseButton')
$outputBrowseButton = $window.FindName('OutputBrowseButton')
$contractsBrowseButton = $window.FindName('ContractsBrowseButton')
$runButton = $window.FindName('RunButton')
$statusText = $window.FindName('StatusText')
$verboseCheckBox = $window.FindName('VerboseCheckBox')
$debugCheckBox = $window.FindName('DebugCheckBox')
$docxCheckBox = $window.FindName('DocxCheckBox')
$txtCheckBox = $window.FindName('TxtCheckBox')
$annotateCheckBox = $window.FindName('AnnotateCheckBox')
$docxMatchModeCombo = $window.FindName('DocxMatchModeCombo')
$unresolvedTokenPolicyCombo = $window.FindName('UnresolvedTokenPolicyCombo')
$outputText = $window.FindName('OutputText')

$bundleRootText.Text = $BundleRoot
$catalogPathText.Text = $CatalogPath
$outputRootText.Text = $OutputRoot
$contractsRootText.Text = $ContractsRoot
$docTitleText.Text = $DocTitle
$docCustomerText.Text = $DocCustomer
$docCustomerAbbrText.Text = $DocCustomerAbbr
$docLocationText.Text = $DocLocation
$docSubsidiaryText.Text = $DocSubsidiary
$docEnvironmentText.Text = $DocEnvironment
$docDocumentReferenceText.Text = $DocDocumentReference
$docClassificationText.Text = $DocClassification
$techIdText.Text = (($TechId ?? @()) -join ',')
$entryIdText.Text = (($EntryId ?? @()) -join ',')
$docxCheckBox.IsChecked = $IncludeDocx
$txtCheckBox.IsChecked = $IncludeTxt
$annotateCheckBox.IsChecked = $AnnotateResolvedTags
switch ([string]$DocxMatchMode) {
    'literal-token' { $docxMatchModeCombo.SelectedIndex = 2 }
    'content-control-tag' { $docxMatchModeCombo.SelectedIndex = 1 }
    default { $docxMatchModeCombo.SelectedIndex = 0 }
}
switch ([string]$UnresolvedTokenPolicy) {
    'remove' { $unresolvedTokenPolicyCombo.SelectedIndex = 1 }
    default { $unresolvedTokenPolicyCombo.SelectedIndex = 0 }
}

$bundleBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $bundleRootText.Text = $dialog.SelectedPath }
})
$catalogBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Catalog JSON (*.catalog.json)|*.catalog.json|JSON (*.json)|*.json|All files (*.*)|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $catalogPathText.Text = $dialog.FileName }
})
$outputBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $outputRootText.Text = $dialog.SelectedPath }
})
$contractsBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $contractsRootText.Text = $dialog.SelectedPath }
})

$runButton.Add_Click({
    try {
        $techSelection = @($techIdText.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $entrySelection = @($entryIdText.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $docxModeSelection = [string]$docxMatchModeCombo.SelectedItem.Content
        $unresolvedTokenPolicySelection = [string]$unresolvedTokenPolicyCombo.SelectedItem.Content
        $resultJson = Invoke-BundleRender -BundleRoot $bundleRootText.Text -CatalogPath $catalogPathText.Text -OutputRoot $outputRootText.Text -ContractsRoot $contractsRootText.Text -TechId $techSelection -EntryId $entrySelection -DocTitle $docTitleText.Text -DocCustomer $docCustomerText.Text -DocCustomerAbbr $docCustomerAbbrText.Text -DocLocation $docLocationText.Text -DocSubsidiary $docSubsidiaryText.Text -DocEnvironment $docEnvironmentText.Text -DocDocumentReference $docDocumentReferenceText.Text -DocClassification $docClassificationText.Text -IncludeDocx ([bool]$docxCheckBox.IsChecked) -IncludeTxt ([bool]$txtCheckBox.IsChecked) -AnnotateResolvedTags ([bool]$annotateCheckBox.IsChecked) -DocxMatchMode $docxModeSelection -UnresolvedTokenPolicy $unresolvedTokenPolicySelection
        $statusText.Text = 'Render completed successfully.'
        $outputText.Text = if ($debugCheckBox.IsChecked) {
            Format-DebugBundleOutput -BundleResultJson $resultJson
        }
        elseif ($verboseCheckBox.IsChecked) {
            Format-VerboseFindingsOutput -BundleResultJson $resultJson
        }
        else {
            Format-RenderFindingsSummary -BundleResultJson $resultJson
        }
    }
    catch {
        $statusText.Text = 'Render failed.'
        $outputText.Text = $_.Exception.ToString()
    }
})

[void]$window.ShowDialog()
