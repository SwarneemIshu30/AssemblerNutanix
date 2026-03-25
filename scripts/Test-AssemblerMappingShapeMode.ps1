#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('legacy', 'dual', 'target')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$ContractMappingPath,
    [Parameter(Mandatory = $true)][string]$RuntimeMappingPath,
    [Parameter(Mandatory = $false)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Dictionary {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return $Value }

    if ($null -ne $Value.PSObject) {
        $converted = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            $converted[[string]$property.Name] = $property.Value
        }
        return $converted
    }

    return $null
}

function Get-MappingEntryShape {
    param([Parameter(Mandatory = $true)]$Entry)

    $entryTable = ConvertTo-Dictionary -Value $Entry
    if ($null -eq $entryTable) { return 'invalid' }

    $hasTopLevelTag = $entryTable.ContainsKey('sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$entryTable.sdtTag)
    $hasTargetTag = $false
    if ($entryTable.ContainsKey('target')) {
        $targetTable = ConvertTo-Dictionary -Value $entryTable.target
        if ($null -ne $targetTable) {
            $hasTargetTag = $targetTable.ContainsKey('sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$targetTable.sdtTag)
            if (-not $hasTargetTag) {
                $hasTargetTag = (
                    $targetTable.ContainsKey('kind') -and -not [string]::IsNullOrWhiteSpace([string]$targetTable.kind) -and
                    $targetTable.ContainsKey('path') -and -not [string]::IsNullOrWhiteSpace([string]$targetTable.path)
                )
            }
        }
    }

    if ($hasTopLevelTag -and $hasTargetTag) { return 'dual' }
    if ($hasTopLevelTag) { return 'sdtTag-only' }
    if ($hasTargetTag) { return 'target-only' }
    return 'invalid'
}

function Get-MappingShapeDashboard {
    param([Parameter(Mandatory = $true)]$Mappings)

    $dashboard = [ordered]@{
        total = 0
        sdtTagOnly = 0
        dual = 0
        targetOnly = 0
        invalid = 0
    }

    foreach ($entry in @($Mappings)) {
        $dashboard.total++
        $shape = Get-MappingEntryShape -Entry $entry
        switch ($shape) {
            'sdtTag-only' { $dashboard.sdtTagOnly++ }
            'dual' { $dashboard.dual++ }
            'target-only' { $dashboard.targetOnly++ }
            default { $dashboard.invalid++ }
        }
    }

    return $dashboard
}

function Assert-MappingShape {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('legacy', 'dual', 'target')][string]$Mode,
        [Parameter(Mandatory = $true)]$Mappings,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $dashboard = Get-MappingShapeDashboard -Mappings $Mappings
    switch ($Mode) {
        'legacy' {
            if ($dashboard.dual -gt 0 -or $dashboard.targetOnly -gt 0 -or $dashboard.invalid -gt 0) {
                throw "Mode '$Mode' validation failed for $Label. Counts: sdtTagOnly=$($dashboard.sdtTagOnly), dual=$($dashboard.dual), targetOnly=$($dashboard.targetOnly), invalid=$($dashboard.invalid)."
            }
        }
        'dual' {
            if ($dashboard.sdtTagOnly -gt 0 -or $dashboard.targetOnly -gt 0 -or $dashboard.invalid -gt 0) {
                throw "Mode '$Mode' validation failed for $Label. Counts: sdtTagOnly=$($dashboard.sdtTagOnly), dual=$($dashboard.dual), targetOnly=$($dashboard.targetOnly), invalid=$($dashboard.invalid)."
            }
        }
        'target' {
            if ($dashboard.sdtTagOnly -gt 0 -or $dashboard.dual -gt 0 -or $dashboard.invalid -gt 0) {
                throw "Mode '$Mode' validation failed for $Label. Counts: sdtTagOnly=$($dashboard.sdtTagOnly), dual=$($dashboard.dual), targetOnly=$($dashboard.targetOnly), invalid=$($dashboard.invalid)."
            }
        }
    }

    return $dashboard
}

function Read-Mapping {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Mapping file not found: $Path"
    }

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.yaml', '.yml')) {
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
            throw "ConvertFrom-Yaml is required to read YAML mapping files ($Path)."
        }
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Yaml
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
}

$exitCode = 0
$result = $null

try {
    $contract = Read-Mapping -Path $ContractMappingPath
    $runtime = Read-Mapping -Path $RuntimeMappingPath

    $contractDashboard = Assert-MappingShape -Mode $Mode -Mappings @($contract.mappings) -Label "contract:$ContractMappingPath"
    $runtimeDashboard = Assert-MappingShape -Mode $Mode -Mappings @($runtime.mappings) -Label "runtime:$RuntimeMappingPath"

    $result = [ordered]@{
        status = 'ok'
        mode = $Mode
        contractMappingPath = $ContractMappingPath
        runtimeMappingPath = $RuntimeMappingPath
        dashboard = [ordered]@{
            contract = $contractDashboard
            runtime = $runtimeDashboard
        }
    }
}
catch {
    $exitCode = 1
    $result = [ordered]@{
        status = 'error'
        mode = $Mode
        contractMappingPath = $ContractMappingPath
        runtimeMappingPath = $RuntimeMappingPath
        message = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
    }
}

$json = $result | ConvertTo-Json -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputDir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Encoding UTF8 -Value $json
}

$json
exit $exitCode
