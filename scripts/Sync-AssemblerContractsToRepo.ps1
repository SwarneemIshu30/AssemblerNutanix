#!/usr/bin/env pwsh
<#
.SYNOPSIS
Sync Assembler contracts into deterministic local ingest path (`.deps/contracts`).

.DESCRIPTION
Supports two modes only:
1) Local export copy (default): `export/repo-ready/contracts` -> `.deps/contracts`
2) Published release pack sync: download/extract zip from contracts release
#>

[CmdletBinding(DefaultParameterSetName = 'LocalExport')]
param(
    [Parameter(ParameterSetName = 'LocalExport')]
    [string]$ExportContractsPath = (Join-Path $PSScriptRoot '..\export\repo-ready\contracts'),

    [Parameter(ParameterSetName = 'PackVersion', Mandatory = $true)]
    [string]$ContractsVersion,

    [Parameter(ParameterSetName = 'PackUrl', Mandatory = $true)]
    [string]$ContractsPackUrl,

    [Parameter(ParameterSetName = 'PackVersion')]
    [string]$ReleaseBaseUrl = 'https://github.com/LNV-AsBuiltDoc/LNV.AsBuiltDoc.Contracts/releases/download',

    [Parameter(ParameterSetName = 'PackVersion')]
    [string]$PackNamePattern = 'asbuiltdoc-contracts-v{0}.zip',

    [string]$DepsContractsPath = (Join-Path $PSScriptRoot '..\.deps\contracts'),

    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-LnvRootLayout {
    param([Parameter(Mandatory = $true)][string]$Root)

    $standardsRoot = Join-Path $Root 'standards'
    $techRoot = Join-Path $Root 'tech'

    if ((Test-Path -LiteralPath $standardsRoot -PathType Container) -and (Test-Path -LiteralPath $techRoot -PathType Container)) {
        return
    }

    $children = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    if ($children.Count -eq 1) {
        $inner = $children[0].FullName
        $innerStandardsRoot = Join-Path $inner 'standards'
        $innerTechRoot = Join-Path $inner 'tech'

        if ((Test-Path -LiteralPath $innerStandardsRoot -PathType Container) -and (Test-Path -LiteralPath $innerTechRoot -PathType Container)) {
            Copy-Item -Recurse -Force -LiteralPath (Join-Path $inner '*') -Destination $Root
            Remove-Item -Recurse -Force -LiteralPath $inner
        }
    }

    if (-not (Test-Path -LiteralPath $standardsRoot -PathType Container) -or -not (Test-Path -LiteralPath $techRoot -PathType Container)) {
        throw "Contracts layout invalid at '$Root'. Expected 'standards/' and 'tech/' at root."
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

if ($PSCmdlet.ParameterSetName -eq 'LocalExport') {
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

$packUrl = if ($PSCmdlet.ParameterSetName -eq 'PackUrl') {
    $ContractsPackUrl
}
else {
    $zipName = [string]::Format($PackNamePattern, $ContractsVersion)
    "$ReleaseBaseUrl/v$ContractsVersion/$zipName"
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
        version = if ($PSCmdlet.ParameterSetName -eq 'PackVersion') { $ContractsVersion } else { $null }
        packUrl = $packUrl
        packPath = $tmpZip
    })

[ordered]@{
    status = 'ok'
    mode = if ($PSCmdlet.ParameterSetName -eq 'PackVersion') { 'PackVersion' } else { 'PackUrl' }
    destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
    snapshotPath = $snapshotPath
} | ConvertTo-Json -Depth 5
