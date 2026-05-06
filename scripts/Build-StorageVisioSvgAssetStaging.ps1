[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$ExportRoot = 'C:\temp\exports',
    [Parameter(Mandatory = $false)][string]$StencilRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.diagramKB/vss'),
    [Parameter(Mandatory = $false)][string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.diagramKB/generated/storage-visio-svg'),
    [Parameter(Mandatory = $false)][string]$LenovoDeRepo = 'C:\Github\LNV.AsBuiltDoc.Lenovo.DE',
    [Parameter(Mandatory = $false)][string]$OntapRepo = 'C:\Github\LNV.AsBuiltDoc.NetApp.ONTAP',
    [Parameter(Mandatory = $false)][ValidateSet('DE','DM','DG','DS')][string[]]$Families = @('DE','DM','DG','DS'),
    [Parameter(Mandatory = $false)][switch]$StageToRepos,
    [Parameter(Mandatory = $false)][switch]$AllowUnsafeBranch,
    [Parameter(Mandatory = $false)][switch]$AllowExistingAssetChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$familyConfig = @{
    DE = @{
        Technology = 'Lenovo.DE'
        OwningRepo = 'Lenovo.DE'
        RepoPath = $LenovoDeRepo
        ManifestName = 'lenovo-de-asset-manifest.yaml'
        ReviewName = 'lenovo-de-review-required.csv'
        StencilName = 'Lenovo-ThinkSystem-DE.vssx'
        RawSubdir = ''
    }
    DM = @{
        Technology = 'NetApp.ONTAP'
        OwningRepo = 'NetApp.ONTAP'
        RepoPath = $OntapRepo
        ManifestName = 'netapp-ontap-dm-asset-manifest.yaml'
        ReviewName = 'netapp-ontap-dm-review-required.csv'
        StencilName = 'Lenovo-ThinkSystem-DM.vssx'
        RawSubdir = 'DM'
    }
    DG = @{
        Technology = 'NetApp.ONTAP'
        OwningRepo = 'NetApp.ONTAP'
        RepoPath = $OntapRepo
        ManifestName = 'netapp-ontap-dg-asset-manifest.yaml'
        ReviewName = 'netapp-ontap-dg-review-required.csv'
        StencilName = 'Lenovo-ThinkSystem-DG.vssx'
        RawSubdir = 'DG'
    }
    DS = @{
        Technology = 'NetApp.ONTAP'
        OwningRepo = 'NetApp.ONTAP'
        RepoPath = $OntapRepo
        ManifestName = 'netapp-ontap-ds-asset-manifest.yaml'
        ReviewName = 'netapp-ontap-ds-review-required.csv'
        StencilName = 'Lenovo-ThinkSystem-DS.vssx'
        RawSubdir = 'DS'
    }
}

$protectedBranches = @('main','master','dev','develop')
$componentTerms = @(
    'controller','controllers','canister','hic','host interface','drive','disk','psu','power','fan','module','sfp',
    'port','rail','bezel','blank','icon','led','label','cable','qsfp','ethernet','base-t','iwarp','crypto'
)

function ConvertTo-AssetSlug {
    param([Parameter(Mandatory = $false)]$Value)
    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    $text = $text -replace '/', '-'
    $text = $text -replace '[^a-z0-9]+', '-'
    return $text.Trim('-')
}

function ConvertTo-YamlScalar {
    param([Parameter(Mandatory = $false)]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [double] -or $Value -is [decimal]) { return [string]$Value }
    $text = [string]$Value
    if ($text -eq '') { return '""' }
    return '"' + (($text -replace '\\', '\\') -replace '"', '\"') + '"'
}

function Write-CsvObjects {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add(($Columns | ConvertTo-Csv -NoTypeInformation)[1])
    foreach ($row in @($Rows)) {
        $values = [ordered]@{}
        foreach ($column in $Columns) {
            $property = $row.PSObject.Properties[$column]
            $values[$column] = if ($null -eq $property) { '' } else { $property.Value }
        }
        [void]$lines.Add(((New-Object psobject -Property $values) | ConvertTo-Csv -NoTypeInformation)[1])
    }
    Set-Content -LiteralPath $Path -Value ($lines -join "`n") -Encoding UTF8
}

function Get-GitRepoState {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git') -PathType Container)) {
        throw "Target repo '$RepoPath' is not a git repository."
    }
    $branch = (& git -C $RepoPath branch --show-current).Trim()
    $upstream = (& git -C $RepoPath rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $upstreamText = if ($null -eq $upstream) { '' } else { ([string]$upstream).Trim() }
    $status = @(& git -C $RepoPath status --short)
    $assetStatus = @(& git -C $RepoPath status --short -- assets/diagrams 2>$null)
    return [pscustomobject]@{
        RepoPath = $RepoPath
        Branch = $branch
        Upstream = $upstreamText
        Status = @($status)
        AssetStatus = @($assetStatus)
    }
}

function Assert-SafeTargetRepo {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$ExpectedRepoName,
        [Parameter(Mandatory = $false)][switch]$AllowUnsafeBranch,
        [Parameter(Mandatory = $false)][switch]$AllowExistingAssetChanges
    )
    $state = Get-GitRepoState -RepoPath $RepoPath
    if (-not $AllowUnsafeBranch.IsPresent -and ($protectedBranches -contains $state.Branch)) {
        throw "Refusing to stage $ExpectedRepoName assets into protected branch '$($state.Branch)' at '$RepoPath'."
    }
    if (-not $AllowUnsafeBranch.IsPresent -and $state.Branch -notmatch 'storage-visio-assets|diagram|asset') {
        throw "Refusing to stage $ExpectedRepoName assets into unrelated branch '$($state.Branch)' at '$RepoPath'."
    }
    if (@($state.AssetStatus).Count -gt 0 -and -not $AllowExistingAssetChanges.IsPresent) {
        throw "Refusing to stage $ExpectedRepoName assets because '$RepoPath' has existing assets/diagrams changes: $($state.AssetStatus -join '; ')"
    }
    return $state
}

function Classify-StorageSvgAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][string]$MasterName
    )
    $name = $MasterName.Trim()
    $lower = $name.ToLowerInvariant()
    $prefixPattern = switch ($Family) {
        'DE' { 'DE\d{3,4}[A-Z]?' }
        'DM' { 'DM\d{3,4}[A-Z]?' }
        'DG' { 'DG\d{3,4}[A-Z]?' }
        'DS' { 'DS\d{3,4}[A-Z]?' }
    }
    if ($name -match "^(?<product>$prefixPattern)(?:\s+(?<enclosure>\dU\d+))?\s+(?<view>Front Open|Front|Rear|Open|Closed)$") {
        return [pscustomobject]@{ AssetType = $(if ($Family -eq 'DS') { 'baseEnclosure' } else { 'baseProduct' }); CanBePrimaryProductAsset = $true; NeedsReview = $false; Reason = 'full master view' }
    }
    if ($name -match "^(?<product>$prefixPattern)(?:\s+(?<enclosure>\dU\d+))?\s+(?<module>.+?)\s+Rear$") {
        return [pscustomobject]@{ AssetType = $(if ($Family -eq 'DS') { 'baseEnclosure' } else { 'baseProduct' }); CanBePrimaryProductAsset = $true; NeedsReview = $true; Reason = 'base rear module variant' }
    }
    foreach ($term in $componentTerms) {
        if ($lower -match ('(^|[^a-z0-9])' + [regex]::Escape($term) + '([^a-z0-9]|$)')) {
            return [pscustomobject]@{ AssetType = 'component'; CanBePrimaryProductAsset = $false; NeedsReview = $false; Reason = "component term '$term'" }
        }
    }
    return [pscustomobject]@{ AssetType = 'unknown'; CanBePrimaryProductAsset = $false; NeedsReview = $true; Reason = 'no conservative classification rule matched' }
}

function Get-AssetMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][object]$Row
    )
    $masterName = if (-not [string]::IsNullOrWhiteSpace([string]$Row.MasterNameU)) { [string]$Row.MasterNameU } else { [string]$Row.MasterName }
    $classification = Classify-StorageSvgAsset -Family $Family -MasterName $masterName
    $productId = ''
    $view = ''
    $enclosure = ''
    $rearModule = ''
    if ($masterName -match '^(?<product>[A-Z]{2}\d{3,4}[A-Z]?)(?:\s+(?<enclosure>\dU\d+))?\s+(?<view>Front Open|Front|Rear|Open|Closed)$') {
        $productId = [string]$Matches.product
        $view = ([string]$Matches.view).ToLowerInvariant().Replace(' ', '-')
        $enclosure = if ($Matches.ContainsKey('enclosure')) { [string]$Matches.enclosure } else { '' }
    }
    elseif ($masterName -match '^(?<product>[A-Z]{2}\d{3,4}[A-Z]?)(?:\s+(?<enclosure>\dU\d+))?\s+(?<module>.+?)\s+Rear$') {
        $productId = [string]$Matches.product
        $view = 'rear'
        $enclosure = if ($Matches.ContainsKey('enclosure')) { [string]$Matches.enclosure } else { '' }
        $rearModule = [string]$Matches.module
    }
    return [pscustomobject]@{
        AssetRef = ('storage.' + $Family.ToLowerInvariant() + '.visio-master.' + [string]$Row.MasterId + '.' + (ConvertTo-AssetSlug -Value $masterName))
        AssetFile = [string]$Row.AssetFile
        MasterId = [string]$Row.MasterId
        MasterName = [string]$Row.MasterName
        MasterNameU = [string]$Row.MasterNameU
        ProductId = $productId
        Enclosure = $enclosure
        View = $view
        RearModule = $rearModule
        AssetType = [string]$classification.AssetType
        CanBePrimaryProductAsset = [bool]$classification.CanBePrimaryProductAsset
        NeedsReview = [bool]$classification.NeedsReview
        ReviewReason = [string]$classification.Reason
        ViewBox = [string]$Row.ViewBox
        ViewBoxWidth = [string]$Row.ViewBoxWidth
        ViewBoxHeight = [string]$Row.ViewBoxHeight
        AspectRatio = [string]$Row.AspectRatio
        PreviewWidthPx = [string]$Row.PreviewWidthPx
        PreviewHeightPx = [string]$Row.PreviewHeightPx
    }
}

function Write-FamilyManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object[]]$Assets
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('schemaVersion: 1')
    [void]$lines.Add(('technology: {0}' -f (ConvertTo-YamlScalar -Value $Config.Technology)))
    [void]$lines.Add(('storageFamily: {0}' -f (ConvertTo-YamlScalar -Value $Family)))
    [void]$lines.Add('sourceType: "VisioVssxSvgExport"')
    [void]$lines.Add(('sourceStencil: {0}' -f (ConvertTo-YamlScalar -Value $Config.StencilName)))
    [void]$lines.Add('identityPolicy:')
    [void]$lines.Add('  assetUnit: "rendered-visio-master-svg"')
    [void]$lines.Add('  emfFilenameIdentityAllowed: false')
    [void]$lines.Add('  unknownAssetsAutoSelectable: false')
    [void]$lines.Add('assets:')
    foreach ($asset in @($Assets | Sort-Object AssetRef)) {
        [void]$lines.Add(('  - assetRef: {0}' -f (ConvertTo-YamlScalar -Value $asset.AssetRef)))
        [void]$lines.Add(('    assetFile: {0}' -f (ConvertTo-YamlScalar -Value $asset.AssetFile)))
        [void]$lines.Add(('    masterId: {0}' -f (ConvertTo-YamlScalar -Value $asset.MasterId)))
        [void]$lines.Add(('    masterName: {0}' -f (ConvertTo-YamlScalar -Value $asset.MasterNameU)))
        [void]$lines.Add(('    assetType: {0}' -f (ConvertTo-YamlScalar -Value $asset.AssetType)))
        [void]$lines.Add(('    productId: {0}' -f (ConvertTo-YamlScalar -Value $asset.ProductId)))
        [void]$lines.Add(('    enclosure: {0}' -f (ConvertTo-YamlScalar -Value $asset.Enclosure)))
        [void]$lines.Add(('    view: {0}' -f (ConvertTo-YamlScalar -Value $asset.View)))
        [void]$lines.Add(('    rearModule: {0}' -f (ConvertTo-YamlScalar -Value $asset.RearModule)))
        [void]$lines.Add(('    canBePrimaryProductAsset: {0}' -f (ConvertTo-YamlScalar -Value $asset.CanBePrimaryProductAsset)))
        [void]$lines.Add(('    needsReview: {0}' -f (ConvertTo-YamlScalar -Value $asset.NeedsReview)))
        [void]$lines.Add(('    reviewReason: {0}' -f (ConvertTo-YamlScalar -Value $asset.ReviewReason)))
        [void]$lines.Add(('    viewBox: {0}' -f (ConvertTo-YamlScalar -Value $asset.ViewBox)))
    }
    Set-Content -LiteralPath $Path -Value ($lines -join "`n") -Encoding UTF8
}

function Process-Family {
    param(
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )
    $familyExportRoot = Join-Path $ExportRoot $Family
    if (-not (Test-Path -LiteralPath $familyExportRoot -PathType Container)) {
        throw "Export folder for family '$Family' was not found at '$familyExportRoot'."
    }
    $svgFiles = @(Get-ChildItem -LiteralPath $familyExportRoot -File -Filter '*.svg')
    if ($svgFiles.Count -eq 0) {
        throw "No SVG files were found for family '$Family' at '$familyExportRoot'."
    }
    $indexPath = Join-Path $familyExportRoot '_visio-master-export-index.csv'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "Export index for family '$Family' was not found at '$indexPath'."
    }
    $rows = @(Import-Csv -LiteralPath $indexPath)
    $assets = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.AssetFile) -and [string]$_.AssetFile -match '\.svg$' } | ForEach-Object { Get-AssetMetadata -Family $Family -Row $_ })

    foreach ($asset in @($assets)) {
        if ([string]$asset.AssetFile -match '\.emf$') { throw "Manifest candidate for '$Family' references raw EMF '$($asset.AssetFile)'." }
        if ([string]$asset.AssetType -eq 'component' -and [bool]$asset.CanBePrimaryProductAsset) { throw "Component '$($asset.AssetRef)' was marked primary-capable." }
        if ([string]$asset.AssetType -eq 'unknown' -and -not [bool]$asset.NeedsReview) { throw "Unknown '$($asset.AssetRef)' was not marked needsReview." }
    }

    $familyOutputRoot = Join-Path $OutputRoot $Family
    $null = New-Item -Path $familyOutputRoot -ItemType Directory -Force
    $manifestPath = Join-Path $familyOutputRoot $Config.ManifestName
    $reviewPath = Join-Path $familyOutputRoot $Config.ReviewName
    $indexCopyPath = Join-Path $familyOutputRoot ('_visio-master-export-index-' + $Family.ToLowerInvariant() + '.csv')
    Write-FamilyManifest -Path $manifestPath -Family $Family -Config $Config -Assets $assets
    Copy-Item -LiteralPath $indexPath -Destination $indexCopyPath -Force
    $reviewRows = @($assets | Where-Object { [bool]$_.NeedsReview } | ForEach-Object {
        [pscustomobject]@{
            family = $Family
            assetRef = $_.AssetRef
            masterName = $_.MasterNameU
            assetType = $_.AssetType
            reason = $_.ReviewReason
        }
    })
    Write-CsvObjects -Rows $reviewRows -Columns @('family','assetRef','masterName','assetType','reason') -Path $reviewPath

    if ($StageToRepos.IsPresent) {
        $repoState = Assert-SafeTargetRepo -RepoPath $Config.RepoPath -ExpectedRepoName $Config.OwningRepo -AllowUnsafeBranch:$AllowUnsafeBranch -AllowExistingAssetChanges:$AllowExistingAssetChanges
        $repoAssetsRoot = Join-Path $Config.RepoPath 'assets/diagrams'
        $sourceRoot = Join-Path $repoAssetsRoot 'source'
        $rawRoot = Join-Path $repoAssetsRoot 'rendered/raw'
        if (-not [string]::IsNullOrWhiteSpace([string]$Config.RawSubdir)) {
            $rawRoot = Join-Path $rawRoot $Config.RawSubdir
        }
        $manifestRoot = Join-Path $repoAssetsRoot 'manifests'
        $null = New-Item -Path $sourceRoot,$rawRoot,$manifestRoot -ItemType Directory -Force
        $stencilPath = Join-Path $StencilRoot $Config.StencilName
        if (-not (Test-Path -LiteralPath $stencilPath -PathType Leaf)) {
            throw "Source stencil '$stencilPath' was not found."
        }
        Copy-Item -LiteralPath $stencilPath -Destination (Join-Path $sourceRoot $Config.StencilName) -Force
        foreach ($svg in @($svgFiles)) {
            Copy-Item -LiteralPath $svg.FullName -Destination (Join-Path $rawRoot $svg.Name) -Force
        }
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $manifestRoot $Config.ManifestName) -Force
        Copy-Item -LiteralPath $reviewPath -Destination (Join-Path $manifestRoot $Config.ReviewName) -Force
        Copy-Item -LiteralPath $indexCopyPath -Destination (Join-Path $manifestRoot (Split-Path $indexCopyPath -Leaf)) -Force
        return [pscustomobject]@{ Family = $Family; SvgCount = $svgFiles.Count; Staged = $true; RepoPath = $Config.RepoPath; Branch = $repoState.Branch; Manifest = $manifestPath }
    }

    return [pscustomobject]@{ Family = $Family; SvgCount = $svgFiles.Count; Staged = $false; RepoPath = ''; Branch = ''; Manifest = $manifestPath }
}

$results = @()
foreach ($family in @($Families)) {
    if (-not $familyConfig.ContainsKey($family)) { throw "Unknown storage family '$family'." }
    $results += Process-Family -Family $family -Config $familyConfig[$family]
}

$results | ConvertTo-Json -Depth 6
