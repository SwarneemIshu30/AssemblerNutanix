#!/usr/bin/env pwsh
<#
.SYNOPSIS
Populate SDT placeholder tags from a Direct-v1 bundle and mapping contract.
#>
param(
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$MappingPath,
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $false)][string]$ReportPath,
    [Parameter(Mandatory = $false)][string]$ContractsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp { (Get-Date).ToUniversalTime().ToString('o') }

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }

    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
}

function Resolve-AssemblerContractsRoot {
    param(
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ContractsRoot)) {
        if (-not (Test-Path -LiteralPath $ContractsRoot -PathType Container)) {
            throw "ContractsRoot '$ContractsRoot' was provided but does not exist."
        }
        return (Resolve-Path -LiteralPath $ContractsRoot).Path
    }

    $candidates = @(
        (Join-Path $RepoRoot '.deps/contracts'),
        (Join-Path $RepoRoot 'export/repo-ready/contracts')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Unable to resolve contracts root. Checked: $($candidates -join ', ')."
}

function Test-MappingMinimumContract {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Mapping,
        [Parameter(Mandatory = $true)][hashtable]$Schema
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($requiredKey in ($Schema.required ?? @())) {
        if (-not $Mapping.ContainsKey([string]$requiredKey)) {
            $errors.Add("ASB-ASM-CONTRACT-MAPPING-REQUIRED: missing required property '$requiredKey'")
        }
    }

    $schemaProperties = $Schema.properties
    if ($null -ne $schemaProperties) {
        foreach ($entry in $schemaProperties.GetEnumerator()) {
            $propertyName = [string]$entry.Key
            $propertySchema = $entry.Value
            if ($Mapping.ContainsKey($propertyName) -and $propertySchema.ContainsKey('const')) {
                if ($Mapping[$propertyName] -ne $propertySchema.const) {
                    $errors.Add("ASB-ASM-CONTRACT-MAPPING-CONST: property '$propertyName' must be '$($propertySchema.const)'")
                }
            }
        }
    }

    if (-not $Mapping.ContainsKey('mappings') -or -not ($Mapping.mappings -is [System.Collections.IList])) {
        $errors.Add("ASB-ASM-CONTRACT-MAPPING-TYPE: 'mappings' must be an array")
        return @($errors.ToArray())
    }

    if (@($Mapping.mappings).Count -lt 1) {
        $errors.Add("ASB-ASM-CONTRACT-MAPPING-MINITEMS: 'mappings' must contain at least 1 item")
    }

    foreach ($entry in @($Mapping.mappings)) {
        if (-not $entry.ContainsKey('dataset') -or [string]::IsNullOrWhiteSpace([string]$entry.dataset)) {
            $errors.Add("ASB-ASM-CONTRACT-MAPPING-DATASET: each mapping requires non-empty 'dataset'")
            continue
        }

        $hasTopLevelTag = $entry.ContainsKey('sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$entry.sdtTag)
        $hasTargetTag = $entry.ContainsKey('target') -and $entry.target.ContainsKey('sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$entry.target.sdtTag)
        if (-not $hasTopLevelTag -and -not $hasTargetTag) {
            $errors.Add("ASB-ASM-CONTRACT-MAPPING-TAG: mapping for dataset '$($entry.dataset)' requires 'sdtTag' or 'target.sdtTag'")
        }
    }

    return @($errors.ToArray())
}

function Resolve-Selector {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $current = $InputObject
    foreach ($segment in $Selector.Split('.')) {
        if ($null -eq $current) {
            return $null
        }

        if ($current -is [hashtable]) {
            if (-not $current.ContainsKey($segment)) {
                return $null
            }
            $current = $current[$segment]
            continue
        }

        if ($current -is [System.Collections.IList]) {
            [int]$idx = 0
            if (-not [int]::TryParse($segment, [ref]$idx)) {
                return $null
            }
            if ($idx -lt 0 -or $idx -ge $current.Count) {
                return $null
            }
            $current = $current[$idx]
            continue
        }

        return $null
    }

    return $current
}


function Resolve-DatasetFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$DatasetRelativePath,
        [Parameter(Mandatory = $false)][string]$TechId
    )

    $exactPath = Join-Path $BundleRoot $DatasetRelativePath
    if (Test-Path -LiteralPath $exactPath -PathType Leaf) {
        return [ordered]@{ path = $exactPath; autoResolved = $false; reason = $null }
    }

    $leafName = [System.IO.Path]::GetFileName($DatasetRelativePath)
    if ([string]::IsNullOrWhiteSpace($leafName)) {
        return [ordered]@{ path = $exactPath; autoResolved = $false; reason = 'missing leaf filename in dataset path' }
    }

    $searchRoot = if (-not [string]::IsNullOrWhiteSpace($TechId)) {
        Join-Path (Join-Path $BundleRoot 'datasets') $TechId
    }
    else {
        Join-Path $BundleRoot 'datasets'
    }

    if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
        return [ordered]@{ path = $exactPath; autoResolved = $false; reason = "search root '$searchRoot' does not exist" }
    }

    $matches = @(
        Get-ChildItem -LiteralPath $searchRoot -Recurse -File -Filter $leafName -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    )

    if (@($matches).Count -eq 0) {
        return [ordered]@{ path = $exactPath; autoResolved = $false; reason = "no '$leafName' found under '$searchRoot'" }
    }

    $normalizedRelative = $DatasetRelativePath.Replace('\', '/').ToLowerInvariant()
    $sorted = @(
        $matches |
            Sort-Object -Property @{ Expression = {
                $candidate = [string]$_
                $candidateNorm = $candidate.Replace('\', '/').ToLowerInvariant()
                if ($candidateNorm.EndsWith($normalizedRelative)) { return 0 }
                if ($candidateNorm.Contains('/_multi/')) { return 1 }
                return 2
            } }, @{ Expression = { [string]$_ } }
    )

    $selected = [string]$sorted[0]
    return [ordered]@{ path = $selected; autoResolved = $true; reason = "resolved missing dataset path '$DatasetRelativePath' to '$selected' from $(@($matches).Count) candidate(s)" }
}

function Convert-CellValueToString {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [ValueType]) { return [string]$Value }

    return ($Value | ConvertTo-Json -Depth 10 -Compress)
}

function Convert-ValueToTableString {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return '' }

    $rows = @()
    if ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) {
            if ($item -is [hashtable]) {
                $row = [ordered]@{}
                foreach ($key in $item.Keys) {
                    $row[[string]$key] = Convert-CellValueToString -Value $item[$key]
                }
                $rows += [pscustomobject]$row
            }
            else {
                $rows += [pscustomobject]([ordered]@{ value = Convert-CellValueToString -Value $item })
            }
        }
    }
    elseif ($Value -is [hashtable]) {
        $row = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $row[[string]$key] = Convert-CellValueToString -Value $Value[$key]
        }
        $rows = @([pscustomobject]$row)
    }

    if (@($rows).Count -eq 0) {
        return (Convert-CellValueToString -Value $Value)
    }

    return (($rows | Format-Table -AutoSize | Out-String).TrimEnd())
}

function Convert-ValueToString {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $false)][string]$Tag
    )

    if ($null -eq $Value) {
        return ''
    }
    if (-not [string]::IsNullOrWhiteSpace($Tag) -and $Tag.EndsWith('_TABLE_JSON')) {
        return (Convert-ValueToTableString -Value $Value)
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [ValueType]) {
        return [string]$Value
    }

    return ($Value | ConvertTo-Json -Depth 10 -Compress)
}

$startedUtc = Get-UtcTimestamp
$issues = [System.Collections.Generic.List[hashtable]]::new()
$stageList = [System.Collections.Generic.List[hashtable]]::new()
$outputs = [System.Collections.Generic.List[hashtable]]::new()
$matches = [System.Collections.Generic.List[hashtable]]::new()
$status = 'OK'
$bundleId = $null

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $effectiveContractsRoot = Resolve-AssemblerContractsRoot -ContractsRoot $ContractsRoot -RepoRoot $repoRoot
    $mappingSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards') 'mapping.dataset-to-sdt.schema.v1.json'

    $loadStart = Get-UtcTimestamp
    $mapping = Read-JsonFile -Path $MappingPath
    $mappingSchema = Read-JsonFile -Path $mappingSchemaPath
    $templateText = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8

    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-JsonFile -Path $manifestPath
        $bundleId = $manifest.bundleId
    }

    $stageList.Add([ordered]@{
        name = 'LoadInputs'; status = 'OK'; startedUtc = $loadStart; completedUtc = Get-UtcTimestamp; details = [ordered]@{ mappingPath = $MappingPath; templatePath = $TemplatePath; contractsRoot = $effectiveContractsRoot; mappingSchemaPath = $mappingSchemaPath }
    })

    $validateStart = Get-UtcTimestamp
    $mappingErrors = @(Test-MappingMinimumContract -Mapping $mapping -Schema $mappingSchema)
    foreach ($mappingError in $mappingErrors) {
        $issues.Add([ordered]@{ code = 'ASB-ASM-CONTRACT-VALIDATE'; severity = 'ERROR'; message = $mappingError; path = $MappingPath })
    }
    if (@($mappingErrors).Count -gt 0) {
        $status = 'ERROR'
        throw 'Mapping contract validation failed.'
    }

    $stageList.Add([ordered]@{
        name = 'ValidateContract'; status = 'OK'; startedUtc = $validateStart; completedUtc = Get-UtcTimestamp; details = [ordered]@{ mappingSchemaPath = $mappingSchemaPath }
    })

    $replaceByTag = @{}
    foreach ($entry in @($mapping.mappings)) {
        $tag = if ($entry.ContainsKey('sdtTag')) { [string]$entry.sdtTag } elseif ($entry.ContainsKey('target') -and $entry.target.ContainsKey('sdtTag')) { [string]$entry.target.sdtTag } else { '' }
        if ([string]::IsNullOrWhiteSpace($tag)) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-MAPPING-NOTAG'; severity = 'WARN'; message = "Skipping mapping with missing sdtTag for dataset '$($entry.dataset)'"; path = $MappingPath })
            continue
        }

        $datasetResolution = Resolve-DatasetFilePath -BundleRoot $BundleRoot -DatasetRelativePath ([string]$entry.dataset) -TechId ([string]$mapping.techId)
        $datasetPath = [string]$datasetResolution.path
        if (-not (Test-Path -LiteralPath $datasetPath -PathType Leaf)) {
            $severity = if ($entry.required) { 'ERROR' } else { 'WARN' }
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-DATASET-MISSING'; severity = $severity; message = "Dataset '$($entry.dataset)' not found for tag '$tag'"; path = $datasetPath })
            if ($severity -eq 'ERROR') { $status = 'ERROR' }
            continue
        }
        if ($datasetResolution.autoResolved) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-DATASET-AUTORESOLVED'; severity = 'WARN'; message = [string]$datasetResolution.reason; path = $datasetPath })
        }

        $dataset = Read-JsonFile -Path $datasetPath
        $resolved = $null
        $selectors = @($entry.selectors)
        if (@($selectors).Count -gt 0) {
            foreach ($selector in $selectors) {
                $candidate = Resolve-Selector -InputObject $dataset -Selector ([string]$selector)
                if ($null -ne $candidate) {
                    $resolved = $candidate
                    break
                }
            }
        }
        else {
            $resolved = $dataset
        }

        if ($null -eq $resolved -and $entry.required) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-SELECTOR-NOMATCH'; severity = 'ERROR'; message = "No selector match found for required tag '$tag'"; path = $datasetPath })
            $status = 'ERROR'
            continue
        }

        $resolvedText = Convert-ValueToString -Value $resolved -Tag $tag
        $replaceByTag[$tag] = $resolvedText
        $valuePreview = if ($resolvedText.Length -gt 80) { $resolvedText.Substring(0, 80) + '...' } else { $resolvedText }
        $matches.Add([ordered]@{ tag = $tag; dataset = [string]$entry.dataset; selector = if (@($selectors).Count -gt 0) { [string]$selectors[0] } else { '' }; valuePreview = $valuePreview })
    }

    $renderStart = Get-UtcTimestamp
    $rendered = $templateText
    foreach ($tag in $replaceByTag.Keys) {
        $token = "<<SDT:$tag>>"
        $rendered = $rendered.Replace($token, [string]$replaceByTag[$tag])
    }

    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $rendered -Encoding UTF8
    $outputs.Add([ordered]@{ path = $OutputPath; type = 'text/template-rendered' })

    $stageList.Add([ordered]@{
        name = 'RenderSdt'; status = if ($status -eq 'ERROR') { 'ERROR' } else { 'OK' }; startedUtc = $renderStart; completedUtc = Get-UtcTimestamp; details = [ordered]@{ tagsPopulated = $replaceByTag.Count }
    })
}
catch {
    $status = 'ERROR'
    $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-UNHANDLED'; severity = 'ERROR'; message = $_.Exception.Message; path = $null })
    $stageList.Add([ordered]@{ name = 'Unhandled'; status = 'ERROR'; startedUtc = Get-UtcTimestamp; completedUtc = Get-UtcTimestamp; details = $null })
}

if ($status -ne 'ERROR' -and @($issues | Where-Object { $_.severity -eq 'WARN' }).Count -gt 0) {
    $status = 'PARTIAL'
}

$report = [ordered]@{
    schemaVersion = 1
    status = $status
    startedUtc = $startedUtc
    completedUtc = Get-UtcTimestamp
    bundleId = $bundleId
    stages = $stageList
    issues = $issues
    matches = $matches
    outputs = $outputs
}

$reportJson = $report | ConvertTo-Json -Depth 10
if ($ReportPath) {
    $reportDir = Split-Path -Path $ReportPath -Parent
    if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }
    Set-Content -LiteralPath $ReportPath -Value $reportJson -Encoding UTF8
}

$reportJson
if ($status -eq 'ERROR') {
    exit 1
}
