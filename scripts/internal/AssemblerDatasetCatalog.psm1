Set-StrictMode -Version Latest

function Read-AssemblerJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
}

function Get-AssemblerMapValue {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory)][string]$Key
    )
    if ($Map.Contains($Key)) { return $Map[$Key] }
    return $null
}

function ConvertTo-AssemblerContextMap {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return @{} }
    if ($Value -is [System.Collections.IDictionary]) { return $Value }

    $map = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.MemberType -eq 'NoteProperty' -or $property.MemberType -eq 'Property') {
            $map[[string]$property.Name] = $property.Value
        }
    }
    return $map
}

function Get-AssemblerTargetLocation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Target)

    $tags = ConvertTo-AssemblerContextMap -Value (Get-AssemblerMapValue -Map $Target -Key 'tags')
    $params = ConvertTo-AssemblerContextMap -Value (Get-AssemblerMapValue -Map $Target -Key 'params')
    $location = ConvertTo-AssemblerContextMap -Value (Get-AssemblerMapValue -Map $Target -Key 'location')

    foreach ($key in @('site','siteSort','facility','building','room','row','rack','rackLocation','position','role')) {
        if (-not $location.Contains($key)) {
            if ($tags.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$tags[$key])) {
                $location[$key] = $tags[$key]
                continue
            }
            if ($params.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$params[$key])) {
                $location[$key] = $params[$key]
            }
        }
    }

    if (-not $location.Contains('rackLocation') -and $location.Contains('rack')) {
        $location.rackLocation = $location.rack
    }
    if (-not $location.Contains('rack') -and $location.Contains('rackLocation')) {
        $location.rack = $location.rackLocation
    }

    return $location
}

function New-AssemblerDatasetCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BundleRoot)

    $resolvedRoot = (Resolve-Path -LiteralPath $BundleRoot -ErrorAction Stop).Path
    $manifest = Read-AssemblerJson -Path (Join-Path $resolvedRoot 'manifest.json')
    $plan = Read-AssemblerJson -Path (Join-Path $resolvedRoot 'config/solution.plan.json')
    $objectIndex = Read-AssemblerJson -Path (Join-Path $resolvedRoot 'objectIndex.json')

    $targetMap = @{}
    foreach ($target in @($plan.targets)) {
        $targetMap[[string]$target.key] = $target
    }
    $groupMap = @{}
    foreach ($group in @((Get-AssemblerMapValue -Map $plan -Key 'targetGroups'))) {
        if ($null -ne $group -and $group.Contains('key')) {
            $groupMap[[string]$group.key] = $group
        }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $identityPaths = @{}
    $legacyPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($file in @($manifest.files | Sort-Object { [string]$_.path })) {
        $relativePath = ([string]$file.path).Replace('\', '/')
        if (
            $relativePath -notlike 'datasets/*' -or
            $relativePath -like 'datasets/raw/*' -or
            $relativePath -match '/findings/' -or
            $relativePath -match '/coverage\.json$' -or
            $relativePath -notlike '*.json'
        ) {
            continue
        }
        if ($relativePath -match '(^|/)(collector-out|target_[^/]+|system_[^/]+)(/|$)' -or $relativePath -match '__[A-Z0-9_]+__') {
            $legacyPaths.Add($relativePath)
            continue
        }

        $match = [regex]::Match($relativePath, '^datasets/([^/]+)/([^/]+)/([^/]+)/([^/]+)\.json$')
        if (-not $match.Success) {
            throw "ASB-ASM-CATALOG-PATH-INVALID: manifest dataset path is not canonical: $relativePath"
        }

        $techId = $match.Groups[1].Value
        $domain = $match.Groups[2].Value
        $objectKey = $match.Groups[3].Value
        $datasetKey = $match.Groups[4].Value
        $scope = if ($targetMap.ContainsKey($objectKey)) {
            'target'
        }
        elseif ($groupMap.ContainsKey($objectKey)) {
            'targetGroup'
        }
        elseif ([string]$plan.solutionId -eq $objectKey) {
            'solution'
        }
        else {
            throw "ASB-ASM-CATALOG-OBJECT-UNKNOWN: '$relativePath' references object '$objectKey' that is not a target, target group, or solution."
        }

        $identity = "$techId|$domain|$scope|$objectKey|$datasetKey"
        if ($identityPaths.ContainsKey($identity)) {
            throw "ASB-ASM-CATALOG-DUPLICATE: dataset identity '$identity' is declared by '$($identityPaths[$identity])' and '$relativePath'."
        }

        $fullPath = Join-Path $resolvedRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "ASB-ASM-CATALOG-FILE-MISSING: manifest dataset file does not exist: $relativePath"
        }
        $envelope = Read-AssemblerJson -Path $fullPath
        foreach ($required in @('schema_version','collector','source','dataset','item_count','items')) {
            if (-not $envelope.Contains($required)) {
                throw "ASB-ASM-CATALOG-ENVELOPE-INVALID: '$relativePath' is missing '$required'."
            }
        }
        if ([string]$envelope.schema_version -ne 'lnv.collector.dataset.v1') {
            throw "ASB-ASM-CATALOG-ENVELOPE-INVALID: '$relativePath' has unsupported schema_version '$($envelope.schema_version)'."
        }
        $declaredDatasetKey = if ($envelope.dataset -is [System.Collections.IDictionary]) { [string]$envelope.dataset.key } else { [string]$envelope.dataset }
        if ($declaredDatasetKey -ne $datasetKey) {
            throw "ASB-ASM-CATALOG-DATASET-MISMATCH: '$relativePath' declares dataset '$declaredDatasetKey'."
        }
        if ([int]$envelope.item_count -ne @($envelope.items).Count) {
            throw "ASB-ASM-CATALOG-ITEMCOUNT: '$relativePath' item_count does not match items length."
        }

        $object = if ($scope -eq 'target') { $targetMap[$objectKey] } elseif ($scope -eq 'targetGroup') { $groupMap[$objectKey] } else { $null }
        $tags = if ($null -ne $object -and $object.Contains('tags')) { ConvertTo-AssemblerContextMap -Value $object.tags } else { @{} }
        $params = if ($null -ne $object -and $object.Contains('params')) { ConvertTo-AssemblerContextMap -Value $object.params } else { @{} }
        $location = if ($null -ne $object) { Get-AssemblerTargetLocation -Target $object } else { @{} }
        $identityPaths[$identity] = $relativePath
        $entries.Add([ordered]@{
            identity = $identity
            techId = $techId
            domain = $domain
            scope = $scope
            objectKey = $objectKey
            objectKind = if ($null -ne $object -and $object.Contains('kind')) { [string]$object.kind } else { $scope }
            displayName = if ($null -ne $object -and $object.Contains('displayName')) { [string]$object.displayName } else { $objectKey }
            tags = $tags
            params = $params
            location = $location
            datasetKey = $datasetKey
            relativePath = $relativePath
            path = $fullPath
            envelope = $envelope
        })
    }

    if ($legacyPaths.Count -gt 0) {
        throw "ASB-ASM-CATALOG-LEGACY-LAYOUT: legacy dataset paths are not supported: $($legacyPaths -join ', ')"
    }

    return [ordered]@{
        schemaVersion = 1
        bundleRoot = $resolvedRoot
        solutionId = [string]$plan.solutionId
        manifest = $manifest
        plan = $plan
        objectIndex = $objectIndex
        entries = @($entries.ToArray())
    }
}

Export-ModuleMember -Function New-AssemblerDatasetCatalog
