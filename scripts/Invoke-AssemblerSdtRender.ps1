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

Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerSchemaValidation.psm1') -Force

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
        (Join-Path $RepoRoot '.deps/contracts')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Unable to resolve contracts root. Checked: $($candidates -join ', ')."
}

function Resolve-Selector {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $current = $InputObject
    $resolved = $true
    foreach ($segment in $Selector.Split('.')) {
        if ($null -eq $current) {
            $resolved = $false
            break
        }

        if ($current -is [hashtable]) {
            if (-not $current.ContainsKey($segment)) {
                $resolved = $false
                break
            }
            $current = $current[$segment]
            continue
        }

        if ($current -is [System.Collections.IList]) {
            [int]$idx = 0
            if (-not [int]::TryParse($segment, [ref]$idx)) {
                $resolved = $false
                break
            }
            if ($idx -lt 0 -or $idx -ge $current.Count) {
                $resolved = $false
                break
            }
            $current = $current[$idx]
            continue
        }

        $resolved = $false
        break
    }

    return [ordered]@{
        found = $resolved
        value = $current
        valueIsNull = ($resolved -and $null -eq $current)
        valueIsEmptyArray = ($resolved -and $current -is [System.Array] -and $current.Length -eq 0)
    }
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

function Test-DatasetEnvelope {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Dataset,
        [Parameter(Mandatory = $true)][string]$DatasetPath
    )

    # Validation rules are sourced from:
    # .deps/contracts/standards/architecture.direct-v1.collector-contracts.md
    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not $Dataset.ContainsKey('schema_version') -or [string]::IsNullOrWhiteSpace([string]$Dataset.schema_version)) {
        $errors.Add("Dataset envelope missing required field 'schema_version'")
    }
    elseif ([string]$Dataset.schema_version -ne 'lnv.collector.dataset.v1') {
        $errors.Add("Dataset envelope schema_version must be 'lnv.collector.dataset.v1' (got '$($Dataset.schema_version)')")
    }

    foreach ($requiredField in @('collector', 'source', 'dataset', 'item_count', 'items')) {
        if (-not $Dataset.ContainsKey($requiredField)) {
            $errors.Add("Dataset envelope missing required field '$requiredField'")
        }
    }

    if ($Dataset.ContainsKey('items') -and $Dataset.items -is [System.Collections.IList]) {
        [int]$itemCount = 0
        if (-not [int]::TryParse([string]$Dataset.item_count, [ref]$itemCount)) {
            $errors.Add("Dataset envelope field 'item_count' must be an integer when 'items' is an array")
        }
        elseif ($itemCount -ne @($Dataset.items).Count) {
            $errors.Add("Dataset envelope item_count ($itemCount) must equal items.Length (@($Dataset.items).Count)")
        }
    }

    return @($errors.ToArray())
}

function Test-LegacySummaryCompatibilityDataset {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Dataset,
        [Parameter(Mandatory = $true)][string]$DatasetPath
    )

    if ([string]::IsNullOrWhiteSpace($DatasetPath)) { return $false }
    if ([System.IO.Path]::GetFileName($DatasetPath) -ne 'run_summary.json') { return $false }
    if ($Dataset.ContainsKey('schema_version') -or $Dataset.ContainsKey('items')) { return $false }

    foreach ($requiredField in @('collectedUtc', 'mode', 'controller', 'port', 'systemCount')) {
        if (-not $Dataset.ContainsKey($requiredField)) {
            return $false
        }
    }

    return $true
}

function Resolve-SelectorWithSummaryCompatibility {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Dataset,
        [Parameter(Mandatory = $true)][string[]]$Selectors,
        [Parameter(Mandatory = $true)][string]$DatasetPath
    )

    $resolved = $Dataset
    foreach ($selector in $Selectors) {
        $resolution = Resolve-Selector -InputObject $resolved -Selector ([string]$selector)
        if (-not $resolution.found) {
            $summaryItem = $null
            if (
                [System.IO.Path]::GetFileName($DatasetPath) -eq 'run_summary.json' -and
                $Dataset.ContainsKey('items') -and
                $Dataset.items -is [System.Collections.IList] -and
                @($Dataset.items).Count -eq 1 -and
                $Dataset.items[0] -is [hashtable] -and
                -not [string]::IsNullOrWhiteSpace([string]$selector) -and
                -not ([string]$selector).StartsWith('items.', [System.StringComparison]::Ordinal)
            ) {
                $summaryItem = $Dataset.items[0]
            }

            if ($null -ne $summaryItem) {
                $resolution = Resolve-Selector -InputObject $summaryItem -Selector ([string]$selector)
            }

            if (-not $resolution.found) {
                return [ordered]@{
                    value = $null
                    selectorFailed = $true
                    valueIsNull = $false
                    valueIsEmptyArray = $false
                }
            }
        }

        $resolved = $resolution.value
    }

    return [ordered]@{
        value = $resolved
        selectorFailed = $false
        valueIsNull = [bool]$resolution.valueIsNull
        valueIsEmptyArray = [bool]$resolution.valueIsEmptyArray
    }
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

function ConvertTo-PlainHashtable {
    param([Parameter(Mandatory = $false)]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $converted = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $converted[[string]$key] = ConvertTo-PlainHashtable -InputObject $InputObject[$key]
        }
        return $converted
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-PlainHashtable -InputObject $item)
        }
        return $items
    }

    $properties = $null
    if ($InputObject.PSObject) {
        $properties = @($InputObject.PSObject.Properties)
    }

    if ($null -ne $properties -and $properties.Count -gt 0) {
        $converted = [ordered]@{}
        foreach ($property in $properties) {
            $converted[[string]$property.Name] = ConvertTo-PlainHashtable -InputObject $property.Value
        }
        return $converted
    }

    return $InputObject
}


function ConvertTo-ObjectArray {
    param([Parameter(Mandatory = $false)]$InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Array]) { return @($InputObject) }
    if ($InputObject -is [System.Collections.IList]) { return @($InputObject) }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string]) -and -not ($InputObject -is [System.Collections.IDictionary])) {
        return @($InputObject)
    }

    return @($InputObject)
}

function Normalize-ProjectionDefinition {
    param([Parameter(Mandatory = $false)]$Definition)

    if ($null -eq $Definition) { return $null }
    if (-not ($Definition -is [hashtable])) {
        throw 'Projection definition must deserialize to an object.'
    }

    $normalized = [ordered]@{}
    foreach ($key in @($Definition.Keys)) {
        switch ([string]$key) {
            'filter' {
                $normalized.filter = @(ConvertTo-ObjectArray -InputObject $Definition[$key] | Where-Object { $null -ne $_ })
            }
            'columns' {
                $normalized.columns = @(ConvertTo-ObjectArray -InputObject $Definition[$key] | Where-Object { $null -ne $_ })
            }
            default {
                $normalized[[string]$key] = $Definition[$key]
            }
        }
    }

    if (-not $normalized.Contains('filter')) { $normalized.filter = @() }
    if (-not $normalized.Contains('columns')) { $normalized.columns = @() }
    return $normalized
}

function Read-ProjectionContractFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Projection contract file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    return (ConvertTo-PlainHashtable -InputObject $raw)
}

function Resolve-ProjectionContractPath {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $relativePath = [System.IO.Path]::Combine('tech', $TechId, 'assembler.projections.v1.json').Replace('\', '/')
    $candidate = Join-Path (Join-Path (Join-Path $ContractsRoot 'tech') $TechId) 'assembler.projections.v1.json'

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    throw "Missing required projection contract for tech '$TechId'. Expected synced runtime dependency at '$relativePath' under ContractsRoot '$ContractsRoot'. Contracts sync is incomplete; sync '$relativePath' into .deps/contracts outside this repo and rerun."
}

$script:ProjectionDefinitionsCache = @{}

function Get-ProjectionDefinitions {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $cacheKey = "$ContractsRoot|$TechId"
    if ($script:ProjectionDefinitionsCache.ContainsKey($cacheKey)) {
        return $script:ProjectionDefinitionsCache[$cacheKey]
    }

    $projectionContractPath = Resolve-ProjectionContractPath -ContractsRoot $ContractsRoot -TechId $TechId
    $contract = Read-ProjectionContractFile -Path $projectionContractPath
    $definitions = @{}
    if ($contract -is [hashtable] -and $contract.ContainsKey('projections')) {
        if ($contract.projections -is [hashtable]) {
            foreach ($projectionTag in @($contract.projections.Keys)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$projectionTag)) {
                    $definitions[[string]$projectionTag] = Normalize-ProjectionDefinition -Definition $contract.projections[$projectionTag]
                }
            }
        }
        elseif ($contract.projections -is [System.Collections.IList]) {
            foreach ($projection in @($contract.projections)) {
                if ($projection -is [hashtable] -and $projection.ContainsKey('sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$projection.sdtTag)) {
                    $definition = @{}
                    foreach ($key in @($projection.Keys)) {
                        if ([string]$key -ne 'sdtTag') {
                            $definition[[string]$key] = $projection[$key]
                        }
                    }
                    $definitions[[string]$projection.sdtTag] = Normalize-ProjectionDefinition -Definition $definition
                }
            }
        }
    }

    $script:ProjectionDefinitionsCache[$cacheKey] = $definitions
    return $definitions
}

function Get-ProjectionDefinitionForTag {
    param(
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionDefinitions
    )

    if ($null -eq $ProjectionDefinitions -or [string]::IsNullOrWhiteSpace($Tag)) {
        return $null
    }

    if ($ProjectionDefinitions.ContainsKey($Tag)) {
        return $ProjectionDefinitions[$Tag]
    }

    $aliasMap = @{
        'LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory' = 'LNV.Lenovo.DE.System[ArrayName].Tables.Drives'
        'LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory' = 'LNV.Lenovo.DE.System[ArrayName].Tables.StorageContainers'
        'LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory' = 'LNV.Lenovo.DE.System[ArrayName].Tables.Volumes'
    }

    if ($aliasMap.ContainsKey($Tag)) {
        $projectionTag = [string]$aliasMap[$Tag]
        if ($ProjectionDefinitions.ContainsKey($projectionTag)) {
            return $ProjectionDefinitions[$projectionTag]
        }
    }

    return $null
}

function Test-ProjectionCondition {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][hashtable]$Condition
    )

    if ($Condition.ContainsKey('anyOf') -and $Condition.anyOf -is [System.Collections.IList]) {
        foreach ($nested in @($Condition.anyOf)) {
            if (Test-ProjectionCondition -Row $Row -Condition $nested) { return $true }
        }
        return $false
    }

    if ($Condition.ContainsKey('allOf') -and $Condition.allOf -is [System.Collections.IList]) {
        foreach ($nested in @($Condition.allOf)) {
            if (-not (Test-ProjectionCondition -Row $Row -Condition $nested)) { return $false }
        }
        return $true
    }

    if (-not $Condition.ContainsKey('field')) {
        throw 'Projection condition is missing required field property.'
    }

    $actual = $Row.([string]$Condition.field)
    if ($Condition.ContainsKey('equals')) {
        return ([string]$actual -eq [string]$Condition.equals)
    }
    if ($Condition.ContainsKey('notEquals')) {
        return ([string]$actual -ne [string]$Condition.notEquals)
    }
    if ($Condition.ContainsKey('isNull')) {
        return (($null -eq $actual) -eq [bool]$Condition.isNull)
    }

    throw "Unsupported projection condition for field '$($Condition.field)'."
}

function Resolve-ProjectionColumnValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][hashtable]$Column
    )

    $value = $null
    if ($Column.ContainsKey('source')) {
        $value = $Row.([string]$Column.source)
    }

    if ($Column.ContainsKey('format')) {
        switch ([string]$Column.format) {
            'bytesHuman' { return (Format-SizeHuman -Bytes $value) }
            'join' {
                if ($null -eq $value) { return '' }
                $delimiter = if ($Column.ContainsKey('delimiter')) { [string]$Column.delimiter } else { ', ' }
                return (@($value) -join $delimiter)
            }
            default { throw "Unsupported projection column format '$([string]$Column.format)'." }
        }
    }

    return $value
}

function Invoke-TableProjection {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][hashtable]$Definition
    )

    $normalizedRows = @(ConvertTo-ObjectArray -InputObject $Rows)
    $normalizedDefinition = Normalize-ProjectionDefinition -Definition $Definition
    $projectedRows = @($normalizedRows)
    if (@($normalizedDefinition.filter).Count -gt 0) {
        foreach ($condition in @($normalizedDefinition.filter)) {
            $projectedRows = @($projectedRows | Where-Object { Test-ProjectionCondition -Row $_ -Condition $condition })
        }
    }
    if ($normalizedDefinition.ContainsKey('sortBy') -and -not [string]::IsNullOrWhiteSpace([string]$normalizedDefinition.sortBy)) {
        $projectedRows = @($projectedRows | Sort-Object -Property ([string]$normalizedDefinition.sortBy))
    }

    if (@($normalizedDefinition.columns).Count -eq 0) {
        return @($projectedRows)
    }

    return @(
        $projectedRows | ForEach-Object {
            $row = $_
            $projected = [ordered]@{}
            foreach ($column in @($normalizedDefinition.columns)) {
                if (-not ($column -is [hashtable]) -or -not $column.ContainsKey('name')) {
                    throw 'Projection column is missing required name property.'
                }
                $projected[[string]$column.name] = Convert-CellValueToString -Value (Resolve-ProjectionColumnValue -Row $row -Column $column)
            }
            [pscustomobject]$projected
        }
    )
}

function Convert-TableRowsForTag {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionDefinitions
    )

    $normalizedRows = @(ConvertTo-ObjectArray -InputObject $Rows)
    $projectionDefinition = Get-ProjectionDefinitionForTag -Tag $Tag -ProjectionDefinitions $ProjectionDefinitions
    if ($null -ne $projectionDefinition) {
        return @(ConvertTo-ObjectArray -InputObject (Invoke-TableProjection -Rows $normalizedRows -Definition $projectionDefinition))
    }

    return @($normalizedRows)
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
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionDefinitions
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

    $rows = @(ConvertTo-ObjectArray -InputObject (Convert-TableRowsForTag -Tag $Tag -Rows $rows -ProjectionDefinitions $ProjectionDefinitions))

    if (@($rows).Count -eq 0) {
        return ''
    }

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
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionDefinitions
    )

    if ($null -eq $Value) {
        return ''
    }
    $projectionDefinition = Get-ProjectionDefinitionForTag -Tag $Tag -ProjectionDefinitions $ProjectionDefinitions
    $hasProjection = ($null -ne $projectionDefinition)
    if ($hasProjection -or (-not [string]::IsNullOrWhiteSpace($Tag) -and $Tag.EndsWith('_TABLE_JSON'))) {
        return (Convert-ValueToTableString -Value $Value -Tag $Tag -ProjectionDefinitions $ProjectionDefinitions)
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [ValueType]) {
        return [string]$Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        return ([string](ConvertTo-Json -InputObject $Value -Depth 10 -Compress))
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value)
        return ([string](ConvertTo-Json -InputObject $items -Depth 10 -Compress))
    }

    return ([string](ConvertTo-Json -InputObject $Value -Depth 10 -Compress))
}

$startedUtc = Get-UtcTimestamp
$issues = [System.Collections.Generic.List[hashtable]]::new()
$stageList = [System.Collections.Generic.List[hashtable]]::new()
$outputs = [System.Collections.Generic.List[hashtable]]::new()
$matches = [System.Collections.Generic.List[hashtable]]::new()
$status = 'OK'
$bundleId = $null
$currentStageName = $null
$currentTag = $null
$currentDatasetRelativePath = $null
$currentDatasetPath = $null
$currentSelectorChain = ''

$stageMap = [ordered]@{}
$stageInitializationUtc = Get-UtcTimestamp
foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
    $stage = [ordered]@{ name = $stageName; status = 'SKIPPED'; startedUtc = $stageInitializationUtc; completedUtc = $stageInitializationUtc; details = $null }
    $stageMap[$stageName] = $stage
    $stageList.Add($stage)
}

function Start-RenderStage {
    param([Parameter(Mandatory = $true)][hashtable]$Stage)
    $script:currentStageName = [string]$Stage.name
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
    if ($Status -ne 'ERROR') { $script:currentStageName = $null }
    $Stage.completedUtc = Get-UtcTimestamp
    if ($PSBoundParameters.ContainsKey('Details')) { $Stage.details = $Details }
}

function Add-SchemaValidationIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$PathValue
    )

    $issues.Add([ordered]@{ code = $Code; severity = 'ERROR'; message = $Message; path = $PathValue })
}

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $effectiveContractsRoot = Resolve-AssemblerContractsRoot -ContractsRoot $ContractsRoot -RepoRoot $repoRoot
    $mappingSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards') 'mapping.dataset-to-sdt.schema.v1.json'
    $projectionSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.projections.schema.v1.json'
    $renderReportSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.render-report.schema.v1.json'

    Start-RenderStage -Stage $stageMap.Load
    $mapping = Read-JsonFile -Path $MappingPath
    $projectionContractPath = Resolve-ProjectionContractPath -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $projectionContract = Read-ProjectionContractFile -Path $projectionContractPath
    $projectionDefinitions = Get-ProjectionDefinitions -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $mappingSchema = Read-JsonFile -Path $mappingSchemaPath
    $templateText = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8

    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-JsonFile -Path $manifestPath
        $bundleId = $manifest.bundleId
    }
    Complete-RenderStage -Stage $stageMap.Load -Status 'OK' -Details ([ordered]@{ mappingPath = $MappingPath; templatePath = $TemplatePath; contractsRoot = $effectiveContractsRoot; mappingSchemaPath = $mappingSchemaPath; projectionContractPath = $projectionContractPath; projectionSchemaPath = $projectionSchemaPath })

    Start-RenderStage -Stage $stageMap.Validate
    $mappingValidation = Test-AssemblerSchemaFile -DocumentPath $MappingPath -SchemaPath $mappingSchemaPath
    if (-not $mappingValidation.isValid) {
        Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-MAPPING-INVALID' -Message ([string]$mappingValidation.message) -PathValue $MappingPath
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Mapping schema validation failed.'
    }

    $projectionContractJson = $projectionContract | ConvertTo-Json -Depth 20
    $projectionValidation = Test-AssemblerSchemaJson -JsonText $projectionContractJson -SchemaPath $projectionSchemaPath -DocumentLabel $projectionContractPath
    if (-not $projectionValidation.isValid) {
        Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-PROJECTIONS-INVALID' -Message ([string]$projectionValidation.message) -PathValue $projectionContractPath
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Projection schema validation failed.'
    }
    Complete-RenderStage -Stage $stageMap.Validate -Status 'OK' -Details ([ordered]@{ mappingCount = @($mapping.mappings).Count; projectionCount = @($projectionDefinitions.Keys).Count })

    Start-RenderStage -Stage $stageMap.Transform
    $replaceByTag = @{}
    foreach ($entry in @($mapping.mappings)) {
        $currentDatasetRelativePath = [string]$entry.dataset
        $currentDatasetPath = $null
        $currentSelectorChain = ''
        $tag = if ($entry.ContainsKey('sdtTag')) { [string]$entry.sdtTag } elseif ($entry.ContainsKey('target') -and $entry.target.ContainsKey('sdtTag')) { [string]$entry.target.sdtTag } else { '' }
        $currentTag = $tag
        if ([string]::IsNullOrWhiteSpace($tag)) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-MAPPING-NOTAG'; severity = 'WARN'; message = "Skipping mapping with missing sdtTag for dataset '$($entry.dataset)'"; path = $MappingPath })
            continue
        }

        $datasetResolution = Resolve-DatasetFilePath -BundleRoot $BundleRoot -DatasetRelativePath ([string]$entry.dataset) -TechId ([string]$mapping.techId)
        $datasetPath = [string]$datasetResolution.path
        $currentDatasetPath = $datasetPath
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
        $envelopeErrors = @(Test-DatasetEnvelope -Dataset $dataset -DatasetPath $datasetPath)
        if (@($envelopeErrors).Count -gt 0) {
            if (Test-LegacySummaryCompatibilityDataset -Dataset $dataset -DatasetPath $datasetPath) {
                $issues.Add([ordered]@{
                    code = 'ASB-ASM-SDT-DATASET-COMPAT'
                    severity = 'WARN'
                    message = "Dataset '$($entry.dataset)' uses legacy run_summary.json compatibility for tag '$tag'; update the collector/Core output to emit a full lnv.collector.dataset.v1 envelope."
                    path = $datasetPath
                })
            }
            else {
                $severity = if ($entry.required) { 'ERROR' } else { 'WARN' }
                foreach ($envelopeError in $envelopeErrors) {
                    $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-DATASET-ENVELOPE'; severity = $severity; message = "Dataset '$($entry.dataset)' failed envelope validation for tag '$tag': $envelopeError"; path = $datasetPath })
                }
                if ($severity -eq 'ERROR') { $status = 'ERROR' }
                continue
            }
        }

        $resolved = $null
        $selectors = @(ConvertTo-ObjectArray -InputObject $entry.selectors)
        $currentSelectorChain = if (@($selectors).Count -gt 0) { (($selectors | ForEach-Object { [string]$_ }) -join ' -> ') } else { '' }
        if (@($selectors).Count -gt 0) {
            $selectorResult = Resolve-SelectorWithSummaryCompatibility -Dataset $dataset -Selectors @($selectors | ForEach-Object { [string]$_ }) -DatasetPath $datasetPath
            $resolved = $selectorResult.value
            $selectorFailed = [bool]$selectorResult.selectorFailed

            if ($selectorFailed) {
                $selectorChain = $currentSelectorChain
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

        $resolvedText = [string](Convert-ValueToString -Value $resolved -Tag $tag -ProjectionDefinitions $projectionDefinitions)
        $replaceByTag[$tag] = $resolvedText
        $resolvedTextLength = if ($null -eq $resolvedText) { 0 } else { $resolvedText.Length }
        $valuePreview = if ($resolvedTextLength -gt 80) { $resolvedText.Substring(0, 80) + '...' } else { $resolvedText }
        $matches.Add([ordered]@{ tag = $tag; dataset = [string]$entry.dataset; selector = $currentSelectorChain; valuePreview = $valuePreview })
        $currentTag = $null
        $currentDatasetRelativePath = $null
        $currentDatasetPath = $null
        $currentSelectorChain = ''
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
    $exception = $_
    $diagnostics = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$exception.Exception.Message)) { $diagnostics.Add("message=$([string]$exception.Exception.Message)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$exception.InvocationInfo.PositionMessage)) { $diagnostics.Add("position=$([string]$exception.InvocationInfo.PositionMessage)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$exception.ScriptStackTrace)) { $diagnostics.Add("stack=$([string]$exception.ScriptStackTrace)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentStageName)) { $diagnostics.Add("stage=$currentStageName") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentTag)) { $diagnostics.Add("tag=$currentTag") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentDatasetRelativePath)) { $diagnostics.Add("dataset=$currentDatasetRelativePath") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentDatasetPath)) { $diagnostics.Add("datasetPath=$currentDatasetPath") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentSelectorChain)) { $diagnostics.Add("selectors=$currentSelectorChain") }
    $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-UNHANDLED'; severity = 'ERROR'; message = ($diagnostics -join ' | '); path = $(if (-not [string]::IsNullOrWhiteSpace([string]$currentDatasetPath)) { $currentDatasetPath } else { $null }) })

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
$renderReportValidation = Test-AssemblerSchemaJson -JsonText $reportJson -SchemaPath $renderReportSchemaPath -DocumentLabel 'assembler-sdt-render-report'
if (-not $renderReportValidation.isValid) {
    Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-RENDERREPORT-INVALID' -Message ([string]$renderReportValidation.message) -PathValue $(if ($ReportPath) { $ReportPath } else { '<stdout>' })
    foreach ($stageName in @('Finalize','Render','Transform','Validate','Load')) {
        $stage = $stageMap[$stageName]
        if ($stage.status -ne 'SKIPPED') {
            $stage.status = 'ERROR'
            break
        }
    }
    $status = 'ERROR'
    $report.status = $status
    $report.issues = $issues
    $report.completedUtc = Get-UtcTimestamp
    $reportJson = $report | ConvertTo-Json -Depth 10
}
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
