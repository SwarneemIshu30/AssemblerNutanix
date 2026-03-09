#!/usr/bin/env pwsh
<#
.SYNOPSIS
Interactive PowerShell launcher for SDT render workflow.
#>
param(
    [Parameter(Mandatory = $false)][string]$BundleRoot,
    [Parameter(Mandatory = $false)][string]$SkeletonRoot,
    [Parameter(Mandatory = $false)][string]$OutputDirectory = './out',
    [Parameter(Mandatory = $false)][string]$ContractsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'

if ([string]::IsNullOrWhiteSpace($BundleRoot)) {
    $BundleRoot = Read-Host 'BundleRoot'
}

if ([string]::IsNullOrWhiteSpace($SkeletonRoot)) {
    $SkeletonRoot = Read-Host 'SkeletonRoot (folder containing *.mapping.json and *.template.txt)'
}

$mapping = Get-ChildItem -LiteralPath $SkeletonRoot -Filter '*.mapping.json' -File | Select-Object -First 1
$template = Get-ChildItem -LiteralPath $SkeletonRoot -Filter '*.template.txt' -File | Select-Object -First 1
if ($null -eq $mapping -or $null -eq $template) {
    throw "Skeleton root '$SkeletonRoot' must contain at least one *.mapping.json and one *.template.txt file."
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$outputPath = Join-Path $OutputDirectory 'assembler-rendered.txt'
$reportPath = Join-Path $OutputDirectory 'assembler-render-report.json'

if ([string]::IsNullOrWhiteSpace($ContractsRoot)) {
    & $invokeScript -BundleRoot $BundleRoot -MappingPath $mapping.FullName -TemplatePath $template.FullName -OutputPath $outputPath -ReportPath $reportPath
}
else {
    & $invokeScript -BundleRoot $BundleRoot -MappingPath $mapping.FullName -TemplatePath $template.FullName -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $ContractsRoot
}
