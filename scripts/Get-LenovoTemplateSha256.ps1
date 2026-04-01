#!/usr/bin/env pwsh
<#
.SYNOPSIS
Compute SHA256 for the Lenovo DE skeleton template.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/SK_Lenovo_DE_DRAFT_v0.1.docx'
$resolvedPath = (Resolve-Path -LiteralPath $templatePath).Path
$hash = Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256

[ordered]@{
    path = $resolvedPath
    sha256 = ([string]$hash.Hash).ToLowerInvariant()
} | ConvertTo-Json -Depth 3
