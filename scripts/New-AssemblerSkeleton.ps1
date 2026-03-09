#!/usr/bin/env pwsh
<#
.SYNOPSIS
Create a local ingest skeleton directory for SDT template work.
#>
param(
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $false)][string]$TechId = 'Lenovo.DE',
    [Parameter(Mandatory = $false)][switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$templateSource = Join-Path $repoRoot (Join-Path 'templates/skeletons' $TechId)
if (-not (Test-Path -LiteralPath $templateSource -PathType Container)) {
    throw "No built-in skeleton exists for tech '$TechId' at '$templateSource'"
}

if (Test-Path -LiteralPath $DestinationRoot -PathType Container) {
    if (-not $Force) {
        throw "Destination '$DestinationRoot' already exists. Re-run with -Force to overwrite."
    }
}
else {
    New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null
}

Copy-Item -Path (Join-Path $templateSource '*') -Destination $DestinationRoot -Recurse -Force

[ordered]@{
    status = 'ok'
    destination = (Resolve-Path -LiteralPath $DestinationRoot).Path
    techId = $TechId
    files = (Get-ChildItem -LiteralPath $DestinationRoot -File | Select-Object -ExpandProperty Name)
} | ConvertTo-Json -Depth 5
