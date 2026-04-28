#!/usr/bin/env pwsh
<#
.SYNOPSIS
Windows-only WPF launcher for bundle-aware Assembler rendering.
#>
param(
    [Parameter(Mandatory = $false)][string]$BundleRoot,
    [Parameter(Mandatory = $false)][string]$BundleArchivePath,
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
    [Parameter(Mandatory = $false)][string]$DocVersion = 'v1.0.0',
    [Parameter(Mandatory = $false)][string]$DocConfigSnapDate,
    [Parameter(Mandatory = $false)][string]$DocReferenceId,
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
$invokeScript = Join-Path $repoRoot 'scripts/Invoke-LnvAssemblerRender.ps1'

$guiHelpersModule = Join-Path $PSScriptRoot 'internal/AssemblerGuiHelpers.psm1'
Import-Module $guiHelpersModule -Force
$mappingStudioModule = Join-Path $PSScriptRoot 'internal/AssemblerGuiMappingStudio.psm1'
Import-Module $mappingStudioModule -Force
$renderProcessModule = Join-Path $PSScriptRoot 'internal/AssemblerGuiRenderProcess.psm1'
Import-Module $renderProcessModule -Force
$webViewBridgeModule = Join-Path $PSScriptRoot 'internal/AssemblerGuiWebViewBridge.psm1'
Import-Module $webViewBridgeModule -Force
$webView2Module = Join-Path $PSScriptRoot 'internal/AssemblerGuiWebView2.psm1'
Import-Module $webView2Module -Force

$defaultBundleRoot = Resolve-DefaultBundleRoot -RepoRoot $repoRoot
$defaultCatalogPath = Resolve-DefaultCatalogPath -RepoRoot $repoRoot
$defaultOutputRoot = Join-Path $repoRoot 'out'
$defaultContractsRoot = Resolve-DefaultContractsRoot -RepoRoot $repoRoot

if ([string]::IsNullOrWhiteSpace($BundleRoot) -and [string]::IsNullOrWhiteSpace($BundleArchivePath)) { $BundleRoot = $defaultBundleRoot }
if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = $defaultCatalogPath }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = $defaultOutputRoot }
if ([string]::IsNullOrWhiteSpace($ContractsRoot)) { $ContractsRoot = $defaultContractsRoot }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Set-WpfImageSourceFromFile {
    param(
        [Parameter(Mandatory = $false)]$ImageControl,
        [Parameter(Mandatory = $false)][string]$Path
    )

    if ($null -eq $ImageControl) { return }
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $imageUri = [System.Uri]::new($resolvedPath, [System.UriKind]::Absolute)
    $bitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.UriSource = $imageUri
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $bitmap.Freeze()
    $ImageControl.Source = $bitmap
}

function Invoke-BundleRender {
    param(
        [Parameter(Mandatory = $false)][string]$BundleRoot,
        [Parameter(Mandatory = $false)][string]$BundleArchivePath,
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
        [Parameter(Mandatory = $false)][string]$DocVersion,
        [Parameter(Mandatory = $false)][string]$DocConfigSnapDate,
        [Parameter(Mandatory = $false)][string]$DocReferenceId,
        [Parameter(Mandatory = $false)][string]$DocClassification,
        [Parameter(Mandatory = $false)][bool]$IncludeDocx = $true,
        [Parameter(Mandatory = $false)][bool]$IncludeTxt = $false,
        [Parameter(Mandatory = $false)][bool]$AnnotateResolvedTags = $false,
        [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
        [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
    )

    $bundleRootProvided = -not [string]::IsNullOrWhiteSpace($BundleRoot)
    $archiveProvided = -not [string]::IsNullOrWhiteSpace($BundleArchivePath)
    if ($bundleRootProvided -and $archiveProvided) {
        throw 'BundleRoot and BundleArchivePath are mutually exclusive.'
    }
    if (-not $bundleRootProvided -and -not $archiveProvided) {
        throw 'Either BundleRoot or BundleArchivePath is required.'
    }
    if ($bundleRootProvided -and -not (Test-Path -LiteralPath $BundleRoot -PathType Container)) {
        throw "BundleRoot not found: $BundleRoot"
    }
    if ($archiveProvided -and -not (Test-Path -LiteralPath $BundleArchivePath -PathType Leaf)) {
        throw "BundleArchivePath not found: $BundleArchivePath"
    }
    if ([string]::IsNullOrWhiteSpace($CatalogPath) -or -not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "CatalogPath not found: $CatalogPath"
    }
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
        New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
    }

    $params = @{ CatalogPath = $CatalogPath; OutputRoot = $OutputRoot }
    if ($archiveProvided) { $params.BundleArchivePath = $BundleArchivePath } else { $params.BundleRoot = $BundleRoot }
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
    if (-not [string]::IsNullOrWhiteSpace($DocVersion)) { $params.DocVersion = $DocVersion }
    if (-not [string]::IsNullOrWhiteSpace($DocConfigSnapDate)) { $params.DocConfigSnapDate = $DocConfigSnapDate }
    if (-not [string]::IsNullOrWhiteSpace($DocReferenceId)) { $params.DocReferenceId = $DocReferenceId }
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
        Title='Assembler Bundle Renderer (WPF launcher)' Height='860' Width='1280' WindowStartupLocation='CenterScreen'>
  <Grid Margin='12'>
    <Grid.RowDefinitions>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='*'/>
    </Grid.RowDefinitions>

    <TabControl Grid.Row='1' Name='MainTabs' Margin='0'>
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
            <RowDefinition Height='Auto'/>
            <RowDefinition Height='Auto'/>
            <RowDefinition Height='Auto'/>
            <RowDefinition Height='*'/>
          </Grid.RowDefinitions>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width='220'/>
            <ColumnDefinition Width='*'/>
          </Grid.ColumnDefinitions>

          <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Title (1)</TextBlock>
          <TextBox Name='DocTitleText' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Customer (2)</TextBlock>
          <TextBox Name='DocCustomerText' Grid.Row='1' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='2' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Customer Abbreviation</TextBlock>
          <TextBox Name='DocCustomerAbbrText' Grid.Row='2' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='3' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Location</TextBlock>
          <TextBox Name='DocLocationText' Grid.Row='3' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='4' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Subsidiary</TextBlock>
          <TextBox Name='DocSubsidiaryText' Grid.Row='4' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='5' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Environment (3)</TextBlock>
          <TextBox Name='DocEnvironmentText' Grid.Row='5' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='6' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Document Reference (7)</TextBlock>
          <TextBox Name='DocDocumentReferenceText' Grid.Row='6' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='7' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Document Version (4)</TextBlock>
          <TextBox Name='DocVersionText' Grid.Row='7' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='8' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Configuration Snapshot Date (5)</TextBlock>
          <TextBox Name='DocConfigSnapDateText' Grid.Row='8' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='9' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Reference ID (6)</TextBlock>
          <TextBox Name='DocReferenceIdText' Grid.Row='9' Grid.Column='1' Margin='0,0,0,8'/>

          <TextBlock Grid.Row='10' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Classification (8)</TextBlock>
          <TextBox Name='DocClassificationText' Grid.Row='10' Grid.Column='1' Margin='0,0,0,8'/>

          <Border Grid.Row='11'
                  Grid.Column='0'
                  Grid.ColumnSpan='2'
                  Margin='0,28,0,0'
                  Padding='16'
                  BorderBrush='#D0D7DE'
                  BorderThickness='1'
                  CornerRadius='6'
                  HorizontalAlignment='Stretch'>
            <StackPanel>
              <TextBlock Margin='0,0,0,14'
                         FontSize='15'
                         FontWeight='SemiBold'
                         Text='Document Layout Reference Diagrams'/>
              <WrapPanel HorizontalAlignment='Left' ItemWidth='360'>
                <StackPanel Width='340' Margin='0,0,20,12' HorizontalAlignment='Left'>
                  <TextBlock Margin='0,0,0,10'
                             FontSize='14'
                             FontWeight='SemiBold'
                             Text='Cover Page Diagram'/>
                  <Image Name='CoverKeyImage'
                         Stretch='Uniform'
                         HorizontalAlignment='Left'
                         VerticalAlignment='Top'
                         MaxHeight='280'/>
                </StackPanel>

                <StackPanel Width='340' Margin='0,0,0,12' HorizontalAlignment='Left'>
                  <TextBlock Margin='0,0,0,10'
                             FontSize='14'
                             FontWeight='SemiBold'
                             Text='Header/Footer Diagram'/>
                  <Image Name='HeadFootKeyImage'
                         Stretch='Uniform'
                         HorizontalAlignment='Left'
                         VerticalAlignment='Top'
                         MaxHeight='280'/>
                </StackPanel>
              </WrapPanel>
            </StackPanel>
          </Border>
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

          <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Bundle Input</TextBlock>
          <Grid Grid.Row='0' Grid.Column='1' Margin='0,0,8,8'>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width='130'/>
              <ColumnDefinition Width='*'/>
            </Grid.ColumnDefinitions>
            <ComboBox Name='BundleInputModeCombo' Grid.Column='0' Margin='0,0,8,0' SelectedIndex='0'>
              <ComboBoxItem>Folder</ComboBoxItem>
              <ComboBoxItem>Archive</ComboBoxItem>
            </ComboBox>
            <TextBox Name='BundleRootText' Grid.Column='1'/>
          </Grid>
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
                <CheckBox Name='DocxCheckBox' Margin='0,0,16,0' VerticalAlignment='Center'>DOCX output</CheckBox>
                <CheckBox Name='AnnotateCheckBox' Margin='0,0,16,0' VerticalAlignment='Center'>Annotate resolved SDT tags</CheckBox>
                <CheckBox Name='TxtCheckBox' Margin='0,0,16,0' VerticalAlignment='Center' Visibility='Collapsed'>Enable TXT output</CheckBox>
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
                <StackPanel Visibility='Collapsed'>
                  <TextBlock Margin='0,0,0,4'>TXT</TextBlock>
                  <ComboBox Name='TxtMatchModeCombo' Width='160' IsEnabled='False' SelectedIndex='0'>
                    <ComboBoxItem>literal-token</ComboBoxItem>
                  </ComboBox>
                </StackPanel>
              </StackPanel>
            </Grid>
          </GroupBox>

          <StackPanel Grid.Row='6' Grid.Column='0' Grid.ColumnSpan='3' Orientation='Horizontal' HorizontalAlignment='Left' Margin='0,6,0,6'>
            <Button Name='RunButton' Width='140' Margin='0,0,10,0'>Run Render</Button>
            <Button Name='CancelButton' Width='110' Margin='0,0,10,0' IsEnabled='False'>Cancel</Button>
            <CheckBox Name='VerboseCheckBox' Margin='0,0,10,0' VerticalAlignment='Center'>Verbose (include matched tags)</CheckBox>
            <CheckBox Name='DebugCheckBox' Margin='0,0,10,0' VerticalAlignment='Center'>Debug (include raw render JSON)</CheckBox>
            <TextBlock Name='StatusText' VerticalAlignment='Center'>Ready</TextBlock>
          </StackPanel>

          <Grid Grid.Row='7' Grid.Column='0' Grid.ColumnSpan='3' Margin='0,8,0,0'>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width='2*'/>
              <ColumnDefinition Width='*'/>
            </Grid.ColumnDefinitions>
            <TextBox Name='OutputText' Grid.Column='0' Margin='0,0,8,0' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
            <TextBox Name='ProgressText' Grid.Column='1' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
          </Grid>
        </Grid>
      </TabItem>

      <TabItem Header='Mapping Studio'>
        <Grid Margin='12'>
          <Grid.RowDefinitions>
            <RowDefinition Height='Auto'/>
            <RowDefinition Height='Auto'/>
            <RowDefinition Height='*'/>
          </Grid.RowDefinitions>

          <Grid Grid.Row='0' Margin='0,0,0,8'>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width='160'/>
              <ColumnDefinition Width='*'/>
              <ColumnDefinition Width='110'/>
              <ColumnDefinition Width='110'/>
              <ColumnDefinition Width='110'/>
            </Grid.ColumnDefinitions>

            <TextBlock Grid.Column='0' Margin='0,0,8,0' VerticalAlignment='Center'>Template collection</TextBlock>
            <ComboBox Name='MappingCollectionCombo' Grid.Column='1' Margin='0,0,8,0' MinWidth='420'/>
            <Button Name='MappingRefreshButton' Grid.Column='2' Margin='0,0,8,0'>Refresh</Button>
            <Button Name='MappingSaveButton' Grid.Column='3' Margin='0,0,8,0'>Save changes</Button>
            <Button Name='MappingClearChangesButton' Grid.Column='4'>Clear queued</Button>
          </Grid>

          <TextBlock Name='MappingModeText' Grid.Row='1' Margin='0,0,0,8' TextWrapping='Wrap'/>

          <TabControl Grid.Row='2' Name='MappingStudioTabs'>
            <TabItem Header='Overview'>
              <TextBox Name='MappingOverviewText' Margin='8' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
            </TabItem>

            <TabItem Header='Datasets'>
              <Grid Margin='8'>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width='320'/>
                  <ColumnDefinition Width='*'/>
                </Grid.ColumnDefinitions>
                <ListBox Name='MappingDatasetsList' Grid.Column='0' Margin='0,0,8,0'/>
                <TextBox Name='MappingDatasetDetailText' Grid.Column='1' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
              </Grid>
            </TabItem>

            <TabItem Header='Targets'>
              <Grid Margin='8'>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width='380'/>
                  <ColumnDefinition Width='*'/>
                </Grid.ColumnDefinitions>
                <ListBox Name='MappingTargetsList' Grid.Column='0' Margin='0,0,8,0'/>
                <TextBox Name='MappingTargetDetailText' Grid.Column='1' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
              </Grid>
            </TabItem>

            <TabItem Header='Connector'>
              <Grid Margin='8'>
                <Grid.RowDefinitions>
                  <RowDefinition Height='*'/>
                  <RowDefinition Height='Auto'/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width='460'/>
                  <ColumnDefinition Width='*'/>
                </Grid.ColumnDefinitions>

                <GroupBox Grid.Row='0' Grid.Column='0' Header='Current Connections' Margin='0,0,8,0'>
                  <Grid Margin='8'>
                    <Grid.RowDefinitions>
                      <RowDefinition Height='Auto'/>
                      <RowDefinition Height='Auto'/>
                      <RowDefinition Height='*'/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width='*'/>
                      <ColumnDefinition Width='150'/>
                    </Grid.ColumnDefinitions>

                    <TextBox Name='ConnectorSearchTextBox' Grid.Row='0' Grid.Column='0' Margin='0,0,8,8'/>
                    <ComboBox Name='ConnectorQuickFilterCombo' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8' SelectedIndex='0'>
                      <ComboBoxItem>All</ComboBoxItem>
                      <ComboBoxItem>Mapped</ComboBoxItem>
                      <ComboBoxItem>Placed</ComboBoxItem>
                      <ComboBoxItem>Staged</ComboBoxItem>
                      <ComboBoxItem>Scalar</ComboBoxItem>
                      <ComboBoxItem>Table</ComboBoxItem>
                    </ComboBox>

                    <TextBlock Name='ConnectorConnectionSummaryText' Grid.Row='1' Grid.Column='0' Grid.ColumnSpan='2' Margin='0,0,0,8' TextWrapping='Wrap'/>

                    <ListBox Name='ConnectorConnectionList' Grid.Row='2' Grid.Column='0' Grid.ColumnSpan='2'>
                      <ListBox.ItemTemplate>
                        <DataTemplate>
                          <Border Padding='4' Margin='0,0,0,4' BorderBrush='#FFD8D8D8' BorderThickness='0,0,0,1'>
                            <StackPanel>
                              <TextBlock Text='{Binding Label}' FontWeight='SemiBold' TextWrapping='Wrap'/>
                              <TextBlock Text='{Binding Summary}' Margin='0,3,0,0' Foreground='#FF5B5B5B' TextWrapping='Wrap'/>
                              <TextBlock Text='{Binding BadgeText}' Margin='0,3,0,0' Foreground='#FF0F5B7A' FontSize='11' TextWrapping='Wrap'/>
                            </StackPanel>
                          </Border>
                        </DataTemplate>
                      </ListBox.ItemTemplate>
                    </ListBox>
                  </Grid>
                </GroupBox>

                <Grid Grid.Row='0' Grid.Column='1'>
                  <Grid.RowDefinitions>
                    <RowDefinition Height='Auto'/>
                    <RowDefinition Height='Auto'/>
                    <RowDefinition Height='Auto'/>
                    <RowDefinition Height='Auto'/>
                    <RowDefinition Height='*'/>
                  </Grid.RowDefinitions>

                  <TextBlock Name='ConnectorActionText' Grid.Row='0' Margin='0,0,0,8' TextWrapping='Wrap'/>
                  <TextBox Name='ConnectorDetailText' Grid.Row='1' MinHeight='170' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>

                  <StackPanel Grid.Row='2' Orientation='Horizontal' Margin='0,8,0,8' VerticalAlignment='Top'>
                    <Button Name='ConnectorEditButton' Width='110' Height='30' Margin='0,0,8,0'>Edit mapping</Button>
                    <Button Name='ConnectorReplaceButton' Width='150' Height='30' Margin='0,0,8,0'>Replace target</Button>
                    <Button Name='ConnectorNewButton' Width='120' Height='30' Margin='0,0,8,0'>New connection</Button>
                    <Button Name='ConnectorOpenDatasetButton' Width='110' Height='30' Margin='0,0,8,0'>Open dataset</Button>
                    <Button Name='ConnectorOpenTargetButton' Width='100' Height='30'>Open target</Button>
                  </StackPanel>

                  <TextBlock Grid.Row='3' Margin='0,0,0,6'>Example preview</TextBlock>
                  <TextBox Name='ConnectorPreviewText' Grid.Row='4' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
                </Grid>

                <Expander Name='ConnectorAuthoringExpander' Grid.Row='1' Grid.Column='0' Grid.ColumnSpan='2' Margin='0,8,0,0' Header='Create or Rebind' IsExpanded='False'>
                  <ScrollViewer VerticalScrollBarVisibility='Auto' HorizontalScrollBarVisibility='Disabled'>
                    <Grid Margin='8'>
                      <Grid.RowDefinitions>
                        <RowDefinition Height='Auto'/>
                        <RowDefinition Height='Auto'/>
                        <RowDefinition Height='Auto'/>
                        <RowDefinition Height='Auto'/>
                        <RowDefinition Height='Auto'/>
                      </Grid.RowDefinitions>

                      <GroupBox Grid.Row='0' Header='Mapping Setup'>
                        <Grid Margin='8'>
                          <Grid.RowDefinitions>
                            <RowDefinition Height='Auto'/>
                            <RowDefinition Height='Auto'/>
                            <RowDefinition Height='Auto'/>
                            <RowDefinition Height='Auto'/>
                          </Grid.RowDefinitions>
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width='110'/>
                            <ColumnDefinition Width='*'/>
                            <ColumnDefinition Width='110'/>
                            <ColumnDefinition Width='*'/>
                          </Grid.ColumnDefinitions>

                          <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Dataset</TextBlock>
                          <ComboBox Name='ConnectorDatasetList' Grid.Row='0' Grid.Column='1' Margin='0,0,12,8' IsEditable='True' IsTextSearchEnabled='True'/>
                          <TextBlock Grid.Row='0' Grid.Column='2' Margin='0,0,8,8' VerticalAlignment='Center'>Render shape</TextBlock>
                          <ComboBox Name='ConnectorRenderAsCombo' Grid.Row='0' Grid.Column='3' Margin='0,0,0,8'>
                            <ComboBoxItem>table</ComboBoxItem>
                            <ComboBoxItem>scalar</ComboBoxItem>
                          </ComboBox>

                          <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Selector</TextBlock>
                          <ComboBox Name='ConnectorSelectorCombo' Grid.Row='1' Grid.Column='1' Margin='0,0,12,8' IsEditable='True'/>
                          <TextBlock Grid.Row='1' Grid.Column='2' Margin='0,0,8,8' VerticalAlignment='Center'>Target</TextBlock>
                          <ComboBox Name='ConnectorTargetList' Grid.Row='1' Grid.Column='3' Margin='0,0,0,8' IsEditable='True' IsTextSearchEnabled='True'/>

                          <TextBlock Grid.Row='2' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>View</TextBlock>
                          <TextBox Name='ConnectorViewText' Grid.Row='2' Grid.Column='1' Margin='0,0,12,8'/>
                          <TextBlock Grid.Row='2' Grid.Column='2' Margin='0,0,8,8' VerticalAlignment='Center'>Projection ref</TextBlock>
                          <TextBox Name='ConnectorProjectionRefText' Grid.Row='2' Grid.Column='3' Margin='0,0,0,8' IsReadOnly='True'/>

                          <TextBlock Name='ConnectorSourceFieldsText' Grid.Row='3' Grid.Column='0' Grid.ColumnSpan='3' Margin='0,0,12,0' TextWrapping='Wrap'/>
                          <CheckBox Name='ConnectorRequiredCheckBox' Grid.Row='3' Grid.Column='3' VerticalAlignment='Center' HorizontalAlignment='Left'>Required</CheckBox>
                        </Grid>
                      </GroupBox>

                      <Grid Grid.Row='1' Margin='0,8,0,8'>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width='520'/>
                          <ColumnDefinition Width='*'/>
                        </Grid.ColumnDefinitions>

                        <GroupBox Grid.Column='0' Header='Columns' Margin='0,0,8,0'>
                          <Grid Margin='8'>
                            <Grid.ColumnDefinitions>
                              <ColumnDefinition Width='230'/>
                              <ColumnDefinition Width='*'/>
                              <ColumnDefinition Width='Auto'/>
                            </Grid.ColumnDefinitions>
                            <ListBox Name='ConnectorProjectionColumnsList' Grid.Column='0' Margin='0,0,8,0' MinHeight='220'/>
                            <Grid Grid.Column='1' Margin='0,0,8,0'>
                              <Grid.RowDefinitions>
                                <RowDefinition Height='Auto'/>
                                <RowDefinition Height='Auto'/>
                                <RowDefinition Height='Auto'/>
                                <RowDefinition Height='Auto'/>
                              </Grid.RowDefinitions>
                              <Grid.ColumnDefinitions>
                                <ColumnDefinition Width='75'/>
                                <ColumnDefinition Width='*'/>
                              </Grid.ColumnDefinitions>
                              <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Header</TextBlock>
                              <TextBox Name='ConnectorColumnNameText' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8'/>
                              <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Source</TextBlock>
                              <ComboBox Name='ConnectorColumnSourceCombo' Grid.Row='1' Grid.Column='1' Margin='0,0,0,8' IsEditable='True'/>
                              <TextBlock Grid.Row='2' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Format</TextBlock>
                              <TextBox Name='ConnectorColumnFormatText' Grid.Row='2' Grid.Column='1' Margin='0,0,0,8'/>
                              <TextBlock Grid.Row='3' Grid.Column='0' Margin='0,0,8,0' VerticalAlignment='Center'>Delimiter</TextBlock>
                              <TextBox Name='ConnectorColumnDelimiterText' Grid.Row='3' Grid.Column='1'/>
                            </Grid>
                            <StackPanel Grid.Column='2' VerticalAlignment='Top'>
                              <Button Name='ConnectorColumnAddButton' Width='90' Height='30' Margin='0,0,0,8'>Add</Button>
                              <Button Name='ConnectorColumnRemoveButton' Width='90' Height='30' Margin='0,0,0,8'>Remove</Button>
                              <Button Name='ConnectorColumnUpButton' Width='90' Height='30' Margin='0,0,0,8'>Move up</Button>
                              <Button Name='ConnectorColumnDownButton' Width='90' Height='30'>Move down</Button>
                            </StackPanel>
                          </Grid>
                        </GroupBox>

                        <GroupBox Grid.Column='1' Header='Rendered Table Preview'>
                          <Grid Margin='8'>
                            <Grid.RowDefinitions>
                              <RowDefinition Height='Auto'/>
                              <RowDefinition Height='*'/>
                            </Grid.RowDefinitions>
                            <TextBlock Name='ConnectorRenderedGridStatusText' Grid.Row='0' Margin='0,0,0,8' TextWrapping='Wrap'/>
                            <DataGrid Name='ConnectorRenderedPreviewGrid'
                                      Grid.Row='1'
                                      MinHeight='260'
                                      AutoGenerateColumns='False'
                                      IsReadOnly='True'
                                      CanUserSortColumns='False'
                                      CanUserAddRows='False'
                                      CanUserDeleteRows='False'
                                      CanUserReorderColumns='False'
                                      HeadersVisibility='Column'
                                      GridLinesVisibility='All'
                                      RowHeaderWidth='0'
                                      SelectionMode='Single'
                                      SelectionUnit='FullRow'
                                      HorizontalScrollBarVisibility='Auto'
                                      VerticalScrollBarVisibility='Auto'/>
                          </Grid>
                        </GroupBox>
                      </Grid>

                      <StackPanel Grid.Row='2' Orientation='Horizontal' Margin='0,0,0,8' VerticalAlignment='Top'>
                        <Button Name='ConnectorPreviewButton' Width='110' Height='30' Margin='0,0,8,0'>Preview</Button>
                        <Button Name='ConnectorQueueButton' Width='140' Height='30' Margin='0,0,8,0'>Queue change</Button>
                        <Button Name='ConnectorResetButton' Width='100' Height='30'>Reset</Button>
                      </StackPanel>

                      <TextBlock Name='ConnectorAuthoringHintText' Grid.Row='3' Margin='0,0,0,8' TextWrapping='Wrap'/>

                      <Expander Grid.Row='4' Header='Advanced preview and data tools' IsExpanded='False'>
                        <Grid Margin='8'>
                          <Grid.RowDefinitions>
                            <RowDefinition Height='Auto'/>
                            <RowDefinition Height='Auto'/>
                          </Grid.RowDefinitions>
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width='*'/>
                            <ColumnDefinition Width='*'/>
                          </Grid.ColumnDefinitions>

                          <GroupBox Grid.Row='0' Grid.Column='0' Header='Source Preview' Margin='0,0,8,8'>
                            <TextBox Name='ConnectorSourcePreviewText' Margin='8' MinHeight='140' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
                          </GroupBox>

                          <GroupBox Grid.Row='0' Grid.Column='1' Header='Rendered Preview Detail' Margin='0,0,0,8'>
                            <TextBox Name='ConnectorRenderedPreviewText' Margin='8' MinHeight='140' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
                          </GroupBox>

                          <GroupBox Grid.Row='1' Grid.Column='0' Header='Filters (secondary)' Margin='0,0,8,0'>
                            <Grid Margin='8'>
                              <Grid.ColumnDefinitions>
                                <ColumnDefinition Width='230'/>
                                <ColumnDefinition Width='*'/>
                                <ColumnDefinition Width='Auto'/>
                              </Grid.ColumnDefinitions>
                              <ListBox Name='ConnectorProjectionFiltersList' Grid.Column='0' Margin='0,0,8,0' MinHeight='120'/>
                              <Grid Grid.Column='1' Margin='0,0,8,0'>
                                <Grid.RowDefinitions>
                                  <RowDefinition Height='Auto'/>
                                  <RowDefinition Height='Auto'/>
                                </Grid.RowDefinitions>
                                <Grid.ColumnDefinitions>
                                  <ColumnDefinition Width='75'/>
                                  <ColumnDefinition Width='*'/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Field</TextBlock>
                                <ComboBox Name='ConnectorFilterFieldCombo' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8' IsEditable='True'/>
                                <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,0' VerticalAlignment='Center'>Equals</TextBlock>
                                <TextBox Name='ConnectorFilterEqualsText' Grid.Row='1' Grid.Column='1'/>
                              </Grid>
                              <StackPanel Grid.Column='2' VerticalAlignment='Top'>
                                <Button Name='ConnectorFilterAddButton' Width='90' Height='30' Margin='0,0,0,8'>Add</Button>
                                <Button Name='ConnectorFilterRemoveButton' Width='90' Height='30'>Remove</Button>
                              </StackPanel>
                            </Grid>
                          </GroupBox>

                          <GroupBox Grid.Row='1' Grid.Column='1' Header='Sort (secondary)'>
                            <Grid Margin='8'>
                              <Grid.ColumnDefinitions>
                                <ColumnDefinition Width='230'/>
                                <ColumnDefinition Width='*'/>
                                <ColumnDefinition Width='Auto'/>
                              </Grid.ColumnDefinitions>
                              <ListBox Name='ConnectorProjectionSortList' Grid.Column='0' Margin='0,0,8,0' MinHeight='120'/>
                              <Grid Grid.Column='1' Margin='0,0,8,0'>
                                <Grid.RowDefinitions>
                                  <RowDefinition Height='Auto'/>
                                  <RowDefinition Height='Auto'/>
                                </Grid.RowDefinitions>
                                <Grid.ColumnDefinitions>
                                  <ColumnDefinition Width='75'/>
                                  <ColumnDefinition Width='*'/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Row='0' Grid.Column='0' Margin='0,0,8,8' VerticalAlignment='Center'>Field</TextBlock>
                                <ComboBox Name='ConnectorSortByCombo' Grid.Row='0' Grid.Column='1' Margin='0,0,0,8' IsEditable='True'/>
                                <TextBlock Grid.Row='1' Grid.Column='0' Margin='0,0,8,0' VerticalAlignment='Center'>Direction</TextBlock>
                                <ComboBox Name='ConnectorSortDirectionCombo' Grid.Row='1' Grid.Column='1' SelectedIndex='0'>
                                  <ComboBoxItem>asc</ComboBoxItem>
                                  <ComboBoxItem>desc</ComboBoxItem>
                                </ComboBox>
                              </Grid>
                              <StackPanel Grid.Column='2' VerticalAlignment='Top'>
                                <Button Name='ConnectorSortAddButton' Width='90' Height='30' Margin='0,0,0,8'>Add</Button>
                                <Button Name='ConnectorSortRemoveButton' Width='90' Height='30' Margin='0,0,0,8'>Remove</Button>
                                <Button Name='ConnectorSortUpButton' Width='90' Height='30' Margin='0,0,0,8'>Move up</Button>
                                <Button Name='ConnectorSortDownButton' Width='90' Height='30'>Move down</Button>
                              </StackPanel>
                            </Grid>
                          </GroupBox>
                        </Grid>
                      </Expander>
                    </Grid>
                  </ScrollViewer>
                </Expander>
              </Grid>
            </TabItem>

            <TabItem Header='Changes'>
              <TextBox Name='MappingChangesText' Margin='8' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
            </TabItem>
          </TabControl>
        </Grid>
      </TabItem>

      <TabItem Name='RichViewsTab' Header='Rich Views' Visibility='Collapsed'>
        <Grid Margin='12'>
          <Grid.RowDefinitions>
            <RowDefinition Height='Auto'/>
            <RowDefinition Height='*'/>
          </Grid.RowDefinitions>
          <TextBlock Name='WebViewStatusText' Grid.Row='0' Margin='0,0,0,8' TextWrapping='Wrap'>Preparing WebView2 rich views.</TextBlock>
          <Grid Name='WebViewHostGrid' Grid.Row='1'>
            <TextBox Name='WebViewFallbackText' IsReadOnly='True' TextWrapping='Wrap' AcceptsReturn='True' VerticalScrollBarVisibility='Auto'/>
          </Grid>
        </Grid>
      </TabItem>
    </TabControl>

    <Border Grid.Row='0'
            HorizontalAlignment='Right'
            VerticalAlignment='Top'
            Margin='0,0,4,8'
            Background='#CCFFFFFF'
            CornerRadius='4'
            Padding='8,5,8,5'
            Panel.ZIndex='10'
            IsHitTestVisible='False'>
      <StackPanel Orientation='Vertical' MaxWidth='280'>
        <Image Name='BrandLogoImage'
               Width='112'
               MaxHeight='36'
               Stretch='Uniform'
               StretchDirection='Both'
               SnapsToDevicePixels='True'
               HorizontalAlignment='Right'/>
        <TextBlock Margin='0,3,0,0'
                   Text='Professional Services AsBuilt Document Creation Toolset'
                   FontSize='10'
                   TextWrapping='Wrap'
                   TextAlignment='Right'
                   Foreground='#FF1F1F1F'/>
      </StackPanel>
    </Border>

  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$bundleInputModeCombo = $window.FindName('BundleInputModeCombo')
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
$docVersionText = $window.FindName('DocVersionText')
$docConfigSnapDateText = $window.FindName('DocConfigSnapDateText')
$docReferenceIdText = $window.FindName('DocReferenceIdText')
$docClassificationText = $window.FindName('DocClassificationText')
$coverKeyImage = $window.FindName('CoverKeyImage')
$headFootKeyImage = $window.FindName('HeadFootKeyImage')
$brandLogoImage = $window.FindName('BrandLogoImage')

Set-WpfImageSourceFromFile -ImageControl $brandLogoImage -Path (Join-Path $PSScriptRoot 'internal/lenovo-logo.png')
Set-WpfImageSourceFromFile -ImageControl $coverKeyImage -Path (Join-Path $PSScriptRoot 'internal/CoverKey.png')
Set-WpfImageSourceFromFile -ImageControl $headFootKeyImage -Path (Join-Path $PSScriptRoot 'internal/HeadFootKey.png')

$techIdText = $window.FindName('TechIdText')
$entryIdText = $window.FindName('EntryIdText')
$bundleBrowseButton = $window.FindName('BundleBrowseButton')
$catalogBrowseButton = $window.FindName('CatalogBrowseButton')
$outputBrowseButton = $window.FindName('OutputBrowseButton')
$contractsBrowseButton = $window.FindName('ContractsBrowseButton')
$runButton = $window.FindName('RunButton')
$cancelButton = $window.FindName('CancelButton')
$statusText = $window.FindName('StatusText')
$verboseCheckBox = $window.FindName('VerboseCheckBox')
$debugCheckBox = $window.FindName('DebugCheckBox')
$docxCheckBox = $window.FindName('DocxCheckBox')
$txtCheckBox = $window.FindName('TxtCheckBox')
$annotateCheckBox = $window.FindName('AnnotateCheckBox')
$docxMatchModeCombo = $window.FindName('DocxMatchModeCombo')
$unresolvedTokenPolicyCombo = $window.FindName('UnresolvedTokenPolicyCombo')
$outputText = $window.FindName('OutputText')
$progressText = $window.FindName('ProgressText')
$richViewsTab = $window.FindName('RichViewsTab')
$webViewHostGrid = $window.FindName('WebViewHostGrid')
$webViewFallbackText = $window.FindName('WebViewFallbackText')
$webViewStatusText = $window.FindName('WebViewStatusText')
$mappingCollectionCombo = $window.FindName('MappingCollectionCombo')
$mappingRefreshButton = $window.FindName('MappingRefreshButton')
$mappingSaveButton = $window.FindName('MappingSaveButton')
$mappingClearChangesButton = $window.FindName('MappingClearChangesButton')
$mappingModeText = $window.FindName('MappingModeText')
$mappingStudioTabs = $window.FindName('MappingStudioTabs')
$mappingOverviewText = $window.FindName('MappingOverviewText')
$mappingDatasetsList = $window.FindName('MappingDatasetsList')
$mappingDatasetDetailText = $window.FindName('MappingDatasetDetailText')
$mappingTargetsList = $window.FindName('MappingTargetsList')
$mappingTargetDetailText = $window.FindName('MappingTargetDetailText')
$connectorSearchTextBox = $window.FindName('ConnectorSearchTextBox')
$connectorQuickFilterCombo = $window.FindName('ConnectorQuickFilterCombo')
$connectorConnectionSummaryText = $window.FindName('ConnectorConnectionSummaryText')
$connectorConnectionList = $window.FindName('ConnectorConnectionList')
$connectorDetailText = $window.FindName('ConnectorDetailText')
$connectorEditButton = $window.FindName('ConnectorEditButton')
$connectorReplaceButton = $window.FindName('ConnectorReplaceButton')
$connectorNewButton = $window.FindName('ConnectorNewButton')
$connectorOpenDatasetButton = $window.FindName('ConnectorOpenDatasetButton')
$connectorOpenTargetButton = $window.FindName('ConnectorOpenTargetButton')
$connectorAuthoringExpander = $window.FindName('ConnectorAuthoringExpander')
$connectorDatasetList = $window.FindName('ConnectorDatasetList')
$connectorTargetList = $window.FindName('ConnectorTargetList')
$connectorActionText = $window.FindName('ConnectorActionText')
$connectorRenderAsCombo = $window.FindName('ConnectorRenderAsCombo')
$connectorSelectorCombo = $window.FindName('ConnectorSelectorCombo')
$connectorSourceFieldsText = $window.FindName('ConnectorSourceFieldsText')
$connectorProjectionRefText = $window.FindName('ConnectorProjectionRefText')
$connectorProjectionColumnsList = $window.FindName('ConnectorProjectionColumnsList')
$connectorColumnNameText = $window.FindName('ConnectorColumnNameText')
$connectorColumnSourceCombo = $window.FindName('ConnectorColumnSourceCombo')
$connectorColumnFormatText = $window.FindName('ConnectorColumnFormatText')
$connectorColumnDelimiterText = $window.FindName('ConnectorColumnDelimiterText')
$connectorColumnAddButton = $window.FindName('ConnectorColumnAddButton')
$connectorColumnRemoveButton = $window.FindName('ConnectorColumnRemoveButton')
$connectorColumnUpButton = $window.FindName('ConnectorColumnUpButton')
$connectorColumnDownButton = $window.FindName('ConnectorColumnDownButton')
$connectorProjectionFiltersList = $window.FindName('ConnectorProjectionFiltersList')
$connectorFilterFieldCombo = $window.FindName('ConnectorFilterFieldCombo')
$connectorFilterEqualsText = $window.FindName('ConnectorFilterEqualsText')
$connectorFilterAddButton = $window.FindName('ConnectorFilterAddButton')
$connectorFilterRemoveButton = $window.FindName('ConnectorFilterRemoveButton')
$connectorProjectionSortList = $window.FindName('ConnectorProjectionSortList')
$connectorSortByCombo = $window.FindName('ConnectorSortByCombo')
$connectorSortDirectionCombo = $window.FindName('ConnectorSortDirectionCombo')
$connectorSortAddButton = $window.FindName('ConnectorSortAddButton')
$connectorSortRemoveButton = $window.FindName('ConnectorSortRemoveButton')
$connectorSortUpButton = $window.FindName('ConnectorSortUpButton')
$connectorSortDownButton = $window.FindName('ConnectorSortDownButton')
$connectorViewText = $window.FindName('ConnectorViewText')
$connectorRequiredCheckBox = $window.FindName('ConnectorRequiredCheckBox')
$connectorPreviewButton = $window.FindName('ConnectorPreviewButton')
$connectorQueueButton = $window.FindName('ConnectorQueueButton')
$connectorResetButton = $window.FindName('ConnectorResetButton')
$connectorAuthoringHintText = $window.FindName('ConnectorAuthoringHintText')
$connectorSourcePreviewText = $window.FindName('ConnectorSourcePreviewText')
$connectorRenderedGridStatusText = $window.FindName('ConnectorRenderedGridStatusText')
$connectorRenderedPreviewGrid = $window.FindName('ConnectorRenderedPreviewGrid')
$connectorRenderedPreviewText = $window.FindName('ConnectorRenderedPreviewText')
$connectorPreviewText = $window.FindName('ConnectorPreviewText')
$mappingChangesText = $window.FindName('MappingChangesText')

if (-not [string]::IsNullOrWhiteSpace($BundleArchivePath)) {
    $bundleInputModeCombo.SelectedIndex = 1
    $bundleRootText.Text = $BundleArchivePath
}
else {
    $bundleInputModeCombo.SelectedIndex = 0
    $bundleRootText.Text = $BundleRoot
}
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
$docVersionText.Text = $DocVersion
$docConfigSnapDateText.Text = $DocConfigSnapDate
$docReferenceIdText.Text = $DocReferenceId
$docClassificationText.Text = $DocClassification
$techIdText.Text = (($TechId ?? @()) -join ',')
$entryIdText.Text = (($EntryId ?? @()) -join ',')
$docxCheckBox.IsChecked = $true
$docxCheckBox.IsEnabled = $false
$txtCheckBox.IsChecked = $false
$txtCheckBox.IsEnabled = $false
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
$connectorRenderAsCombo.SelectedIndex = 0
$mappingCollectionCombo.DisplayMemberPath = 'Label'
$mappingDatasetsList.DisplayMemberPath = 'Label'
$mappingTargetsList.DisplayMemberPath = 'Label'
$connectorDatasetList.DisplayMemberPath = 'Label'
$connectorTargetList.DisplayMemberPath = 'Label'
$connectorProjectionColumnsList.DisplayMemberPath = 'Label'
$connectorProjectionFiltersList.DisplayMemberPath = 'Label'
$connectorProjectionSortList.DisplayMemberPath = 'Label'

$documentPropertyState = [ordered]@{
    LastAutoConfigSnapDate = ''
}

$renderProcessState = [ordered]@{
    Current = $null
    Timer = $null
    LastProgressCount = 0
}

$webViewState = [ordered]@{
    Control = $null
    Ready = $false
    LastReportPath = ''
    AssetPath = ''
}

function ConvertTo-WebViewJson {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 40 -Compress)
}

function Send-WebViewMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $false)]$Payload = $null,
        [Parameter(Mandatory = $false)][string]$Id = ''
    )

    if (-not [bool]$webViewState.Ready -or $null -eq $webViewState.Control -or $null -eq $webViewState.Control.CoreWebView2) {
        return
    }

    $message = [ordered]@{
        id = if ([string]::IsNullOrWhiteSpace($Id)) { $null } else { $Id }
        ok = $true
        type = $Type
        payload = $Payload
        error = $null
    }
    $webViewState.Control.CoreWebView2.PostWebMessageAsJson((ConvertTo-WebViewJson -Value $message))
}

function Get-CurrentWebViewAllowedRoots {
    $webViewBundleRoot = if ((Get-SelectedBundleInputMode) -eq 'Archive') { Join-Path $repoRoot 'bundle' } else { $bundleRootText.Text }
    return @(New-AssemblerWebViewBridgeRoots -RepoRoot $repoRoot -BundleRoot $webViewBundleRoot -OutputRoot $outputRootText.Text -ContractsRoot $contractsRootText.Text)
}

function New-CurrentWebViewMappingStudioState {
    $resolvedMappingsRoot = Join-Path $outputRootText.Text '.resolved-mappings'
    $reportPath = if (-not [string]::IsNullOrWhiteSpace([string]$webViewState.LastReportPath)) {
        [string]$webViewState.LastReportPath
    }
    else {
        Join-Path $outputRootText.Text 'render-report.json'
    }

    return New-AssemblerWebViewMappingStudioState -Workbench $mappingStudioState.Workbench -ResolvedMappingsRoot $resolvedMappingsRoot -RenderReportPath $reportPath -Status ([string]$statusText.Text)
}

function Publish-WebViewMappingStudioState {
    if (-not [bool]$webViewState.Ready) { return }
    Send-WebViewMessage -Type 'MappingStudioState' -Payload (New-CurrentWebViewMappingStudioState)
}

function Add-ProgressLine {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ([string]::IsNullOrWhiteSpace($progressText.Text)) {
        $progressText.Text = $Text
    }
    else {
        $progressText.AppendText([Environment]::NewLine + $Text)
    }
    $progressText.ScrollToEnd()
}

function Get-SelectedBundleInputMode {
    if ($null -eq $bundleInputModeCombo -or $null -eq $bundleInputModeCombo.SelectedItem) {
        return 'Folder'
    }

    $mode = [string]$bundleInputModeCombo.SelectedItem.Content
    if ([string]::Equals($mode, 'Archive', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Archive'
    }

    return 'Folder'
}

function Start-RenderFromCurrentInputs {
    if ($null -ne $renderProcessState.Current) {
        return [ordered]@{ accepted = $false; reason = 'Render already running.' }
    }

    Update-DocumentPropertyDefaultsFromBundle
    $statusText.Text = 'Starting render process...'
    $outputText.Text = ''
    $progressText.Text = ''
    $techSelection = @($techIdText.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $entrySelection = @($entryIdText.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $docxModeSelection = [string]$docxMatchModeCombo.SelectedItem.Content
    $unresolvedTokenPolicySelection = [string]$unresolvedTokenPolicyCombo.SelectedItem.Content
    $outputTypes = @()
    if ([bool]$docxCheckBox.IsChecked) { $outputTypes += 'docx' }
    if ([bool]$txtCheckBox.IsChecked) { $outputTypes += 'text' }

    $bundleInvocationParams = @{
        RepoRoot = $repoRoot
        CatalogPath = $catalogPathText.Text
        OutputRoot = $outputRootText.Text
        ContractsRoot = $contractsRootText.Text
        TechId = $techSelection
        EntryId = $entrySelection
        OutputType = $outputTypes
        DocTitle = $docTitleText.Text
        DocCustomer = $docCustomerText.Text
        DocCustomerAbbr = $docCustomerAbbrText.Text
        DocLocation = $docLocationText.Text
        DocSubsidiary = $docSubsidiaryText.Text
        DocEnvironment = $docEnvironmentText.Text
        DocDocumentReference = $docDocumentReferenceText.Text
        DocVersion = $docVersionText.Text
        DocConfigSnapDate = $docConfigSnapDateText.Text
        DocReferenceId = $docReferenceIdText.Text
        DocClassification = $docClassificationText.Text
        AnnotateResolvedTags = ([bool]$annotateCheckBox.IsChecked)
        DocxMatchMode = $docxModeSelection
        UnresolvedTokenPolicy = $unresolvedTokenPolicySelection
    }
    if ((Get-SelectedBundleInputMode) -eq 'Archive') {
        $bundleInvocationParams.BundleArchivePath = $bundleRootText.Text
    }
    else {
        $bundleInvocationParams.BundleRoot = $bundleRootText.Text
    }

    $invocation = New-AssemblerGuiRenderInvocation @bundleInvocationParams
    $renderProcessState.Current = Start-AssemblerGuiRenderProcess -Invocation $invocation
    $renderProcessState.LastProgressCount = 0
    $webViewState.LastReportPath = [string]$invocation.ReportPath
    $runButton.IsEnabled = $false
    $cancelButton.IsEnabled = $true
    $statusText.Text = 'Render running out-of-process...'
    Add-ProgressLine -Text "Started: pwsh $($invocation.Arguments -join ' ')"
    $renderProcessState.Timer.Start()
    Publish-WebViewMappingStudioState

    return [ordered]@{
        accepted = $true
        outputRoot = [string]$outputRootText.Text
        progressPath = [string]$invocation.ProgressPath
        reportPath = [string]$invocation.ReportPath
    }
}

function Update-RenderProgressFromFile {
    if ($null -eq $renderProcessState.Current) { return }

    $events = @(Read-AssemblerGuiProgressEvents -Path ([string]$renderProcessState.Current.Invocation.ProgressPath))
    if ($events.Count -le [int]$renderProcessState.LastProgressCount) { return }

    foreach ($event in @($events | Select-Object -Skip ([int]$renderProcessState.LastProgressCount))) {
        $statusText.Text = "$($event.stage): $($event.message)"
        Add-ProgressLine -Text ("{0,3}% [{1}] {2}" -f [int]$event.percent, [string]$event.stage, [string]$event.message)
        Send-WebViewMessage -Type 'ProgressEvent' -Payload $event
    }
    $renderProcessState.LastProgressCount = $events.Count
}

function Complete-RenderProcessIfFinished {
    if ($null -eq $renderProcessState.Current) { return }
    $process = $renderProcessState.Current.Process
    if ($null -eq $process -or -not $process.HasExited) { return }

    if ($null -ne $renderProcessState.Timer) {
        $renderProcessState.Timer.Stop()
    }

    Update-RenderProgressFromFile
    $wrapperReport = Get-AssemblerGuiWrapperReport -Path ([string]$renderProcessState.Current.Invocation.ReportPath)
    $wrapperStdout = [string]$renderProcessState.Current.StdoutTask.GetAwaiter().GetResult()
    $wrapperStderr = [string]$renderProcessState.Current.StderrTask.GetAwaiter().GetResult()
    $backendJson = Get-AssemblerGuiBackendReportJson -WrapperReport $wrapperReport -FallbackJson $wrapperStdout
    if ([string]::IsNullOrWhiteSpace($backendJson) -and $null -ne $wrapperReport) {
        $backendJson = $wrapperReport | ConvertTo-Json -Depth 20
    }
    $webViewState.LastReportPath = [string]$renderProcessState.Current.Invocation.ReportPath

    if ([int]$process.ExitCode -eq 0) {
        $statusText.Text = 'Render completed successfully.'
        $outputText.Text = if ($debugCheckBox.IsChecked) {
            Format-DebugBundleOutput -BundleResultJson $backendJson
        }
        elseif ($verboseCheckBox.IsChecked) {
            Format-VerboseFindingsOutput -BundleResultJson $backendJson
        }
        else {
            Format-RenderFindingsSummary -BundleResultJson $backendJson
        }
    }
    elseif ([int]$process.ExitCode -eq 130) {
        $statusText.Text = 'Render cancelled.'
        $outputText.Text = if ($null -ne $wrapperReport) { $wrapperReport | ConvertTo-Json -Depth 20 } else { $wrapperStderr }
    }
    else {
        $statusText.Text = "Render failed (exit code $([int]$process.ExitCode))."
        $outputText.Text = @(
            'Wrapper stdout:'
            $wrapperStdout
            ''
            'Wrapper stderr:'
            $wrapperStderr
        ) -join [Environment]::NewLine
    }

    $runButton.IsEnabled = $true
    $cancelButton.IsEnabled = $false
    $renderProcessState.Current = $null
    $renderProcessState.LastProgressCount = 0
    Send-WebViewMessage -Type 'RenderReport' -Payload $wrapperReport
    Publish-WebViewMappingStudioState
}

function Initialize-RenderProgressTimer {
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        try {
            Update-RenderProgressFromFile
            Complete-RenderProcessIfFinished
        }
        catch {
            $statusText.Text = "Progress polling failed: $($_.Exception.Message)"
        }
    })
    $renderProcessState.Timer = $timer
}

function Initialize-WebViewHost {
    $webViewPath = Join-Path $PSScriptRoot 'webview/index.html'
    $webViewState.AssetPath = [string]$webViewPath
    $bootstrap = Get-AssemblerWebView2BootstrapStatus -RepoRoot $repoRoot
    $webViewFallbackText.Text = @(
        [string]$bootstrap.message
        ''
        "Static asset: $webViewPath"
        ''
        'Run scripts/Restore-WebView2Dependency.ps1 to restore the WebView2 SDK assembly.'
        'Install Microsoft Edge WebView2 Runtime if the runtime is missing.'
        ''
        'The existing native Mapping Studio tab remains available.'
    ) -join [Environment]::NewLine

    $richViewsTab.Visibility = [System.Windows.Visibility]::Collapsed
    $webViewState.Ready = $false
    $webViewState.Control = $null

    if (-not (Test-Path -LiteralPath $webViewPath -PathType Leaf)) {
        $webViewStatusText.Text = 'WebView2 assets are missing.'
        return
    }
    if (-not [bool]$bootstrap.available) {
        $webViewStatusText.Text = [string]$bootstrap.message
        return
    }

    try {
        $loaderDirectory = Split-Path -Parent ([string]$bootstrap.loaderPath)
        if (-not ([string]$env:PATH).Split([System.IO.Path]::PathSeparator) -contains $loaderDirectory) {
            $env:PATH = $loaderDirectory + [System.IO.Path]::PathSeparator + $env:PATH
        }
        $coreAssemblyPath = Join-Path (Split-Path -Parent ([string]$bootstrap.assemblyPath)) 'Microsoft.Web.WebView2.Core.dll'
        if (Test-Path -LiteralPath $coreAssemblyPath -PathType Leaf) {
            Add-Type -Path $coreAssemblyPath -ErrorAction Stop
        }
        Add-Type -Path ([string]$bootstrap.assemblyPath) -ErrorAction Stop
        $webView = [Microsoft.Web.WebView2.Wpf.WebView2]::new()
        $webViewHostGrid.Children.Clear()
        [void]$webViewHostGrid.Children.Add($webView)
        $webViewState.Control = $webView
        $richViewsTab.Visibility = [System.Windows.Visibility]::Visible
        $webViewStatusText.Text = 'Initializing WebView2 rich views...'
        $webView.add_CoreWebView2InitializationCompleted({
            param($sender, $eventArgs)
            if (-not [bool]$eventArgs.IsSuccess) {
                $webViewState.Ready = $false
                $webViewStatusText.Text = "WebView2 rich views unavailable: $($eventArgs.InitializationException.Message)"
                return
            }

            try {
                $sender.CoreWebView2.add_WebMessageReceived({
                    param($messageSender, $messageArgs)
                    try {
                        $callbacks = @{
                            ValidateMapping = {
                                Refresh-MappingStudioWorkbench
                                $state = New-CurrentWebViewMappingStudioState
                                Send-WebViewMessage -Type 'MappingStudioState' -Payload $state
                                return [ordered]@{ status = 'ok'; refreshed = $true }
                            }
                            RunRender = {
                                return (Start-RenderFromCurrentInputs)
                            }
                        }
                        $response = Invoke-AssemblerWebViewCommand -Message $messageArgs.WebMessageAsJson -RepoRoot $repoRoot -AllowedRoots (Get-CurrentWebViewAllowedRoots) -Callbacks $callbacks
                        $messageSender.PostWebMessageAsJson((ConvertTo-WebViewJson -Value $response))
                    }
                    catch {
                        $response = New-AssemblerWebViewResponse -Ok $false -Type 'Error' -Error $_.Exception.Message
                        $messageSender.PostWebMessageAsJson((ConvertTo-WebViewJson -Value $response))
                    }
                })
                $webViewState.Ready = $true
                $webViewStatusText.Text = 'WebView2 rich views loaded.'
                Publish-WebViewMappingStudioState
            }
            catch {
                $webViewState.Ready = $false
                $webViewStatusText.Text = "WebView2 bridge unavailable: $($_.Exception.Message)"
            }
        })
        $webView.add_NavigationCompleted({
            Publish-WebViewMappingStudioState
        })
        $null = $window.Dispatcher.BeginInvoke([Action]{
            if ($null -ne $webViewState.Control -and -not [string]::IsNullOrWhiteSpace([string]$webViewState.AssetPath)) {
                $webViewState.Control.Source = [System.Uri]::new([string]$webViewState.AssetPath, [System.UriKind]::Absolute)
            }
        }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    }
    catch {
        $richViewsTab.Visibility = [System.Windows.Visibility]::Visible
        $webViewState.Ready = $false
        $webViewState.Control = $null
        $webViewStatusText.Text = "WebView2 rich views unavailable: $($_.Exception.Message)"
    }
}

function Resolve-LoadedBundleRoot {
    param([Parameter(Mandatory = $false)][string]$BundleRoot)

    if ([string]::IsNullOrWhiteSpace($BundleRoot)) {
        return ''
    }

    try {
        $resolvedRoot = (Resolve-Path -LiteralPath $BundleRoot -ErrorAction Stop).Path
    }
    catch {
        return ''
    }

    $directManifest = Join-Path $resolvedRoot 'manifest.json'
    $directObjectIndex = Join-Path $resolvedRoot 'objectIndex.json'
    $directSolutionPlan = Join-Path (Join-Path $resolvedRoot 'config') 'solution.plan.json'
    if ((Test-Path -LiteralPath $directManifest -PathType Leaf) -and (Test-Path -LiteralPath $directObjectIndex -PathType Leaf) -and (Test-Path -LiteralPath $directSolutionPlan -PathType Leaf)) {
        return $resolvedRoot
    }

    $bundleCandidates = @(
        Get-ChildItem -LiteralPath $resolvedRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'objectIndex.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'config/solution.plan.json') -PathType Leaf)
            } |
            Sort-Object -Property Name
    )
    if (@($bundleCandidates).Count -eq 1) {
        return [string]$bundleCandidates[0].FullName
    }

    return ''
}

function Convert-BundleTimestampToDisplayDate {
    param([Parameter(Mandatory = $false)]$Timestamp)

    if ($null -eq $Timestamp) {
        return ''
    }

    try {
        if ($Timestamp -is [System.DateTimeOffset]) {
            return $Timestamp.ToLocalTime().ToString('yyyy-MM-dd')
        }
        if ($Timestamp -is [System.DateTime]) {
            return ([System.DateTimeOffset]::new($Timestamp)).ToLocalTime().ToString('yyyy-MM-dd')
        }

        $timestampText = [string]$Timestamp
        if ([string]::IsNullOrWhiteSpace($timestampText)) {
            return ''
        }

        return ([System.DateTimeOffset]::Parse($timestampText)).ToLocalTime().ToString('yyyy-MM-dd')
    }
    catch {
        return ''
    }
}

function Get-BundleSnapshotDateDefault {
    param([Parameter(Mandatory = $false)][string]$BundleRoot)

    $resolvedBundleRoot = Resolve-LoadedBundleRoot -BundleRoot $BundleRoot
    if ([string]::IsNullOrWhiteSpace($resolvedBundleRoot)) {
        return ''
    }

    $datasetsRoot = Join-Path $resolvedBundleRoot 'datasets'
    if (Test-Path -LiteralPath $datasetsRoot -PathType Container) {
        $runSummaryPath = Get-ChildItem -LiteralPath $datasetsRoot -Recurse -Filter 'run_summary.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName |
            Select-Object -First 1
        if ($null -ne $runSummaryPath) {
            try {
                $runSummary = Get-Content -LiteralPath $runSummaryPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                $items = @($runSummary.items)
                if (@($items).Count -gt 0) {
                    $displayDate = Convert-BundleTimestampToDisplayDate -Timestamp $items[0].collectedUtc
                    if (-not [string]::IsNullOrWhiteSpace($displayDate)) {
                        return $displayDate
                    }
                }
            }
            catch {
            }
        }
    }

    $manifestPath = Join-Path $resolvedBundleRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            foreach ($propertyName in @('createdUtc', 'completedUtc')) {
                $displayDate = Convert-BundleTimestampToDisplayDate -Timestamp $manifest[$propertyName]
                if (-not [string]::IsNullOrWhiteSpace($displayDate)) {
                    return $displayDate
                }
            }
        }
        catch {
        }
    }

    return ''
}

function Update-DocumentPropertyDefaultsFromBundle {
    if ((Get-SelectedBundleInputMode) -eq 'Archive') {
        return
    }

    $autoConfigSnapDate = Get-BundleSnapshotDateDefault -BundleRoot $bundleRootText.Text
    $docConfigSnapDateText.Text = $autoConfigSnapDate
    $documentPropertyState.LastAutoConfigSnapDate = [string]$autoConfigSnapDate
}

$mappingStudioState = [ordered]@{
    Collections = @()
    Workbench = $null
    PendingChanges = @()
    IsRefreshing = $false
    ConnectorMode = 'inspect'
    LastConnectorContextKey = ''
    LastConnectorConnectionKey = ''
    SuppressConnectorSelectionEvents = $false
    SuppressProjectionEditorEvents = $false
    DraftProjectionRef = ''
    DraftProjectionColumns = @()
    DraftProjectionFilter = @()
    DraftProjectionRowOrder = @()
    DraftFieldCandidates = @()
    LastConnectorRenderAs = ''
}

function Get-SelectedMappingCollection {
    if ($null -eq $mappingCollectionCombo.SelectedItem) { return $null }
    return $mappingCollectionCombo.SelectedItem
}

function Get-SelectedConnectorRenderAs {
    if ($null -eq $connectorRenderAsCombo.SelectedItem) {
        return 'table'
    }
    return [string]$connectorRenderAsCombo.SelectedItem.Content
}

function Get-SelectedConnectorQuickFilter {
    if ($null -eq $connectorQuickFilterCombo.SelectedItem) {
        return 'All'
    }

    return [string]$connectorQuickFilterCombo.SelectedItem.Content
}

function Get-SelectedConnectorConnection {
    if ($null -eq $connectorConnectionList.SelectedItem) {
        return $null
    }

    return $connectorConnectionList.SelectedItem
}

function Find-ConnectorDatasetNode {
    param([Parameter(Mandatory = $false)][string]$DatasetId)

    if ([string]::IsNullOrWhiteSpace($DatasetId)) {
        return $null
    }

    foreach ($item in @($connectorDatasetList.ItemsSource)) {
        if ([string]$item.DatasetId -eq $DatasetId) {
            return $item
        }
    }

    return $null
}

function Find-ConnectorTargetNode {
    param([Parameter(Mandatory = $false)][string]$TargetPath)

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return $null
    }

    foreach ($item in @($connectorTargetList.ItemsSource)) {
        if ([string]$item.TargetPath -eq $TargetPath) {
            return $item
        }
    }

    return $null
}

function Set-ConnectorDraftSelection {
    param(
        [Parameter(Mandatory = $false)][string]$DatasetId,
        [Parameter(Mandatory = $false)][string]$TargetPath,
        [Parameter(Mandatory = $false)][bool]$PreserveExistingDataset = $false
    )

    $mappingStudioState.SuppressConnectorSelectionEvents = $true
    try {
        if (-not $PreserveExistingDataset -or $null -eq $connectorDatasetList.SelectedItem) {
            $datasetNode = Find-ConnectorDatasetNode -DatasetId $DatasetId
            if ($null -ne $datasetNode) {
                $connectorDatasetList.SelectedItem = $datasetNode
            }
        }

        $targetNode = Find-ConnectorTargetNode -TargetPath $TargetPath
        if ($null -ne $targetNode) {
            $connectorTargetList.SelectedItem = $targetNode
        }
    }
    finally {
        $mappingStudioState.SuppressConnectorSelectionEvents = $false
    }
}

function New-ConnectorColumnDraft {
    return [pscustomobject]@{
        Id = ([guid]::NewGuid()).Guid
        Name = ''
        Source = ''
        Format = ''
        Delimiter = ''
        Label = 'New column'
    }
}

function New-ConnectorFilterDraft {
    return [pscustomobject]@{
        Id = ([guid]::NewGuid()).Guid
        Field = ''
        Equals = ''
        Label = 'New filter'
    }
}

function New-ConnectorSortDraft {
    return [pscustomobject]@{
        Id = ([guid]::NewGuid()).Guid
        By = ''
        Direction = 'asc'
        Label = 'New sort'
    }
}

function Update-ConnectorColumnDraftLabel {
    param([Parameter(Mandatory = $true)]$ColumnDraft)

    $header = if ([string]::IsNullOrWhiteSpace([string]$ColumnDraft.Name)) { '(header)' } else { [string]$ColumnDraft.Name }
    $source = if ([string]::IsNullOrWhiteSpace([string]$ColumnDraft.Source)) { '(field)' } else { [string]$ColumnDraft.Source }
    $ColumnDraft.Label = "$header <- $source"
}

function Update-ConnectorFilterDraftLabel {
    param([Parameter(Mandatory = $true)]$FilterDraft)

    $field = if ([string]::IsNullOrWhiteSpace([string]$FilterDraft.Field)) { '(field)' } else { [string]$FilterDraft.Field }
    $FilterDraft.Label = "{0} = {1}" -f $field, [string]$FilterDraft.Equals
}

function Update-ConnectorSortDraftLabel {
    param([Parameter(Mandatory = $true)]$SortDraft)

    $field = if ([string]::IsNullOrWhiteSpace([string]$SortDraft.By)) { '(field)' } else { [string]$SortDraft.By }
    $direction = if ([string]::IsNullOrWhiteSpace([string]$SortDraft.Direction)) { 'asc' } else { [string]$SortDraft.Direction }
    $SortDraft.Label = "{0} ({1})" -f $field, $direction
}

function Get-SelectedConnectorProjectionColumn {
    return $connectorProjectionColumnsList.SelectedItem
}

function Get-SelectedConnectorProjectionFilter {
    return $connectorProjectionFiltersList.SelectedItem
}

function Get-SelectedConnectorProjectionSort {
    return $connectorProjectionSortList.SelectedItem
}

function Apply-ConnectorFieldCandidateSources {
    $fieldCandidates = @($mappingStudioState.DraftFieldCandidates)
    $connectorColumnSourceCombo.ItemsSource = $fieldCandidates
    $connectorFilterFieldCombo.ItemsSource = $fieldCandidates
    $connectorSortByCombo.ItemsSource = $fieldCandidates
    $connectorSourceFieldsText.Text = if (@($fieldCandidates).Count -gt 0) {
        "Available row fields: $($fieldCandidates -join ', ')"
    }
    else {
        'Available row fields will appear once a selector resolves example rows.'
    }
}

function Refresh-ConnectorProjectionLists {
    $selectedColumnId = if ($null -ne $connectorProjectionColumnsList.SelectedItem) { [string]$connectorProjectionColumnsList.SelectedItem.Id } else { '' }
    $selectedFilterId = if ($null -ne $connectorProjectionFiltersList.SelectedItem) { [string]$connectorProjectionFiltersList.SelectedItem.Id } else { '' }
    $selectedSortId = if ($null -ne $connectorProjectionSortList.SelectedItem) { [string]$connectorProjectionSortList.SelectedItem.Id } else { '' }

    $mappingStudioState.SuppressProjectionEditorEvents = $true
    try {
        $connectorProjectionColumnsList.ItemsSource = @($mappingStudioState.DraftProjectionColumns)
        $connectorProjectionFiltersList.ItemsSource = @($mappingStudioState.DraftProjectionFilter)
        $connectorProjectionSortList.ItemsSource = @($mappingStudioState.DraftProjectionRowOrder)

        if (-not [string]::IsNullOrWhiteSpace($selectedColumnId)) {
            $connectorProjectionColumnsList.SelectedItem = $mappingStudioState.DraftProjectionColumns | Where-Object { [string]$_.Id -eq $selectedColumnId } | Select-Object -First 1
        }
        if ($null -eq $connectorProjectionColumnsList.SelectedItem -and $connectorProjectionColumnsList.Items.Count -gt 0) {
            $connectorProjectionColumnsList.SelectedIndex = 0
        }

        if (-not [string]::IsNullOrWhiteSpace($selectedFilterId)) {
            $connectorProjectionFiltersList.SelectedItem = $mappingStudioState.DraftProjectionFilter | Where-Object { [string]$_.Id -eq $selectedFilterId } | Select-Object -First 1
        }
        if ($null -eq $connectorProjectionFiltersList.SelectedItem -and $connectorProjectionFiltersList.Items.Count -gt 0) {
            $connectorProjectionFiltersList.SelectedIndex = 0
        }

        if (-not [string]::IsNullOrWhiteSpace($selectedSortId)) {
            $connectorProjectionSortList.SelectedItem = $mappingStudioState.DraftProjectionRowOrder | Where-Object { [string]$_.Id -eq $selectedSortId } | Select-Object -First 1
        }
        if ($null -eq $connectorProjectionSortList.SelectedItem -and $connectorProjectionSortList.Items.Count -gt 0) {
            $connectorProjectionSortList.SelectedIndex = 0
        }
    }
    finally {
        $mappingStudioState.SuppressProjectionEditorEvents = $false
    }
}

function Update-ConnectorProjectionSelectionDetails {
    $mappingStudioState.SuppressProjectionEditorEvents = $true
    try {
        $connectorProjectionRefText.Text = [string]$mappingStudioState.DraftProjectionRef

        $selectedColumn = Get-SelectedConnectorProjectionColumn
        $connectorColumnNameText.Text = if ($null -ne $selectedColumn) { [string]$selectedColumn.Name } else { '' }
        $connectorColumnSourceCombo.Text = if ($null -ne $selectedColumn) { [string]$selectedColumn.Source } else { '' }
        $connectorColumnFormatText.Text = if ($null -ne $selectedColumn) { [string]$selectedColumn.Format } else { '' }
        $connectorColumnDelimiterText.Text = if ($null -ne $selectedColumn) { [string]$selectedColumn.Delimiter } else { '' }

        $selectedFilter = Get-SelectedConnectorProjectionFilter
        $connectorFilterFieldCombo.Text = if ($null -ne $selectedFilter) { [string]$selectedFilter.Field } else { '' }
        $connectorFilterEqualsText.Text = if ($null -ne $selectedFilter) { [string]$selectedFilter.Equals } else { '' }

        $selectedSort = Get-SelectedConnectorProjectionSort
        $connectorSortByCombo.Text = if ($null -ne $selectedSort) { [string]$selectedSort.By } else { '' }
        $sortDirection = if ($null -ne $selectedSort -and -not [string]::IsNullOrWhiteSpace([string]$selectedSort.Direction)) { [string]$selectedSort.Direction } else { 'asc' }
        $connectorSortDirectionCombo.SelectedIndex = if ($sortDirection -eq 'desc') { 1 } else { 0 }
    }
    finally {
        $mappingStudioState.SuppressProjectionEditorEvents = $false
    }

    $isTableDraft = ([string]$mappingStudioState.ConnectorMode -ne 'inspect') -and ((Get-SelectedConnectorRenderAs) -eq 'table')
    $connectorProjectionRefText.IsEnabled = $isTableDraft
    $connectorProjectionColumnsList.IsEnabled = $isTableDraft
    $connectorColumnNameText.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionColumn)
    $connectorColumnSourceCombo.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionColumn)
    $connectorColumnFormatText.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionColumn)
    $connectorColumnDelimiterText.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionColumn)
    $connectorColumnAddButton.IsEnabled = $isTableDraft
    $connectorColumnRemoveButton.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionColumn)
    $connectorColumnUpButton.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionColumn)
    $connectorColumnDownButton.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionColumn)
    $connectorProjectionFiltersList.IsEnabled = $isTableDraft
    $connectorFilterFieldCombo.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionFilter)
    $connectorFilterEqualsText.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionFilter)
    $connectorFilterAddButton.IsEnabled = $isTableDraft
    $connectorFilterRemoveButton.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionFilter)
    $connectorProjectionSortList.IsEnabled = $isTableDraft
    $connectorSortByCombo.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionSort)
    $connectorSortDirectionCombo.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionSort)
    $connectorSortAddButton.IsEnabled = $isTableDraft
    $connectorSortRemoveButton.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionSort)
    $connectorSortUpButton.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionSort)
    $connectorSortDownButton.IsEnabled = $isTableDraft -and $null -ne (Get-SelectedConnectorProjectionSort)
}

function Clear-ConnectorRenderedPreviewGrid {
    $connectorRenderedPreviewGrid.ItemsSource = $null
    $connectorRenderedPreviewGrid.Columns.Clear()
}

function Set-ConnectorRenderedPreviewGrid {
    param([Parameter(Mandatory = $false)]$Preview)

    $previewTable = if ($null -eq $Preview) { $null } else { $Preview }
    if ($null -eq $previewTable) {
        $connectorRenderedGridStatusText.Text = ''
        Clear-ConnectorRenderedPreviewGrid
        return
    }

    if ([string]$previewTable.Status -ne 'ok') {
        $connectorRenderedGridStatusText.Text = [string]$previewTable.Message
        Clear-ConnectorRenderedPreviewGrid
        return
    }

    if ([string]$previewTable.RenderAs -eq 'scalar') {
        $connectorRenderedGridStatusText.Text = 'Scalar mappings use the text preview only.'
        Clear-ConnectorRenderedPreviewGrid
        return
    }

    $columnNames = @($previewTable.RenderedGridColumns)
    $gridRows = @($previewTable.RenderedGridRows)
    if (@($columnNames).Count -eq 0 -and @($previewTable.ColumnNames).Count -gt 0) {
        $columnNames = @($previewTable.ColumnNames)
    }

    $connectorRenderedPreviewGrid.Columns.Clear()

    $table = New-Object System.Data.DataTable
    foreach ($columnName in @($columnNames)) {
        $null = $table.Columns.Add([string]$columnName, [string])

        $binding = New-Object System.Windows.Data.Binding
        $binding.Path = "[{0}]" -f [string]$columnName
        $binding.Mode = [System.Windows.Data.BindingMode]::OneWay

        $column = New-Object System.Windows.Controls.DataGridTextColumn
        $column.Header = [string]$columnName
        $column.Binding = $binding
        $column.CanUserSort = $false
        $connectorRenderedPreviewGrid.Columns.Add($column) | Out-Null
    }

    foreach ($row in @($gridRows)) {
        $dataRow = $table.NewRow()
        $rowTable = if ($row -is [System.Collections.IDictionary]) { $row } else { $null }
        foreach ($columnName in @($columnNames)) {
            $value = ''
            if ($null -ne $rowTable -and $rowTable.Contains([string]$columnName)) {
                $value = [string]$rowTable[[string]$columnName]
            }
            $dataRow[[string]$columnName] = $value
        }
        $table.Rows.Add($dataRow)
    }

    $connectorRenderedPreviewGrid.ItemsSource = $table.DefaultView
    if (@($columnNames).Count -eq 0) {
        $connectorRenderedGridStatusText.Text = 'No rendered columns are available for this preview.'
    }
    elseif (@($gridRows).Count -eq 0) {
        $connectorRenderedGridStatusText.Text = 'No sample rows matched the current selector/filter combination.'
    }
    else {
        $connectorRenderedGridStatusText.Text = "Showing $(@($gridRows).Count) rendered sample row(s) across $(@($columnNames).Count) column(s)."
    }
}

function Reset-ConnectorProjectionDraft {
    param(
        [Parameter(Mandatory = $false)]$ExistingMapping,
        [Parameter(Mandatory = $false)]$DatasetNode,
        [Parameter(Mandatory = $false)]$TargetNode
    )

    if ((Get-SelectedConnectorRenderAs) -ne 'table' -or $null -eq $mappingStudioState.Workbench -or $null -eq $DatasetNode -or $null -eq $TargetNode) {
        $mappingStudioState.DraftProjectionRef = ''
        $mappingStudioState.DraftProjectionColumns = @()
        $mappingStudioState.DraftProjectionFilter = @()
        $mappingStudioState.DraftProjectionRowOrder = @()
        Refresh-ConnectorProjectionLists
        Update-ConnectorProjectionSelectionDetails
        return
    }

    $projectionDraft = New-MappingStudioProjectionDraft -Workbench $mappingStudioState.Workbench -ExistingMapping $ExistingMapping -DatasetNode $DatasetNode -TargetNode $TargetNode -RenderAs 'table'
    $mappingStudioState.DraftProjectionRef = [string]$projectionDraft.ProjectionRef
    $mappingStudioState.DraftProjectionColumns = @($projectionDraft.Columns)
    $mappingStudioState.DraftProjectionFilter = @($projectionDraft.Filter)
    $mappingStudioState.DraftProjectionRowOrder = @($projectionDraft.RowOrder)
    Refresh-ConnectorProjectionLists
    Update-ConnectorProjectionSelectionDetails
}

function Move-ConnectorDraftItem {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IList]$Items,
        [Parameter(Mandatory = $true)][string]$ItemId,
        [Parameter(Mandatory = $true)][int]$Direction
    )

    for ($index = 0; $index -lt $Items.Count; $index++) {
        if ([string]$Items[$index].Id -ne $ItemId) {
            continue
        }

        $newIndex = $index + $Direction
        if ($newIndex -lt 0 -or $newIndex -ge $Items.Count) {
            return
        }

        $current = $Items[$index]
        $Items.RemoveAt($index)
        $Items.Insert($newIndex, $current)
        return
    }
}

function Update-MappingStudioInteractionState {
    $hasWorkbench = $null -ne $mappingStudioState.Workbench
    $hasPending = @($mappingStudioState.PendingChanges).Count -gt 0
    $isReadOnly = $hasWorkbench -and [bool]$mappingStudioState.Workbench.MappingDocument.readOnly
    $isAuthoringMode = [string]$mappingStudioState.ConnectorMode -ne 'inspect'
    $hasConnectionSelection = $hasWorkbench -and $null -ne (Get-SelectedConnectorConnection)
    $hasAuthoringSelection = $hasWorkbench -and $isAuthoringMode -and $null -ne $connectorDatasetList.SelectedItem -and $null -ne $connectorTargetList.SelectedItem
    $hasPreviewSource = $hasConnectionSelection -or $hasAuthoringSelection

    $mappingSaveButton.IsEnabled = $hasWorkbench -and $hasPending -and (-not $isReadOnly)
    $mappingClearChangesButton.IsEnabled = $hasPending
    $connectorPreviewButton.IsEnabled = $hasPreviewSource
    $connectorQueueButton.IsEnabled = $hasAuthoringSelection -and (-not $isReadOnly)
    $connectorResetButton.IsEnabled = $hasAuthoringSelection
    $connectorEditButton.IsEnabled = $hasConnectionSelection -and (-not $isReadOnly)
    $connectorReplaceButton.IsEnabled = $hasConnectionSelection -and (-not $isReadOnly)
    $connectorNewButton.IsEnabled = $hasWorkbench -and (-not $isReadOnly)
    $connectorOpenDatasetButton.IsEnabled = $hasConnectionSelection
    $connectorOpenTargetButton.IsEnabled = $hasConnectionSelection
    $connectorAuthoringExpander.IsEnabled = $hasWorkbench -and (-not $isReadOnly) -and $isAuthoringMode
}

function Update-MappingChangesView {
    $mappingChangesText.Text = Format-PendingChangesDetail -PendingChanges $mappingStudioState.PendingChanges
    Update-MappingStudioInteractionState
}

function Update-MappingCollectionChoices {
    try {
        $previousId = if ($null -ne $mappingCollectionCombo.SelectedItem) { [string]$mappingCollectionCombo.SelectedItem.Id } else { '' }
        $collections = @(Get-TemplateCollections -CatalogPath $catalogPathText.Text | Where-Object { [string]$_.OutputType -eq 'docx' })
        $mappingStudioState.Collections = @($collections)
        $mappingCollectionCombo.ItemsSource = @($collections)

        $selected = $null
        if (-not [string]::IsNullOrWhiteSpace($previousId)) {
            $selected = $collections | Where-Object { [string]$_.Id -eq $previousId } | Select-Object -First 1
        }
        if ($null -eq $selected) {
            $selected = $collections | Select-Object -First 1
        }
        $mappingCollectionCombo.SelectedItem = $selected
    }
    catch {
        $mappingStudioState.Collections = @()
        $mappingCollectionCombo.ItemsSource = @()
        $mappingModeText.Text = $_.Exception.Message
    }
}

function Update-MappingDatasetDetail {
    $selected = $mappingDatasetsList.SelectedItem
    if ($null -eq $selected) {
        $mappingDatasetDetailText.Text = 'Select a dataset to inspect its scope, path template, and current mappings.'
        return
    }

    $mappingDatasetDetailText.Text = Format-DatasetNodeDetail -DatasetNode $selected
}

function Update-MappingTargetDetail {
    $selected = $mappingTargetsList.SelectedItem
    if ($null -eq $selected) {
        $mappingTargetDetailText.Text = 'Select a target to inspect placement state and active mappings.'
        return
    }

    $mappingTargetDetailText.Text = Format-TargetNodeDetail -TargetNode $selected
}

function Update-ConnectorConnectionList {
    $workbench = $mappingStudioState.Workbench
    if ($null -eq $workbench) {
        $connectorConnectionSummaryText.Text = ''
        $connectorConnectionList.ItemsSource = @()
        $mappingStudioState.LastConnectorConnectionKey = ''
        return
    }

    $previousConnectionKey = if ($null -ne $connectorConnectionList.SelectedItem) {
        [string]$connectorConnectionList.SelectedItem.ConnectionKey
    }
    else {
        [string]$mappingStudioState.LastConnectorConnectionKey
    }

    $allRows = @($workbench.ConnectionRows)
    $filteredRows = @(Select-MappingStudioConnectionRows -ConnectionRows $allRows -SearchText $connectorSearchTextBox.Text -QuickFilter (Get-SelectedConnectorQuickFilter))
    $connectorConnectionList.ItemsSource = $filteredRows
    $connectorConnectionSummaryText.Text = "Showing $(@($filteredRows).Count) of $(@($allRows).Count) current connections."

    $selectedRow = $null
    if (-not [string]::IsNullOrWhiteSpace($previousConnectionKey)) {
        $selectedRow = $filteredRows | Where-Object { [string]$_.ConnectionKey -eq $previousConnectionKey } | Select-Object -First 1
    }
    if ($null -eq $selectedRow -and @($filteredRows).Count -gt 0) {
        $selectedRow = $filteredRows | Select-Object -First 1
    }

    $connectorConnectionList.SelectedItem = $selectedRow
    $mappingStudioState.LastConnectorConnectionKey = if ($null -ne $selectedRow) { [string]$selectedRow.ConnectionKey } else { '' }
}

function Set-ConnectorAuthoringMode {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $false)]$ConnectionRow = $null
    )

    $workbench = $mappingStudioState.Workbench
    if ($null -eq $workbench) {
        $mappingStudioState.ConnectorMode = 'inspect'
        $mappingStudioState.LastConnectorContextKey = ''
        $connectorAuthoringExpander.Header = 'Create or Rebind (choose an action above)'
        $connectorAuthoringExpander.IsEnabled = $false
        $connectorAuthoringExpander.IsExpanded = $false
        return
    }

    if ($null -eq $ConnectionRow) {
        $ConnectionRow = Get-SelectedConnectorConnection
    }

    if ([bool]$workbench.MappingDocument.readOnly -and $Mode -ne 'inspect') {
        $Mode = 'inspect'
    }

    $mappingStudioState.ConnectorMode = $Mode
    $mappingStudioState.LastConnectorContextKey = ''

    switch ($Mode) {
        'edit-existing' {
            $connectorAuthoringExpander.Header = 'Edit Current Mapping'
            $connectorAuthoringExpander.IsEnabled = $true
            $connectorAuthoringExpander.IsExpanded = $true
            if ($null -ne $ConnectionRow) {
                Set-ConnectorDraftSelection -DatasetId ([string]$ConnectionRow.DatasetId) -TargetPath ([string]$ConnectionRow.TargetPath)
            }
        }
        'replace-target' {
            $connectorAuthoringExpander.Header = 'Replace Target Mapping'
            $connectorAuthoringExpander.IsEnabled = $true
            $connectorAuthoringExpander.IsExpanded = $true
            if ($null -ne $ConnectionRow) {
                Set-ConnectorDraftSelection -DatasetId ([string]$ConnectionRow.DatasetId) -TargetPath ([string]$ConnectionRow.TargetPath) -PreserveExistingDataset:$true
            }
        }
        'new-connection' {
            $connectorAuthoringExpander.Header = 'Create or Rebind Mapping'
            $connectorAuthoringExpander.IsEnabled = $true
            $connectorAuthoringExpander.IsExpanded = $true
            if ($null -eq $connectorDatasetList.SelectedItem -and $connectorDatasetList.Items.Count -gt 0) {
                $connectorDatasetList.SelectedIndex = 0
            }
            if ($null -eq $connectorTargetList.SelectedItem) {
                $preferredTarget = $workbench.Targets | Where-Object { (-not [bool]$_.IsMapped) -or ([string]$_.PlacementGroup -eq 'Available to stage') } | Select-Object -First 1
                if ($null -eq $preferredTarget -and $connectorTargetList.Items.Count -gt 0) {
                    $preferredTarget = $workbench.Targets | Select-Object -First 1
                }
                if ($null -ne $preferredTarget) {
                    $connectorTargetList.SelectedItem = $preferredTarget
                }
            }
        }
        default {
            $connectorAuthoringExpander.Header = 'Create or Rebind (choose an action above)'
            $connectorAuthoringExpander.IsEnabled = $false
            $connectorAuthoringExpander.IsExpanded = $false
        }
    }
}

function Update-ConnectorEditor {
    $workbench = $mappingStudioState.Workbench
    if ($null -eq $workbench) {
        $connectorActionText.Text = 'Refresh Mapping Studio to load datasets, targets, and current mappings.'
        $connectorDetailText.Text = 'Refresh Mapping Studio to load the current connection inventory.'
        $connectorAuthoringHintText.Text = ''
        $connectorSourceFieldsText.Text = ''
        $connectorSourcePreviewText.Text = ''
        $connectorRenderedGridStatusText.Text = ''
        Clear-ConnectorRenderedPreviewGrid
        $connectorRenderedPreviewText.Text = ''
        $connectorPreviewText.Text = ''
        $connectorAuthoringExpander.IsExpanded = $false
        $mappingStudioState.DraftProjectionRef = ''
        $mappingStudioState.DraftProjectionColumns = @()
        $mappingStudioState.DraftProjectionFilter = @()
        $mappingStudioState.DraftProjectionRowOrder = @()
        Update-MappingStudioInteractionState
        return
    }

    $selectedConnection = Get-SelectedConnectorConnection
    if ($null -eq $selectedConnection) {
        if (@($connectorConnectionList.ItemsSource).Count -eq 0 -and @($workbench.ConnectionRows).Count -gt 0) {
            $connectorActionText.Text = 'No current connections match the active filter.'
            $connectorDetailText.Text = 'Adjust the search or filter to inspect the existing dataset-to-target mappings.'
        }
        elseif (@($workbench.ConnectionRows).Count -eq 0) {
            $connectorActionText.Text = 'No current connections were found for the selected collection.'
            $connectorDetailText.Text = 'Use New connection to stage or create the first dataset-to-target mapping for this collection.'
        }
        else {
            $connectorActionText.Text = 'Select a current connection to inspect what is mapped today.'
            $connectorDetailText.Text = 'The inspector shows the dataset, target, mapping type, selector, and example preview for the selected connection.'
        }
    }
    else {
        $connectorActionText.Text = "Viewing current mapping: $($selectedConnection.DatasetId) -> $($selectedConnection.TargetPath)"
        $connectorDetailText.Text = Format-MappingStudioConnectionDetail -ConnectionRow $selectedConnection
        $mappingStudioState.LastConnectorConnectionKey = [string]$selectedConnection.ConnectionKey
    }

    $mode = [string]$mappingStudioState.ConnectorMode
    $datasetNode = $connectorDatasetList.SelectedItem
    $targetNode = $connectorTargetList.SelectedItem
    if ($mode -eq 'edit-existing' -and $null -ne $selectedConnection) {
        if ($null -eq $connectorDatasetList.SelectedItem -or [string]$connectorDatasetList.SelectedItem.DatasetId -ne [string]$selectedConnection.DatasetId -or $null -eq $connectorTargetList.SelectedItem -or [string]$connectorTargetList.SelectedItem.TargetPath -ne [string]$selectedConnection.TargetPath) {
            Set-ConnectorDraftSelection -DatasetId ([string]$selectedConnection.DatasetId) -TargetPath ([string]$selectedConnection.TargetPath)
        }
        $datasetNode = $connectorDatasetList.SelectedItem
        $targetNode = $connectorTargetList.SelectedItem
    }
    elseif ($mode -eq 'replace-target' -and $null -ne $selectedConnection) {
        if ($null -eq $connectorTargetList.SelectedItem -or [string]$connectorTargetList.SelectedItem.TargetPath -ne [string]$selectedConnection.TargetPath) {
            Set-ConnectorDraftSelection -DatasetId ([string]$selectedConnection.DatasetId) -TargetPath ([string]$selectedConnection.TargetPath) -PreserveExistingDataset:$true
        }
        if ($null -eq $connectorDatasetList.SelectedItem) {
            Set-ConnectorDraftSelection -DatasetId ([string]$selectedConnection.DatasetId) -TargetPath ([string]$selectedConnection.TargetPath) -PreserveExistingDataset:$false
        }
        $datasetNode = $connectorDatasetList.SelectedItem
        $targetNode = $connectorTargetList.SelectedItem
    }

    switch ($mode) {
        'edit-existing' {
            $connectorDatasetList.IsEnabled = $false
            $connectorTargetList.IsEnabled = $false
        }
        'replace-target' {
            $connectorDatasetList.IsEnabled = $true
            $connectorTargetList.IsEnabled = $false
        }
        'new-connection' {
            $connectorDatasetList.IsEnabled = $true
            $connectorTargetList.IsEnabled = $true
        }
        default {
            $connectorDatasetList.IsEnabled = $false
            $connectorTargetList.IsEnabled = $false
        }
    }

    if ($mode -eq 'inspect') {
        $connectorAuthoringHintText.Text = 'Choose Edit mapping, Replace target, or New connection to activate the authoring tools.'
        $connectorSourceFieldsText.Text = 'Available row fields appear when authoring a table connection.'
        $connectorSourcePreviewText.Text = 'Open Edit mapping, Replace target, or New connection to inspect selector rows.'
        $connectorRenderedGridStatusText.Text = 'Open Edit mapping, Replace target, or New connection to preview the rendered table.'
        Clear-ConnectorRenderedPreviewGrid
        $connectorRenderedPreviewText.Text = 'Rendered preview appears while authoring a draft mapping.'
        $connectorQueueButton.Content = 'Queue change'
        $mappingStudioState.DraftProjectionRef = ''
        $mappingStudioState.DraftProjectionColumns = @()
        $mappingStudioState.DraftProjectionFilter = @()
        $mappingStudioState.DraftProjectionRowOrder = @()
        Refresh-ConnectorProjectionLists
        Update-ConnectorProjectionSelectionDetails
        Update-MappingStudioInteractionState
        return
    }

    if ($null -eq $datasetNode -or $null -eq $targetNode) {
        $connectorAuthoringHintText.Text = 'Select the dataset and target for the draft mapping before queueing a change.'
        Update-MappingStudioInteractionState
        return
    }

    $existingMapping = $null
    switch ($mode) {
        'edit-existing' {
            $existingMapping = $selectedConnection
        }
        'replace-target' {
            $existingMapping = $selectedConnection
        }
        default {
            if ([bool]$targetNode.IsMapped) {
                $existingMapping = $targetNode.Mappings | Select-Object -First 1
            }
        }
    }

    $defaultRenderAs = if ($null -ne $existingMapping -and -not [string]::IsNullOrWhiteSpace([string]$existingMapping.RenderAs)) {
        [string]$existingMapping.RenderAs
    }
    elseif ([string]$datasetNode.PresentationKind -eq 'summary') {
        'scalar'
    }
    else {
        'table'
    }

    $selectedConnectionKey = if ($null -ne $selectedConnection) { [string]$selectedConnection.ConnectionKey } else { '' }
    $contextKey = "{0}|{1}|{2}|{3}" -f $mode, `
        $selectedConnectionKey, `
        [string]$datasetNode.DatasetId, `
        [string]$targetNode.TargetPath
    $contextChanged = $mappingStudioState.LastConnectorContextKey -ne $contextKey
    if ($contextChanged -or $null -eq $connectorRenderAsCombo.SelectedItem) {
        if ($defaultRenderAs -eq 'scalar') {
            $connectorRenderAsCombo.SelectedIndex = 1
        }
        else {
            $connectorRenderAsCombo.SelectedIndex = 0
        }
    }

    $selectorCandidates = Get-SelectorCandidatesForDataset -DatasetNode $datasetNode -ExampleData $datasetNode.ExampleData -RenderAs (Get-SelectedConnectorRenderAs) -SyncPolicy $workbench.SyncPolicy
    $currentSelectorText = [string]$connectorSelectorCombo.Text
    $connectorSelectorCombo.ItemsSource = @($selectorCandidates)
    if ($contextChanged) {
        if ($null -ne $existingMapping -and -not [string]::IsNullOrWhiteSpace([string]$existingMapping.PrimarySelector)) {
            $connectorSelectorCombo.Text = [string]$existingMapping.PrimarySelector
        }
        elseif (@($selectorCandidates).Count -gt 0) {
            $connectorSelectorCombo.Text = [string]$selectorCandidates[0]
        }
        else {
            $connectorSelectorCombo.Text = ''
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($currentSelectorText)) {
        $connectorSelectorCombo.Text = $currentSelectorText
    }
    elseif (@($selectorCandidates).Count -gt 0) {
        $connectorSelectorCombo.Text = [string]$selectorCandidates[0]
    }

    $renderAsChanged = [string]$mappingStudioState.LastConnectorRenderAs -ne (Get-SelectedConnectorRenderAs)
    if ($contextChanged) {
        $connectorViewText.Text = if ($null -ne $existingMapping) { [string]$existingMapping.View } else { '' }
        $connectorRequiredCheckBox.IsChecked = if ($null -ne $existingMapping) { [bool]$existingMapping.Required } else { $false }
    }

    if ($contextChanged -or $renderAsChanged) {
        Reset-ConnectorProjectionDraft -ExistingMapping $existingMapping -DatasetNode $datasetNode -TargetNode $targetNode
    }
    $mappingStudioState.LastConnectorRenderAs = [string](Get-SelectedConnectorRenderAs)
    Apply-ConnectorFieldCandidateSources
    Update-ConnectorProjectionSelectionDetails

    switch ($mode) {
        'edit-existing' {
            $connectorAuthoringHintText.Text = "Editing the current mapping for $($targetNode.TargetPath). Adjust the selector, projection shaping, and preview before queueing the updated mapping."
            $connectorQueueButton.Content = 'Queue edit'
        }
        'replace-target' {
            $connectorAuthoringHintText.Text = "Replacing the mapping for target $($targetNode.TargetPath). Choose the dataset, selector, and projection shaping that should feed this destination."
            $connectorQueueButton.Content = 'Queue replacement'
        }
        'new-connection' {
            if ([bool]$targetNode.IsMapped) {
                $connectorAuthoringHintText.Text = "The selected target already has a current mapping. Queueing this draft will replace that target mapping when the changes are saved."
            }
            elseif ([string]$targetNode.PlacementGroup -eq 'Available to stage') {
                $connectorAuthoringHintText.Text = "Creating a staged mapping for $($targetNode.TargetPath). This saves a valid contract target even if it has not yet been placed in the DOCX template."
            }
            else {
                $connectorAuthoringHintText.Text = "Creating a new connection from $($datasetNode.DatasetId) to $($targetNode.TargetPath)."
            }
            $connectorQueueButton.Content = 'Queue new mapping'
        }
    }

    $mappingStudioState.LastConnectorContextKey = $contextKey
    Update-MappingStudioInteractionState
}

function Invoke-MappingStudioPreviewUpdate {
    try {
        $workbench = $mappingStudioState.Workbench
        if ($null -eq $workbench) {
            $connectorSourcePreviewText.Text = ''
            $connectorRenderedGridStatusText.Text = ''
            Clear-ConnectorRenderedPreviewGrid
            $connectorRenderedPreviewText.Text = ''
            $connectorPreviewText.Text = ''
            return
        }

        if ([string]$mappingStudioState.ConnectorMode -ne 'inspect' -and $null -ne $connectorDatasetList.SelectedItem -and $null -ne $connectorTargetList.SelectedItem) {
            $preview = Get-MappingStudioPreview -Workbench $workbench -DatasetId ([string]$connectorDatasetList.SelectedItem.DatasetId) -RenderAs (Get-SelectedConnectorRenderAs) -Selector $connectorSelectorCombo.Text -ProjectionRef ([string]$mappingStudioState.DraftProjectionRef) -ProjectionColumns @($mappingStudioState.DraftProjectionColumns) -ProjectionFilter @($mappingStudioState.DraftProjectionFilter) -ProjectionRowOrder @($mappingStudioState.DraftProjectionRowOrder) -View $connectorViewText.Text
            $mappingStudioState.DraftFieldCandidates = @($preview.SourceFieldCandidates)
            Apply-ConnectorFieldCandidateSources
            $connectorSourcePreviewText.Text = Format-MappingStudioSourcePreview -Preview $preview
            Set-ConnectorRenderedPreviewGrid -Preview $preview
            $connectorRenderedPreviewText.Text = Format-MappingStudioRenderedPreview -Preview $preview
            $connectorPreviewText.Text = Format-MappingStudioPreview -Preview $preview
            return
        }

        $selectedConnection = Get-SelectedConnectorConnection
        if ($null -eq $selectedConnection) {
            $connectorSourcePreviewText.Text = 'Select a connection and open an authoring action to inspect selector rows.'
            $connectorRenderedGridStatusText.Text = 'Select a current connection or open an authoring action to view the rendered table.'
            Clear-ConnectorRenderedPreviewGrid
            $connectorRenderedPreviewText.Text = 'Select a current connection or open an authoring action to view a rendered preview.'
            if (@($workbench.ConnectionRows).Count -eq 0) {
                $connectorPreviewText.Text = 'No current connections are available for preview.'
            }
            else {
                $connectorPreviewText.Text = 'Select a current connection to view its example preview.'
            }
            return
        }

        $preview = Get-MappingStudioPreview -Workbench $workbench -DatasetId ([string]$selectedConnection.DatasetId) -RenderAs ([string]$selectedConnection.RenderAs) -Selector ([string]$selectedConnection.PrimarySelector) -ProjectionRef ([string]$selectedConnection.ProjectionRef) -View ([string]$selectedConnection.View)
        $connectorSourcePreviewText.Text = Format-MappingStudioSourcePreview -Preview $preview
        Set-ConnectorRenderedPreviewGrid -Preview $preview
        $connectorRenderedPreviewText.Text = Format-MappingStudioRenderedPreview -Preview $preview
        $connectorPreviewText.Text = Format-MappingStudioPreview -Preview $preview
    }
    catch {
        $connectorSourcePreviewText.Text = $_.Exception.Message
        $connectorRenderedGridStatusText.Text = $_.Exception.Message
        Clear-ConnectorRenderedPreviewGrid
        $connectorRenderedPreviewText.Text = $_.Exception.Message
        $connectorPreviewText.Text = $_.Exception.Message
    }
}

function Refresh-MappingStudioWorkbench {
    if ([bool]$mappingStudioState.IsRefreshing) {
        return
    }

    $mappingStudioState.IsRefreshing = $true
    try {
        if ((Get-SelectedBundleInputMode) -eq 'Archive') {
            throw 'Mapping Studio requires a folder bundle. Run archive render first, then select the extracted bundle under the repo bundle folder.'
        }

        Update-MappingCollectionChoices
        $collection = Get-SelectedMappingCollection
        if ($null -eq $collection) {
            $mappingStudioState.Workbench = $null
            $mappingModeText.Text = 'No template collection is available for the selected catalog.'
            $mappingOverviewText.Text = 'No Mapping Studio collection is selected.'
            $mappingDatasetsList.ItemsSource = @()
            $mappingTargetsList.ItemsSource = @()
            $connectorConnectionList.ItemsSource = @()
            $connectorDatasetList.ItemsSource = @()
            $connectorTargetList.ItemsSource = @()
            $connectorConnectionSummaryText.Text = ''
            $connectorDetailText.Text = 'No current connection inventory is available.'
            $connectorAuthoringHintText.Text = ''
            $connectorSourceFieldsText.Text = ''
            $connectorSourcePreviewText.Text = ''
            $connectorRenderedGridStatusText.Text = ''
            Clear-ConnectorRenderedPreviewGrid
            $connectorRenderedPreviewText.Text = ''
            $mappingStudioState.LastConnectorConnectionKey = ''
            $mappingStudioState.LastConnectorContextKey = ''
            $mappingStudioState.ConnectorMode = 'inspect'
            Update-MappingChangesView
            return
        }

        $mappingStudioState.Workbench = Get-MappingStudioWorkbench -RepoRoot $repoRoot -BundleRoot $bundleRootText.Text -ContractsRoot $contractsRootText.Text -Collection $collection
        $mappingOverviewText.Text = Format-MappingStudioOverview -Workbench $mappingStudioState.Workbench -PendingChanges $mappingStudioState.PendingChanges
        $mappingDatasetsList.ItemsSource = @($mappingStudioState.Workbench.Datasets)
        $mappingTargetsList.ItemsSource = @($mappingStudioState.Workbench.Targets)
        $connectorDatasetList.ItemsSource = @($mappingStudioState.Workbench.Datasets)
        $connectorTargetList.ItemsSource = @($mappingStudioState.Workbench.Targets)
        $mappingStudioState.ConnectorMode = 'inspect'
        $mappingStudioState.LastConnectorContextKey = ''

        $mappingModeText.Text = if ([bool]$mappingStudioState.Workbench.MappingDocument.readOnly) {
            "Read-only. $($mappingStudioState.Workbench.MappingDocument.readOnlyReason)"
        }
        else {
            "Authoring enabled. Using bundle target '$($mappingStudioState.Workbench.DatasetContext.target)' and system '$($mappingStudioState.Workbench.DatasetContext.selectedSystem)'."
        }

        if ($mappingDatasetsList.Items.Count -gt 0 -and $null -eq $mappingDatasetsList.SelectedItem) {
            $mappingDatasetsList.SelectedIndex = 0
        }
        if ($mappingTargetsList.Items.Count -gt 0 -and $null -eq $mappingTargetsList.SelectedItem) {
            $mappingTargetsList.SelectedIndex = 0
        }

        Update-MappingDatasetDetail
        Update-MappingTargetDetail
        Update-ConnectorConnectionList
        Update-ConnectorEditor
        Invoke-MappingStudioPreviewUpdate
        Update-MappingChangesView
        $statusText.Text = 'Mapping Studio refreshed.'
    }
    catch {
        $mappingStudioState.Workbench = $null
        $mappingModeText.Text = $_.Exception.Message
        $mappingOverviewText.Text = $_.Exception.Message
        $mappingDatasetDetailText.Text = $_.Exception.Message
        $mappingTargetDetailText.Text = $_.Exception.Message
        $connectorDetailText.Text = $_.Exception.Message
        $connectorSourcePreviewText.Text = $_.Exception.Message
        $connectorRenderedGridStatusText.Text = $_.Exception.Message
        Clear-ConnectorRenderedPreviewGrid
        $connectorRenderedPreviewText.Text = $_.Exception.Message
        $connectorPreviewText.Text = $_.Exception.Message
        $statusText.Text = 'Mapping Studio refresh failed.'
        Update-MappingChangesView
    }
    finally {
        $mappingStudioState.IsRefreshing = $false
        Publish-WebViewMappingStudioState
    }
}

$bundleBrowseButton.Add_Click({
    if ((Get-SelectedBundleInputMode) -eq 'Archive') {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Bundle archives (*.lnvbundle.zip;*.zip)|*.lnvbundle.zip;*.zip|All files (*.*)|*.*'
        $dialog.InitialDirectory = Resolve-DialogInitialDirectory -Path $bundleRootText.Text -RepoRoot $repoRoot -FallbackPath (Join-Path $repoRoot 'bundle') -PathKind File
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $bundleRootText.Text = $dialog.FileName
            Publish-WebViewMappingStudioState
        }
        return
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = Resolve-DialogInitialDirectory -Path $bundleRootText.Text -RepoRoot $repoRoot -FallbackPath $defaultBundleRoot -PathKind Directory
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $bundleRootText.Text = $dialog.SelectedPath
        Update-DocumentPropertyDefaultsFromBundle
        Publish-WebViewMappingStudioState
    }
})
$catalogBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Catalog JSON (*.catalog.json)|*.catalog.json|JSON (*.json)|*.json|All files (*.*)|*.*'
    $dialog.InitialDirectory = Resolve-DialogInitialDirectory -Path $catalogPathText.Text -RepoRoot $repoRoot -FallbackPath $defaultCatalogPath -PathKind File
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $catalogPathText.Text = $dialog.FileName
        Publish-WebViewMappingStudioState
    }
})
$outputBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $outputBrowsePath = Resolve-DialogInitialDirectory -Path $outputRootText.Text -RepoRoot $repoRoot -FallbackPath $defaultOutputRoot -PathKind Directory -CreateIfMissing
    $dialog.InitialDirectory = $outputBrowsePath
    $dialog.SelectedPath = $outputBrowsePath
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $outputRootText.Text = $dialog.SelectedPath
        Publish-WebViewMappingStudioState
    }
})
$contractsBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = Resolve-DialogInitialDirectory -Path $contractsRootText.Text -RepoRoot $repoRoot -FallbackPath $defaultContractsRoot -PathKind Directory
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $contractsRootText.Text = $dialog.SelectedPath
        Publish-WebViewMappingStudioState
    }
})
$bundleRootText.Add_LostFocus({
    Update-DocumentPropertyDefaultsFromBundle
    Publish-WebViewMappingStudioState
})
$bundleInputModeCombo.Add_SelectionChanged({
    Update-DocumentPropertyDefaultsFromBundle
    Publish-WebViewMappingStudioState
})
$mappingRefreshButton.Add_Click({
    Refresh-MappingStudioWorkbench
})
$mappingCollectionCombo.Add_SelectionChanged({
    if (-not [bool]$mappingStudioState.IsRefreshing -and $null -ne $mappingCollectionCombo.SelectedItem) {
        Refresh-MappingStudioWorkbench
    }
})
$mappingDatasetsList.Add_SelectionChanged({
    Update-MappingDatasetDetail
})
$mappingTargetsList.Add_SelectionChanged({
    Update-MappingTargetDetail
})
$connectorSearchTextBox.Add_TextChanged({
    Update-ConnectorConnectionList
    Set-ConnectorAuthoringMode -Mode 'inspect'
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorQuickFilterCombo.Add_SelectionChanged({
    Update-ConnectorConnectionList
    Set-ConnectorAuthoringMode -Mode 'inspect'
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorConnectionList.Add_SelectionChanged({
    $selectedConnection = Get-SelectedConnectorConnection
    $mappingStudioState.LastConnectorConnectionKey = if ($null -ne $selectedConnection) { [string]$selectedConnection.ConnectionKey } else { '' }
    Set-ConnectorAuthoringMode -Mode 'inspect' -ConnectionRow $selectedConnection
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorDatasetList.Add_SelectionChanged({
    if ([bool]$mappingStudioState.SuppressConnectorSelectionEvents) {
        return
    }
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorTargetList.Add_SelectionChanged({
    if ([bool]$mappingStudioState.SuppressConnectorSelectionEvents) {
        return
    }
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorRenderAsCombo.Add_SelectionChanged({
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorProjectionColumnsList.Add_SelectionChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) {
        return
    }
    Update-ConnectorProjectionSelectionDetails
})
$connectorProjectionFiltersList.Add_SelectionChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) {
        return
    }
    Update-ConnectorProjectionSelectionDetails
})
$connectorProjectionSortList.Add_SelectionChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) {
        return
    }
    Update-ConnectorProjectionSelectionDetails
})
$connectorColumnAddButton.Add_Click({
    $columnDraft = New-ConnectorColumnDraft
    $mappingStudioState.DraftProjectionColumns = @($mappingStudioState.DraftProjectionColumns) + @($columnDraft)
    Refresh-ConnectorProjectionLists
    $connectorProjectionColumnsList.SelectedItem = $columnDraft
    Update-ConnectorProjectionSelectionDetails
})
$connectorColumnRemoveButton.Add_Click({
    $selected = Get-SelectedConnectorProjectionColumn
    if ($null -eq $selected) { return }
    $mappingStudioState.DraftProjectionColumns = @($mappingStudioState.DraftProjectionColumns | Where-Object { [string]$_.Id -ne [string]$selected.Id })
    Refresh-ConnectorProjectionLists
    Update-ConnectorProjectionSelectionDetails
    Invoke-MappingStudioPreviewUpdate
})
$connectorColumnUpButton.Add_Click({
    $selected = Get-SelectedConnectorProjectionColumn
    if ($null -eq $selected) { return }
    $items = New-Object System.Collections.ArrayList
    foreach ($item in @($mappingStudioState.DraftProjectionColumns)) { [void]$items.Add($item) }
    Move-ConnectorDraftItem -Items $items -ItemId ([string]$selected.Id) -Direction -1
    $mappingStudioState.DraftProjectionColumns = @($items)
    Refresh-ConnectorProjectionLists
    $connectorProjectionColumnsList.SelectedItem = $mappingStudioState.DraftProjectionColumns | Where-Object { [string]$_.Id -eq [string]$selected.Id } | Select-Object -First 1
    Update-ConnectorProjectionSelectionDetails
    Invoke-MappingStudioPreviewUpdate
})
$connectorColumnDownButton.Add_Click({
    $selected = Get-SelectedConnectorProjectionColumn
    if ($null -eq $selected) { return }
    $items = New-Object System.Collections.ArrayList
    foreach ($item in @($mappingStudioState.DraftProjectionColumns)) { [void]$items.Add($item) }
    Move-ConnectorDraftItem -Items $items -ItemId ([string]$selected.Id) -Direction 1
    $mappingStudioState.DraftProjectionColumns = @($items)
    Refresh-ConnectorProjectionLists
    $connectorProjectionColumnsList.SelectedItem = $mappingStudioState.DraftProjectionColumns | Where-Object { [string]$_.Id -eq [string]$selected.Id } | Select-Object -First 1
    Update-ConnectorProjectionSelectionDetails
    Invoke-MappingStudioPreviewUpdate
})
$connectorFilterAddButton.Add_Click({
    $filterDraft = New-ConnectorFilterDraft
    $mappingStudioState.DraftProjectionFilter = @($mappingStudioState.DraftProjectionFilter) + @($filterDraft)
    Refresh-ConnectorProjectionLists
    $connectorProjectionFiltersList.SelectedItem = $filterDraft
    Update-ConnectorProjectionSelectionDetails
})
$connectorFilterRemoveButton.Add_Click({
    $selected = Get-SelectedConnectorProjectionFilter
    if ($null -eq $selected) { return }
    $mappingStudioState.DraftProjectionFilter = @($mappingStudioState.DraftProjectionFilter | Where-Object { [string]$_.Id -ne [string]$selected.Id })
    Refresh-ConnectorProjectionLists
    Update-ConnectorProjectionSelectionDetails
    Invoke-MappingStudioPreviewUpdate
})
$connectorSortAddButton.Add_Click({
    $sortDraft = New-ConnectorSortDraft
    $mappingStudioState.DraftProjectionRowOrder = @($mappingStudioState.DraftProjectionRowOrder) + @($sortDraft)
    Refresh-ConnectorProjectionLists
    $connectorProjectionSortList.SelectedItem = $sortDraft
    Update-ConnectorProjectionSelectionDetails
})
$connectorSortRemoveButton.Add_Click({
    $selected = Get-SelectedConnectorProjectionSort
    if ($null -eq $selected) { return }
    $mappingStudioState.DraftProjectionRowOrder = @($mappingStudioState.DraftProjectionRowOrder | Where-Object { [string]$_.Id -ne [string]$selected.Id })
    Refresh-ConnectorProjectionLists
    Update-ConnectorProjectionSelectionDetails
    Invoke-MappingStudioPreviewUpdate
})
$connectorSortUpButton.Add_Click({
    $selected = Get-SelectedConnectorProjectionSort
    if ($null -eq $selected) { return }
    $items = New-Object System.Collections.ArrayList
    foreach ($item in @($mappingStudioState.DraftProjectionRowOrder)) { [void]$items.Add($item) }
    Move-ConnectorDraftItem -Items $items -ItemId ([string]$selected.Id) -Direction -1
    $mappingStudioState.DraftProjectionRowOrder = @($items)
    Refresh-ConnectorProjectionLists
    $connectorProjectionSortList.SelectedItem = $mappingStudioState.DraftProjectionRowOrder | Where-Object { [string]$_.Id -eq [string]$selected.Id } | Select-Object -First 1
    Update-ConnectorProjectionSelectionDetails
    Invoke-MappingStudioPreviewUpdate
})
$connectorSortDownButton.Add_Click({
    $selected = Get-SelectedConnectorProjectionSort
    if ($null -eq $selected) { return }
    $items = New-Object System.Collections.ArrayList
    foreach ($item in @($mappingStudioState.DraftProjectionRowOrder)) { [void]$items.Add($item) }
    Move-ConnectorDraftItem -Items $items -ItemId ([string]$selected.Id) -Direction 1
    $mappingStudioState.DraftProjectionRowOrder = @($items)
    Refresh-ConnectorProjectionLists
    $connectorProjectionSortList.SelectedItem = $mappingStudioState.DraftProjectionRowOrder | Where-Object { [string]$_.Id -eq [string]$selected.Id } | Select-Object -First 1
    Update-ConnectorProjectionSelectionDetails
    Invoke-MappingStudioPreviewUpdate
})
$connectorColumnNameText.Add_TextChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionColumn
    if ($null -eq $selected) { return }
    $selected.Name = [string]$connectorColumnNameText.Text
    Update-ConnectorColumnDraftLabel -ColumnDraft $selected
    Refresh-ConnectorProjectionLists
    $connectorProjectionColumnsList.SelectedItem = $selected
    Invoke-MappingStudioPreviewUpdate
})
$connectorColumnSourceCombo.Add_LostFocus({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionColumn
    if ($null -eq $selected) { return }
    $selected.Source = [string]$connectorColumnSourceCombo.Text
    Update-ConnectorColumnDraftLabel -ColumnDraft $selected
    Refresh-ConnectorProjectionLists
    $connectorProjectionColumnsList.SelectedItem = $selected
    Invoke-MappingStudioPreviewUpdate
})
$connectorColumnFormatText.Add_TextChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionColumn
    if ($null -eq $selected) { return }
    $selected.Format = [string]$connectorColumnFormatText.Text
    Invoke-MappingStudioPreviewUpdate
})
$connectorColumnDelimiterText.Add_TextChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionColumn
    if ($null -eq $selected) { return }
    $selected.Delimiter = [string]$connectorColumnDelimiterText.Text
    Invoke-MappingStudioPreviewUpdate
})
$connectorFilterFieldCombo.Add_LostFocus({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionFilter
    if ($null -eq $selected) { return }
    $selected.Field = [string]$connectorFilterFieldCombo.Text
    Update-ConnectorFilterDraftLabel -FilterDraft $selected
    Refresh-ConnectorProjectionLists
    $connectorProjectionFiltersList.SelectedItem = $selected
    Invoke-MappingStudioPreviewUpdate
})
$connectorFilterEqualsText.Add_TextChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionFilter
    if ($null -eq $selected) { return }
    $selected.Equals = [string]$connectorFilterEqualsText.Text
    Update-ConnectorFilterDraftLabel -FilterDraft $selected
    Refresh-ConnectorProjectionLists
    $connectorProjectionFiltersList.SelectedItem = $selected
    Invoke-MappingStudioPreviewUpdate
})
$connectorSortByCombo.Add_LostFocus({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionSort
    if ($null -eq $selected) { return }
    $selected.By = [string]$connectorSortByCombo.Text
    Update-ConnectorSortDraftLabel -SortDraft $selected
    Refresh-ConnectorProjectionLists
    $connectorProjectionSortList.SelectedItem = $selected
    Invoke-MappingStudioPreviewUpdate
})
$connectorSortDirectionCombo.Add_SelectionChanged({
    if ([bool]$mappingStudioState.SuppressProjectionEditorEvents) { return }
    $selected = Get-SelectedConnectorProjectionSort
    if ($null -eq $selected) { return }
    $selected.Direction = if ($null -ne $connectorSortDirectionCombo.SelectedItem) { [string]$connectorSortDirectionCombo.SelectedItem.Content } else { 'asc' }
    Update-ConnectorSortDraftLabel -SortDraft $selected
    Refresh-ConnectorProjectionLists
    $connectorProjectionSortList.SelectedItem = $selected
    Invoke-MappingStudioPreviewUpdate
})
$connectorEditButton.Add_Click({
    Set-ConnectorAuthoringMode -Mode 'edit-existing'
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorReplaceButton.Add_Click({
    Set-ConnectorAuthoringMode -Mode 'replace-target'
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorNewButton.Add_Click({
    Set-ConnectorAuthoringMode -Mode 'new-connection'
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorOpenDatasetButton.Add_Click({
    $selectedConnection = Get-SelectedConnectorConnection
    if ($null -eq $selectedConnection) {
        return
    }

    $connectorSearchTextBox.Text = [string]$selectedConnection.DatasetId
    $mappingDatasetsList.SelectedItem = $selectedConnection.DatasetNode
    if ($null -ne $mappingStudioTabs) {
        $mappingStudioTabs.SelectedIndex = 1
    }
    $statusText.Text = "Opened dataset '$($selectedConnection.DatasetId)' from Connector."
})
$connectorOpenTargetButton.Add_Click({
    $selectedConnection = Get-SelectedConnectorConnection
    if ($null -eq $selectedConnection) {
        return
    }

    $connectorSearchTextBox.Text = [string]$selectedConnection.TargetPath
    $mappingTargetsList.SelectedItem = $selectedConnection.TargetNode
    if ($null -ne $mappingStudioTabs) {
        $mappingStudioTabs.SelectedIndex = 2
    }
    $statusText.Text = "Opened target '$($selectedConnection.TargetPath)' from Connector."
})
$connectorPreviewButton.Add_Click({
    Invoke-MappingStudioPreviewUpdate
})
$connectorResetButton.Add_Click({
    $mappingStudioState.LastConnectorContextKey = ''
    Update-ConnectorEditor
    Invoke-MappingStudioPreviewUpdate
})
$connectorQueueButton.Add_Click({
    try {
        $workbench = $mappingStudioState.Workbench
        $datasetNode = $connectorDatasetList.SelectedItem
        $targetNode = $connectorTargetList.SelectedItem
        if ([string]$mappingStudioState.ConnectorMode -eq 'inspect') {
            throw 'Open Edit mapping, Replace target, or New connection before queueing a Mapping Studio change.'
        }
        if ($null -eq $workbench -or $null -eq $datasetNode -or $null -eq $targetNode) {
            throw 'Select a dataset and target before queueing a mapping change.'
        }

        $mappingStudioState.PendingChanges = Add-MappingStudioPendingChange -Workbench $workbench -PendingChanges $mappingStudioState.PendingChanges -DatasetId ([string]$datasetNode.DatasetId) -TargetPath ([string]$targetNode.TargetPath) -RenderAs (Get-SelectedConnectorRenderAs) -Selector $connectorSelectorCombo.Text -ProjectionRef ([string]$mappingStudioState.DraftProjectionRef) -View $connectorViewText.Text -Required ([bool]$connectorRequiredCheckBox.IsChecked) -ProjectionColumns @($mappingStudioState.DraftProjectionColumns) -ProjectionFilter @($mappingStudioState.DraftProjectionFilter) -ProjectionRowOrder @($mappingStudioState.DraftProjectionRowOrder)
        $mappingOverviewText.Text = Format-MappingStudioOverview -Workbench $mappingStudioState.Workbench -PendingChanges $mappingStudioState.PendingChanges
        Update-MappingChangesView
        $statusText.Text = 'Mapping change queued.'
    }
    catch {
        $statusText.Text = 'Unable to queue mapping change.'
        $connectorPreviewText.Text = $_.Exception.Message
    }
})
$mappingClearChangesButton.Add_Click({
    $mappingStudioState.PendingChanges = @()
    if ($null -ne $mappingStudioState.Workbench) {
        $mappingOverviewText.Text = Format-MappingStudioOverview -Workbench $mappingStudioState.Workbench -PendingChanges $mappingStudioState.PendingChanges
    }
    Update-MappingChangesView
    $statusText.Text = 'Queued Mapping Studio changes cleared.'
})
$mappingSaveButton.Add_Click({
    try {
        $result = Save-MappingStudioPendingChanges -Workbench $mappingStudioState.Workbench -PendingChanges $mappingStudioState.PendingChanges
        $mappingStudioState.PendingChanges = @()
        Refresh-MappingStudioWorkbench
        $mappingChangesText.Text = @(
            "Saved mapping changes: $([int]$result.SavedCount)"
            "Contract YAML: $([string]$result.ContractPath)"
            "Export mirror: $([string]$result.ExportMirrorPath)"
            "Runtime mapping: $([string]$result.RuntimePath)"
        ) -join [Environment]::NewLine
        $statusText.Text = 'Mapping Studio changes saved.'
    }
    catch {
        $statusText.Text = 'Mapping Studio save failed.'
        $mappingChangesText.Text = $_.Exception.Message
    }
})

$runButton.Add_Click({
    try {
        $null = Start-RenderFromCurrentInputs
    }
    catch {
        $runButton.IsEnabled = $true
        $cancelButton.IsEnabled = $false
        $renderProcessState.Current = $null
        $statusText.Text = 'Render failed to start.'
        $outputText.Text = $_.Exception.ToString()
    }
})

$cancelButton.Add_Click({
    try {
        if ($null -eq $renderProcessState.Current) { return }
        $statusText.Text = 'Cancelling render...'
        Request-AssemblerGuiRenderCancel -RenderState $renderProcessState.Current
    }
    catch {
        $statusText.Text = 'Cancel request failed.'
        $outputText.Text = $_.Exception.ToString()
    }
})

Update-DocumentPropertyDefaultsFromBundle
Refresh-MappingStudioWorkbench
Update-MappingChangesView
Initialize-RenderProgressTimer
Initialize-WebViewHost

[void]$window.ShowDialog()

