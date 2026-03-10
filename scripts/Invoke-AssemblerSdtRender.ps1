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
    return [ordered]@{ path = $exactPath; autoResolved = $false; reason = $null }
}

function Convert-CellValueToString {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [ValueType]) { return [string]$Value }

    return ($Value | ConvertTo-Json -Depth 10 -Compress)
}


function Format-SizeHuman {
    param([Parameter(Mandatory = $false)]$Bytes)

    if ($null -eq $Bytes) { return '' }
    [double]$value = 0
    if (-not [double]::TryParse([string]$Bytes, [ref]$value)) { return [string]$Bytes }

    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $idx = 0
    while ($value -ge 1024 -and $idx -lt ($units.Count - 1)) {
        $value = $value / 1024
        $idx++
    }
    return ('{0:N2} {1}' -f $value, $units[$idx])
}

function Convert-TableRowsForTag {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    switch ($Tag) {
        'DE_DRIVES_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Slot = $_.slot
                        'Media Type' = $_.driveMediaType
                        Raw = Format-SizeHuman -Bytes $_.rawCapacityBytes
                        Usable = Format-SizeHuman -Bytes $_.usableCapacityBytes
                        Firmware = $_.firmwareVersion
                        Status = $_.status
                        SerialNumber = $_.serialNumber
                    }
                }
            )
        }
        'DE_STORAGE_CONTAINERS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = $_.name
                        ContainerType = $_.containerType
                        RaidLevel = $_.raidLevel
                        DriveMediaType = $_.driveMediaType
                        Total = Format-SizeHuman -Bytes $_.totalBytes
                        Used = Format-SizeHuman -Bytes $_.usedBytes
                        Free = Format-SizeHuman -Bytes $_.freeBytes
                        State = $_.state
                        Status = $_.status
                    }
                }
            )
        }
        'DE_VOLUMES_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = $_.name
                        Size = Format-SizeHuman -Bytes $_.sizeBytes
                        Status = $_.status
                        RaidLevel = $_.raidLevel
                        Container = $_.containerName
                    }
                }
            )
        }
        'DE_CONTROLLERS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Controller = $_.controllerLabel
                        Slot = $_.controllerSlot
                        Status = $_.status
                        AppVersion = $_.appVersion
                        BootVersion = $_.bootVersion
                        SerialNumber = $_.serialNumber
                    }
                }
            )
        }
        default {
            return $Rows
        }
    }
}

function Get-DisplayColumnsForTable {
    param([Parameter(Mandatory = $true)][string[]]$Columns)

    $excluded = @(
        'systemid',
        'controllerref',
        'driveref',
        'volumeref',
        'poolref',
        'trayref',
        'storagesystemref',
        'id'
    )

    $filtered = @(
        $Columns |
            Where-Object {
                $name = [string]$_
                if ([string]::IsNullOrWhiteSpace($name)) { return $false }

                $lower = $name.ToLowerInvariant()
                if ($excluded -contains $lower) { return $false }
                if ($lower.EndsWith('ref')) { return $false }
                if ($lower.EndsWith('id')) { return $false }

                return $true
            }
    )

    if (@($filtered).Count -gt 0) { return $filtered }
    return $Columns
}

function Convert-ValueToTableString {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $false)][string]$Tag
    )

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

    $rows = @(Convert-TableRowsForTag -Tag $Tag -Rows $rows)

    $allColumns = @($rows[0].PSObject.Properties.Name)
    $displayColumns = Get-DisplayColumnsForTable -Columns $allColumns

    if (@($displayColumns).Count -gt 0) {
        return (($rows | Select-Object -Property $displayColumns | Format-Table -AutoSize | Out-String).TrimEnd())
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
        return (Convert-ValueToTableString -Value $Value -Tag $Tag)
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

$stageMap = [ordered]@{}
foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
    $stage = [ordered]@{ name = $stageName; status = 'SKIPPED'; startedUtc = $null; completedUtc = $null; details = $null }
    $stageMap[$stageName] = $stage
    $stageList.Add($stage)
}

function Start-RenderStage {
    param([Parameter(Mandatory = $true)][hashtable]$Stage)
    $Stage.startedUtc = Get-UtcTimestamp
    $Stage.completedUtc = $null
    $Stage.status = 'OK'
}

function Complete-RenderStage {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][hashtable]$Details
    )
    $Stage.status = $Status
    $Stage.completedUtc = Get-UtcTimestamp
    if ($PSBoundParameters.ContainsKey('Details')) { $Stage.details = $Details }
}

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $effectiveContractsRoot = Resolve-AssemblerContractsRoot -ContractsRoot $ContractsRoot -RepoRoot $repoRoot
    $mappingSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards') 'mapping.dataset-to-sdt.schema.v1.json'

    Start-RenderStage -Stage $stageMap.Load
    $mapping = Read-JsonFile -Path $MappingPath
    $mappingSchema = Read-JsonFile -Path $mappingSchemaPath
    $templateText = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8

    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-JsonFile -Path $manifestPath
        $bundleId = $manifest.bundleId
    }
    Complete-RenderStage -Stage $stageMap.Load -Status 'OK' -Details ([ordered]@{ mappingPath = $MappingPath; templatePath = $TemplatePath; contractsRoot = $effectiveContractsRoot; mappingSchemaPath = $mappingSchemaPath })

    Start-RenderStage -Stage $stageMap.Validate
    $mappingErrors = @(Test-MappingMinimumContract -Mapping $mapping -Schema $mappingSchema)
    foreach ($mappingError in $mappingErrors) {
        $issues.Add([ordered]@{ code = 'ASB-ASM-CONTRACT-VALIDATE'; severity = 'ERROR'; message = $mappingError; path = $MappingPath })
    }
    if (@($mappingErrors).Count -gt 0) {
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Mapping contract validation failed.'
    }
    Complete-RenderStage -Stage $stageMap.Validate -Status 'OK' -Details ([ordered]@{ mappingCount = @($mapping.mappings).Count })

    Start-RenderStage -Stage $stageMap.Transform
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
            $resolved = $dataset
            $selectorFailed = $false
            foreach ($selector in $selectors) {
                $resolved = Resolve-Selector -InputObject $resolved -Selector ([string]$selector)
                if ($null -eq $resolved) {
                    $selectorFailed = $true
                    break
                }
            }

            if ($selectorFailed) {
                $selectorChain = ($selectors | ForEach-Object { [string]$_ }) -join ' -> '
                $severity = if ($entry.required) { 'ERROR' } else { 'WARN' }
                $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-SELECTOR-NOMATCH'; severity = $severity; message = "Selector chain '$selectorChain' did not resolve for tag '$tag'"; path = $datasetPath })
                if ($severity -eq 'ERROR') { $status = 'ERROR' }
                continue
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
        $matches.Add([ordered]@{ tag = $tag; dataset = [string]$entry.dataset; selector = if (@($selectors).Count -gt 0) { (($selectors | ForEach-Object { [string]$_ }) -join ' -> ') } else { '' }; valuePreview = $valuePreview })
    }

    $transformStatus = if ($status -eq 'ERROR') { 'ERROR' } elseif (@($issues | Where-Object { $_.severity -eq 'WARN' }).Count -gt 0) { 'WARN' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Transform -Status $transformStatus -Details ([ordered]@{ tagsResolved = $replaceByTag.Count; matches = $matches.Count })

    Start-RenderStage -Stage $stageMap.Render
    $rendered = $templateText
    foreach ($tag in $replaceByTag.Keys) {
        $token = "<<SDT:$tag>>"
        $rendered = $rendered.Replace($token, [string]$replaceByTag[$tag])
    }
    $renderStatus = if ($status -eq 'ERROR') { 'ERROR' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Render -Status $renderStatus -Details ([ordered]@{ tagsPopulated = $replaceByTag.Count })

    Start-RenderStage -Stage $stageMap.Finalize
    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $rendered -Encoding UTF8
    $outputs.Add([ordered]@{ path = $OutputPath; type = 'text/template-rendered' })
    $finalizeStatus = if ($status -eq 'ERROR') { 'ERROR' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Finalize -Status $finalizeStatus -Details ([ordered]@{ outputPath = $OutputPath })
}
catch {
    $status = 'ERROR'
    $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-UNHANDLED'; severity = 'ERROR'; message = $_.Exception.Message; path = $null })

    foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
        $stage = $stageMap[$stageName]
        if ($null -ne $stage.startedUtc -and $null -eq $stage.completedUtc) {
            Complete-RenderStage -Stage $stage -Status 'ERROR'
            break
        }
    }
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
