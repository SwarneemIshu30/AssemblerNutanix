#!/usr/bin/env pwsh
<#
.SYNOPSIS
Sync Assembler contracts into deterministic local ingest path (`.deps/contracts`).

.DESCRIPTION
Supports two modes only:
1) Published release pack sync (default with no args): resolve latest release asset and download/extract zip
2) Local export copy (when non-pack options are supplied): `export/repo-ready/contracts` -> `.deps/contracts`
#>

[CmdletBinding()]
param(
    [string]$ExportContractsPath = (Join-Path $PSScriptRoot '..\export\repo-ready\contracts'),

    [string]$ContractsVersion,

    [string]$ContractsPackUrl,

    [string]$ReleaseBaseUrl = 'https://github.com/LNV-AsBuiltDoc/LNV.AsBuiltDoc.Contracts/releases/download',

    [string]$PackNamePattern = 'asbuiltdoc-contracts-v{0}.zip',

    [string]$DepsContractsPath = (Join-Path $PSScriptRoot '..\.deps\contracts'),

    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LatestContractsPack {
    param([Parameter(Mandatory = $true)][string]$ReleaseBaseUrl)

    $apiBase = ($ReleaseBaseUrl -replace '/releases/download$', '')
    $latestUri = "$apiBase/releases/latest"
    $latest = Invoke-RestMethod -Uri $latestUri -Headers @{ 'User-Agent' = 'LNV.AsBuiltDoc.Assembler/Sync-AssemblerContractsToRepo' }

    $asset = @($latest.assets | Where-Object { $_.name -match '^asbuiltdoc-contracts-v.+\.zip$' } | Select-Object -First 1)
    if (@($asset).Count -eq 0) {
        throw "Unable to locate contracts zip asset in latest release '$($latest.tag_name)'."
    }

    [ordered]@{
        version = ([string]$latest.tag_name).TrimStart('v')
        tag = [string]$latest.tag_name
        packName = [string]$asset[0].name
        packUrl = [string]$asset[0].browser_download_url
        releaseUrl = [string]$latest.html_url
    }
}

function Initialize-LnvRootLayout {
    param([Parameter(Mandatory = $true)][string]$Root)

    $standardsRoot = Join-Path $Root 'standards'
    $techRoot = Join-Path $Root 'tech'

    if (Test-Path -LiteralPath $standardsRoot -PathType Container) {
        return
    }

    $children = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    if (@($children).Count -eq 1) {
        $inner = $children[0].FullName
        $innerStandardsRoot = Join-Path $inner 'standards'

        if (Test-Path -LiteralPath $innerStandardsRoot -PathType Container) {
            Copy-Item -Recurse -Force -LiteralPath (Join-Path $inner '*') -Destination $Root
            Remove-Item -Recurse -Force -LiteralPath $inner
        }
    }

    if (-not (Test-Path -LiteralPath $standardsRoot -PathType Container)) {
        throw "Contracts layout invalid at '$Root'. Expected 'standards/' at root (and optionally 'tech/')."
    }

    if (-not (Test-Path -LiteralPath $techRoot -PathType Container)) {
        Write-Verbose "Contracts root '$Root' has no 'tech/' folder; continuing with standards-only layout."
    }
}

function Write-Snapshot {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][hashtable]$Snapshot
    )

    $snapshotPath = Join-Path $DestinationPath 'contracts.snapshot.json'
    $Snapshot | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $snapshotPath
    return $snapshotPath
}

if ($Clean -and (Test-Path -LiteralPath $DepsContractsPath -PathType Container)) {
    Remove-Item -Recurse -Force -LiteralPath $DepsContractsPath
}
New-Item -ItemType Directory -Force -Path $DepsContractsPath | Out-Null

if ($ContractsVersion -and $ContractsPackUrl) {
    throw "Specify either -ContractsVersion or -ContractsPackUrl, not both."
}

$invokedWithoutOptions = @($PSBoundParameters.Keys).Count -eq 0

if (-not $invokedWithoutOptions -and -not $ContractsVersion -and -not $ContractsPackUrl) {
    $sourceRoot = (Resolve-Path -LiteralPath $ExportContractsPath -ErrorAction Stop).Path
    Copy-Item -Recurse -Force -Path (Join-Path $sourceRoot '*') -Destination $DepsContractsPath
    Initialize-LnvRootLayout -Root $DepsContractsPath

    $snapshotPath = Write-Snapshot -DestinationPath $DepsContractsPath -Snapshot ([ordered]@{
            schemaVersion = 1
            syncedUtc = (Get-Date).ToUniversalTime().ToString('o')
            source = 'local-export-copy'
            exportContractsPath = $sourceRoot
        })

    [ordered]@{
        status = 'ok'
        mode = 'LocalExport'
        sourceRoot = $sourceRoot
        destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
        snapshotPath = $snapshotPath
    } | ConvertTo-Json -Depth 5
    exit 0
}

$resolvedVersion = $ContractsVersion
$resolvedTag = if ($ContractsVersion) { "v$ContractsVersion" } else { $null }
$releasePageUrl = $null

$packUrl = if ($ContractsPackUrl) {
    $ContractsPackUrl
}
elseif ($ContractsVersion) {
    $zipName = [string]::Format($PackNamePattern, $ContractsVersion)
    "$ReleaseBaseUrl/v$ContractsVersion/$zipName"
}
else {
    $latest = Resolve-LatestContractsPack -ReleaseBaseUrl $ReleaseBaseUrl
    $resolvedVersion = $latest.version
    $resolvedTag = $latest.tag
    $releasePageUrl = $latest.releaseUrl
    Write-Information "Resolved latest contracts release: tag=$($latest.tag), asset=$($latest.packName)" -InformationAction Continue
    $latest.packUrl
}

$zipLeaf = [IO.Path]::GetFileName(($packUrl -split '\?')[0])
if ([string]::IsNullOrWhiteSpace($zipLeaf)) {
    $zipLeaf = 'asbuiltdoc-contracts.zip'
}

$tmpBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
$tmpZip = Join-Path $tmpBase $zipLeaf

Write-Information "Downloading contracts pack: $packUrl" -InformationAction Continue
Invoke-WebRequest -Uri $packUrl -OutFile $tmpZip -UseBasicParsing

Write-Information "Extracting contracts pack to $DepsContractsPath" -InformationAction Continue
Expand-Archive -LiteralPath $tmpZip -DestinationPath $DepsContractsPath -Force
Initialize-LnvRootLayout -Root $DepsContractsPath

$snapshotPath = Write-Snapshot -DestinationPath $DepsContractsPath -Snapshot ([ordered]@{
        schemaVersion = 1
        syncedUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = 'published-pack'
        version = $resolvedVersion
        tag = $resolvedTag
        packUrl = $packUrl
        releaseUrl = $releasePageUrl
        packPath = $tmpZip
    })

[ordered]@{
    status = 'ok'
    mode = if ($ContractsPackUrl) { 'PackUrl' } elseif ($ContractsVersion) { 'PackVersion' } else { 'PackLatest' }
    version = $resolvedVersion
    tag = $resolvedTag
    packUrl = $packUrl
    releaseUrl = $releasePageUrl
    destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
    snapshotPath = $snapshotPath
} | ConvertTo-Json -Depth 5
