#!/usr/bin/env pwsh
<#
.SYNOPSIS
Create a runtime-oriented assembler package zip from an explicit include list.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = 'dist',
    [string]$PackageName = 'LNV.AsBuiltDoc.Assembler-runtime',
    [string]$PackageVersion = (Get-Date -AsUTC).ToString('yyyy.MM.dd.HHmmss'),
    [ValidateSet('release', 'ci', 'dev')]
    [string]$BuildChannel = 'dev',
    [string]$IncludeFile = '.packaging/assembler-package.include'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [switch]$AllowMissing
    )

    $candidate = Join-Path $RepoRoot $RelativePath
    $resolved = [System.IO.Path]::GetFullPath($candidate)
    $repoRootWithSeparator = $RepoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

    $isRepoRoot = [string]::Equals($resolved, $RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $isUnderRepoRoot = $resolved.StartsWith($repoRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not ($isRepoRoot -or $isUnderRepoRoot)) {
        throw "Path '$RelativePath' resolves outside the repository root."
    }

    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $resolved)) {
        throw "Path not found: $RelativePath"
    }

    return $resolved
}

function Get-RepoRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return [System.IO.Path]::GetRelativePath($RepoRoot, $Path).Replace('\', '/')
}

function Get-GitValue {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    try {
        $value = & git -C $RepoRoot @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ''
        }

        return ([string]$value).Trim()
    }
    catch {
        return ''
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputRoot = Resolve-RepoRelativePath -RepoRoot $repoRoot -RelativePath $OutputDir -AllowMissing
$stagingRoot = Resolve-RepoRelativePath -RepoRoot $repoRoot -RelativePath '.packaging/staging' -AllowMissing
$includeFilePath = Resolve-RepoRelativePath -RepoRoot $repoRoot -RelativePath $IncludeFile
$stageDirName = '{0}-{1}-{2}' -f $PackageName, $PackageVersion, ([guid]::NewGuid().ToString('N'))
$stageDir = Join-Path $stagingRoot $stageDirName
$cleanupStageDir = $false

try {
    $includes = @(
        Get-Content -LiteralPath $includeFilePath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )

    if ($includes.Count -eq 0) {
        throw "Include file '$IncludeFile' had no entries."
    }

    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    $cleanupStageDir = $true
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    $resolvedFiles = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $includes) {
        $full = Resolve-RepoRelativePath -RepoRoot $repoRoot -RelativePath $entry

        $items = if (Test-Path -LiteralPath $full -PathType Container) {
            Get-ChildItem -LiteralPath $full -Recurse -File
        }
        else {
            @(Get-Item -LiteralPath $full)
        }

        foreach ($item in $items) {
            $itemPath = [System.IO.Path]::GetFullPath($item.FullName)
            $null = Resolve-RepoRelativePath -RepoRoot $repoRoot -RelativePath (Get-RepoRelativePath -RepoRoot $repoRoot -Path $itemPath)
            $resolvedFiles.Add($itemPath)
        }
    }

    $resolvedFiles = @($resolvedFiles | Sort-Object -Unique)
    foreach ($src in $resolvedFiles) {
        $relative = Get-RepoRelativePath -RepoRoot $repoRoot -Path $src
        $dest = Join-Path $stageDir $relative
        $destParent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }

        Copy-Item -LiteralPath $src -Destination $dest -Force
    }

    $zipName = "$PackageName-$PackageVersion.zip"
    $zipPath = Join-Path $outputRoot $zipName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force

    $repoUrl = Get-GitValue -RepoRoot $repoRoot -Arguments @('remote', 'get-url', 'origin')
    $sourceCommit = Get-GitValue -RepoRoot $repoRoot -Arguments @('rev-parse', 'HEAD')
    $sourceRef = Get-GitValue -RepoRoot $repoRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $contractsRoot = '.deps/contracts'
    $contractsSnapshotPath = '.deps/contracts/contracts.snapshot.json'
    $contractsSnapshotFullPath = Resolve-RepoRelativePath -RepoRoot $repoRoot -RelativePath $contractsSnapshotPath -AllowMissing

    $bundledContracts = [ordered]@{
        root = $contractsRoot
        snapshotPath = $contractsSnapshotPath
        snapshotExists = (Test-Path -LiteralPath $contractsSnapshotFullPath -PathType Leaf)
    }

    if ($bundledContracts.snapshotExists) {
        try {
            $snapshot = Get-Content -LiteralPath $contractsSnapshotFullPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if ($snapshot.ContainsKey('version')) {
                $bundledContracts.version = [string]$snapshot.version
            }
            if ($snapshot.ContainsKey('tag')) {
                $bundledContracts.tag = [string]$snapshot.tag
            }
            if ($snapshot.ContainsKey('source')) {
                $bundledContracts.source = [string]$snapshot.source
            }
            if ($snapshot.ContainsKey('syncedUtc')) {
                $bundledContracts.syncedUtc = [string]$snapshot.syncedUtc
            }
            if ($snapshot.ContainsKey('packUrl')) {
                $bundledContracts.packUrl = [string]$snapshot.packUrl
            }
            if ($snapshot.ContainsKey('releaseUrl')) {
                $bundledContracts.releaseUrl = [string]$snapshot.releaseUrl
            }
        }
        catch {
            $bundledContracts.snapshotReadError = $_.Exception.Message
        }
    }

    $manifest = [ordered]@{
        packageName = $PackageName
        packageVersion = $PackageVersion
        buildChannel = $BuildChannel
        createdUtc = (Get-Date -AsUTC).ToString('o')
        sourceRepository = $repoUrl
        sourceCommit = $sourceCommit
        sourceRef = $sourceRef
        includeFile = $IncludeFile
        zipPath = Get-RepoRelativePath -RepoRoot $repoRoot -Path $zipPath
        fileCount = $resolvedFiles.Count
        bundledContracts = $bundledContracts
    }

    $manifestPath = Join-Path $outputRoot 'package.manifest.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

    Write-Host "Package created: $zipPath"
    Write-Host "Manifest: $manifestPath"
}
finally {
    if ($cleanupStageDir -and (Test-Path -LiteralPath $stageDir -PathType Container)) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
