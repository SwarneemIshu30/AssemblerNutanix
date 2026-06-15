Set-StrictMode -Version Latest

function ConvertTo-AssemblerSafeName {
    param([Parameter(Mandatory)][string]$Value)
    return ($Value -replace '[^a-zA-Z0-9_.-]+', '_')
}

function New-AssemblerDefaultCompositionMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$DatasetCatalog,
        [Parameter(Mandatory)][System.Collections.IDictionary]$TemplateCatalog,
        [Parameter(Mandatory)][string]$ContractsRoot
    )

    $policyPath = Join-Path $ContractsRoot 'standards/assembler/assembler.default-composition-policy.v1.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        throw "Assembler composition policy not found: $policyPath"
    }
    $policy = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100

    $objects = @(
        $DatasetCatalog.entries |
            Sort-Object scope, techId, objectKey |
            Group-Object { "$([string]$_.scope)|$([string]$_.techId)|$([string]$_.objectKey)" } |
            ForEach-Object {
                $entry = $_.Group[0]
                [ordered]@{
                    scope = [string]$entry.scope
                    techId = [string]$entry.techId
                    objectKey = [string]$entry.objectKey
                    objectKind = [string]$entry.objectKind
                    displayName = [string]$entry.displayName
                    domain = @($_.Group.domain | Sort-Object -Unique)
                    tags = $entry.tags
                    included = $true
                }
            }
    )

    return [ordered]@{
        schema = 'assembler.composition-map'
        schemaVersion = 1
        document = [ordered]@{
            id = [string]$DatasetCatalog.solutionId
            outputName = "$([string]$DatasetCatalog.solutionId).docx"
        }
        policy = $policy
        objects = $objects
        contributions = @(
            $TemplateCatalog.entries |
                Where-Object { $_.enabled -ne $false } |
                Sort-Object @{ Expression = { if ($_.Contains('priority')) { [int]$_.priority } else { 100 } } }, id |
                ForEach-Object {
                    [ordered]@{
                        entryId = [string]$_.id
                        techId = [string]$_.techId
                        included = $true
                    }
                }
        )
    }
}

function Add-AssemblerContextToItem {
    param(
        [AllowNull()]$Item,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CatalogEntry
    )
    $copy = if ($Item -is [System.Collections.IDictionary]) {
        [ordered]@{} + $Item
    }
    else {
        [ordered]@{ value = $Item }
    }
    $copy['_assembler'] = [ordered]@{
        techId = [string]$CatalogEntry.techId
        domain = [string]$CatalogEntry.domain
        scope = [string]$CatalogEntry.scope
        objectKey = [string]$CatalogEntry.objectKey
        objectKind = [string]$CatalogEntry.objectKind
        displayName = [string]$CatalogEntry.displayName
        tags = $CatalogEntry.tags
    }
    return $copy
}

function New-AssemblerCompiledMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$DatasetCatalog,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CompositionMap,
        [Parameter(Mandatory)][string]$MappingPath,
        [Parameter(Mandatory)][string]$EntryId,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $mapping = Get-Content -LiteralPath $MappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $includedObjects = @{}
    foreach ($object in @($CompositionMap.objects | Where-Object { $_.included -ne $false })) {
        $includedObjects["$([string]$object.scope)|$([string]$object.techId)|$([string]$object.objectKey)"] = $true
    }

    $planRoot = Join-Path $OutputRoot '.render-plan'
    $datasetRoot = Join-Path $planRoot "datasets/$([string]$mapping.techId)"
    $mappingRoot = Join-Path $planRoot 'mappings'
    New-Item -ItemType Directory -Path $datasetRoot, $mappingRoot -Force | Out-Null

    foreach ($entry in @($mapping.mappings)) {
        $datasetKey = [string]$entry.dataset
        if ([string]::IsNullOrWhiteSpace($datasetKey) -or $datasetKey -match '[/\\]' -or $datasetKey -match '__[A-Z0-9_]+__') {
            throw "ASB-ASM-MAPPING-DATASET-NOT-LOGICAL: entry '$([string]$entry.sdtTag)' must use a logical dataset key, got '$datasetKey'."
        }

        $matches = @(
            $DatasetCatalog.entries |
                Where-Object {
                    [string]$_.techId -eq [string]$mapping.techId -and
                    [string]$_.datasetKey -eq $datasetKey -and
                    (
                        -not $entry.Contains('scope') -or
                        [string]::IsNullOrWhiteSpace([string]$entry.scope) -or
                        [string]$entry.scope -eq 'any' -or
                        [string]$_.scope -eq [string]$entry.scope
                    ) -and
                    (
                        -not $entry.Contains('domain') -or
                        [string]::IsNullOrWhiteSpace([string]$entry.domain) -or
                        [string]$_.domain -eq [string]$entry.domain
                    ) -and
                    $includedObjects.ContainsKey("$([string]$_.scope)|$([string]$_.techId)|$([string]$_.objectKey)")
                } |
                Sort-Object scope, objectKey, domain, relativePath
        )
        if ($matches.Count -eq 0) {
            if ($entry.required) {
                throw "ASB-ASM-MAPPING-DATASET-MISSING: required logical dataset '$datasetKey' has no selected canonical inputs."
            }
            continue
        }

        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($match in $matches) {
            foreach ($item in @($match.envelope.items)) {
                $items.Add((Add-AssemblerContextToItem -Item $item -CatalogEntry $match))
            }
        }
        $compiledDatasetNameParts = [System.Collections.Generic.List[string]]::new()
        $compiledDatasetNameParts.Add($datasetKey)
        foreach ($filterKey in @('scope', 'domain')) {
            if ($entry.Contains($filterKey) -and -not [string]::IsNullOrWhiteSpace([string]$entry[$filterKey]) -and [string]$entry[$filterKey] -ne 'any') {
                $compiledDatasetNameParts.Add((ConvertTo-AssemblerSafeName -Value ([string]$entry[$filterKey])))
            }
        }
        $compiledDatasetPath = Join-Path $datasetRoot "$($compiledDatasetNameParts -join '.').json"
        [ordered]@{
            schema_version = 'lnv.collector.dataset.v1'
            collector = [ordered]@{ tech_id = [string]$mapping.techId; module = 'LNV.AsBuiltDoc.Assembler'; entry_point = 'composition' }
            source = [ordered]@{ bundle_root = [string]$DatasetCatalog.bundleRoot; composition_id = [string]$CompositionMap.document.id; input_files = @($matches.relativePath) }
            dataset = [ordered]@{ key = $datasetKey; schema_path = "tech/$([string]$mapping.techId)/dataset/$datasetKey.schema.json" }
            item_count = $items.Count
            items = @($items)
        } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $compiledDatasetPath -Encoding UTF8
        if ([int]$mapping.schemaVersion -ge 2) {
            $entry.resolvedDataset = $compiledDatasetPath
        }
        else {
            $entry.dataset = $compiledDatasetPath
        }
    }

    $compiledMappingPath = Join-Path $mappingRoot "$(ConvertTo-AssemblerSafeName -Value $EntryId).json"
    $mapping | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $compiledMappingPath -Encoding UTF8
    return $compiledMappingPath
}

Export-ModuleMember -Function New-AssemblerDefaultCompositionMap, New-AssemblerCompiledMapping
