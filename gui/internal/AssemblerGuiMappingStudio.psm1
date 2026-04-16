Set-StrictMode -Version Latest

function ConvertTo-Dictionary {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value
    }

    if ($Value -is [string] -or $Value -is [ValueType]) {
        return $null
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [System.Collections.IDictionary])) {
        return $null
    }

    if ($null -ne $Value.PSObject) {
        $converted = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            $converted[[string]$property.Name] = $property.Value
        }
        return $converted
    }

    return $null
}

function Test-MapHasKey {
    param(
        [Parameter(Mandatory = $false)]$Map,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ($null -eq $Map -or -not ($Map -is [System.Collections.IDictionary])) {
        return $false
    }

    $containsKeyMethod = $Map.PSObject.Methods['ContainsKey']
    if ($null -ne $containsKeyMethod) {
        return $Map.ContainsKey($Key)
    }

    $containsMethod = $Map.PSObject.Methods['Contains']
    if ($null -ne $containsMethod) {
        return [bool]$Map.Contains($Key)
    }

    foreach ($existingKey in @($Map.Keys)) {
        if ([string]$existingKey -eq $Key) {
            return $true
        }
    }

    return $false
}

function Get-MapValueOrDefault {
    param(
        [Parameter(Mandatory = $false)]$Map,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)]$DefaultValue = $null
    )

    if (-not (Test-MapHasKey -Map $Map -Key $Key)) {
        return $DefaultValue
    }

    return $Map[$Key]
}

function ConvertTo-PlainValue {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $copy[[string]$key] = ConvertTo-PlainValue -Value $Value[$key]
        }
        return $copy
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($Value)) {
            $items.Add((ConvertTo-PlainValue -Value $item)) | Out-Null
        }
        return [object[]]$items.ToArray()
    }

    if ($null -ne $Value.PSObject -and @($Value.PSObject.Properties).Count -gt 0 -and -not ($Value -is [string])) {
        $copy = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            $copy[[string]$property.Name] = ConvertTo-PlainValue -Value $property.Value
        }
        return $copy
    }

    return $Value
}

function Copy-PlainValue {
    param([Parameter(Mandatory = $false)]$Value)

    return (ConvertTo-PlainValue -Value $Value)
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file not found: $Path"
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable)
}

function Get-FileTextIfExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Get-MappingStudioYamlSupport {
    $parser = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
    $writer = Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue

    if ($null -eq $parser -or $null -eq $writer) {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue | Out-Null
        $parser = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
        $writer = Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue
    }

    $canRead = $null -ne $parser
    $canWrite = $null -ne $writer
    $available = $canRead -and $canWrite
    $message = ''

    if (-not $available) {
        $detectedEdition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { '<unknown>' }
        $detectedVersion = if ($PSVersionTable.ContainsKey('PSVersion')) { [string]$PSVersionTable.PSVersion } else { '<unknown>' }
        $message = "YAML authoring support is unavailable in this session. Install-Module powershell-yaml -Scope CurrentUser or run under pwsh 7+ with ConvertFrom-Yaml / ConvertTo-Yaml available. Detected: $detectedEdition $detectedVersion."
    }

    return [ordered]@{
        canRead = $canRead
        canWrite = $canWrite
        available = $available
        message = $message
    }
}

function Read-YamlFileSafe {
    param([Parameter(Mandatory = $true)][string]$Path)

    $support = Get-MappingStudioYamlSupport
    if (-not [bool]$support.canRead) {
        throw $support.message
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Yaml)
}

function Write-YamlFileSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $support = Get-MappingStudioYamlSupport
    if (-not [bool]$support.available) {
        throw $support.message
    }

    $directory = Split-Path -Parent $Path
    Ensure-Directory -Path $directory
    $yamlText = $Value | ConvertTo-Yaml
    Set-Content -LiteralPath $Path -Encoding UTF8 -Value $yamlText
}

function Get-CatalogEntryOutputType {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entry)

    $templatePath = [string](Get-MapValueOrDefault -Map $Entry -Key 'templatePath')
    $outputFileName = [string](Get-MapValueOrDefault -Map $Entry -Key 'outputFileName')

    if ($templatePath -match '\.docx$' -or $outputFileName -match '\.docx$') {
        return 'docx'
    }
    if ($templatePath -match '\.(txt|text)$' -or $outputFileName -match '\.(txt|text)$') {
        return 'text'
    }

    return 'unknown'
}

function Get-TemplateCollections {
    param([Parameter(Mandatory = $true)][string]$CatalogPath)

    $catalog = Read-JsonFile -Path $CatalogPath
    $catalogDir = Split-Path -Parent $CatalogPath
    $collections = New-Object System.Collections.Generic.List[object]

    foreach ($entry in @($catalog.entries)) {
        $entryTable = ConvertTo-Dictionary -Value $entry
        if ($null -eq $entryTable) { continue }
        if ((Test-MapHasKey -Map $entryTable -Key 'enabled') -and (-not [bool]$entryTable.enabled)) { continue }

        $outputType = Get-CatalogEntryOutputType -Entry $entryTable
        $mappingRelativePath = [string](Get-MapValueOrDefault -Map $entryTable -Key 'mappingPath')
        $templateRelativePath = [string](Get-MapValueOrDefault -Map $entryTable -Key 'templatePath')
        $priority = [int](Get-MapValueOrDefault -Map $entryTable -Key 'priority' -DefaultValue 0)

        $collections.Add([pscustomobject]@{
                Id = [string](Get-MapValueOrDefault -Map $entryTable -Key 'id')
                TechId = [string](Get-MapValueOrDefault -Map $entryTable -Key 'techId')
                DisplayName = [string](Get-MapValueOrDefault -Map $entryTable -Key 'displayName')
                DocType = [string](Get-MapValueOrDefault -Map $entryTable -Key 'docType')
                OutputType = $outputType
                Priority = $priority
                CatalogPath = $CatalogPath
                CatalogDirectory = $catalogDir
                MappingPath = if ([string]::IsNullOrWhiteSpace($mappingRelativePath)) { $null } else { Join-Path $catalogDir $mappingRelativePath }
                MappingRelativePath = $mappingRelativePath
                TemplatePath = if ([string]::IsNullOrWhiteSpace($templateRelativePath)) { $null } else { Join-Path $catalogDir $templateRelativePath }
                TemplateRelativePath = $templateRelativePath
                OutputFileName = [string](Get-MapValueOrDefault -Map $entryTable -Key 'outputFileName')
                Label = ("{0} [{1}] ({2})" -f [string](Get-MapValueOrDefault -Map $entryTable -Key 'displayName'), ([string](Get-MapValueOrDefault -Map $entryTable -Key 'techId')), $outputType)
                Entry = Copy-PlainValue -Value $entryTable
            }) | Out-Null
    }

    return @(
        $collections |
            Sort-Object -Property `
                @{ Expression = { if ($_.OutputType -eq 'docx') { 0 } elseif ($_.OutputType -eq 'text') { 1 } else { 2 } } }, `
                @{ Expression = { -1 * [int]$_.Priority } }, `
                @{ Expression = 'DisplayName' }, `
                @{ Expression = 'Id' }
    )
}

function Resolve-MappingStudioBundleRoot {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)

    $resolvedInput = (Resolve-Path -LiteralPath $BundleRoot -ErrorAction Stop).Path

    function Test-BundleCandidate {
        param([Parameter(Mandatory = $true)][string]$Path)

        $manifestPath = Join-Path $Path 'manifest.json'
        $objectIndexPath = Join-Path $Path 'objectIndex.json'
        $solutionPlanPath = Join-Path (Join-Path $Path 'config') 'solution.plan.json'

        return [ordered]@{
            path = $Path
            manifestPath = $manifestPath
            objectIndexPath = $objectIndexPath
            solutionPlanPath = $solutionPlanPath
            isValid =
                (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
                (Test-Path -LiteralPath $objectIndexPath -PathType Leaf) -and
                (Test-Path -LiteralPath $solutionPlanPath -PathType Leaf)
        }
    }

    $directCandidate = Test-BundleCandidate -Path $resolvedInput
    if ($directCandidate.isValid) {
        return [ordered]@{
            bundleRoot = $resolvedInput
            solutionPlanPath = $directCandidate.solutionPlanPath
            objectIndexPath = $directCandidate.objectIndexPath
            autoSelected = $false
            selectionReason = 'direct'
        }
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $resolvedInput -Directory -ErrorAction Stop |
            ForEach-Object {
                $candidate = Test-BundleCandidate -Path $_.FullName
                if ($candidate.isValid) {
                    [pscustomobject]@{
                        BundleRoot = [string]$candidate.path
                        SolutionPlanPath = [string]$candidate.solutionPlanPath
                        ObjectIndexPath = [string]$candidate.objectIndexPath
                    }
                }
            }
    )

    if (@($candidates).Count -eq 1) {
        $selected = $candidates[0]
        return [ordered]@{
            bundleRoot = [string]$selected.BundleRoot
            solutionPlanPath = [string]$selected.SolutionPlanPath
            objectIndexPath = [string]$selected.ObjectIndexPath
            autoSelected = $true
            selectionReason = 'single-staged-child'
        }
    }

    if (@($candidates).Count -gt 1) {
        $candidateRoots = @($candidates | Sort-Object -Property BundleRoot | ForEach-Object { [string]$_.BundleRoot })
        throw "BundleRoot '$BundleRoot' resolves to multiple bundle candidates. Select a specific bundle directory. Candidates: $($candidateRoots -join ', ')"
    }

    throw "BundleRoot '$BundleRoot' does not resolve to a valid bundle directory."
}

function Get-CollectorTargetRoots {
    param([Parameter(Mandatory = $true)][string]$CollectorOutRoot)

    if (-not (Test-Path -LiteralPath $CollectorOutRoot -PathType Container)) {
        throw "Expected collector dataset root not found: $CollectorOutRoot"
    }

    $targetRoots = [System.Collections.Generic.List[psobject]]::new()
    foreach ($container in @(Get-ChildItem -LiteralPath $CollectorOutRoot -Directory -ErrorAction Stop | Sort-Object -Property Name)) {
        if ($container.Name -eq '_multi') {
            foreach ($targetRoot in @(Get-ChildItem -LiteralPath $container.FullName -Directory -ErrorAction Stop | Where-Object { $_.Name -like 'target_*' } | Sort-Object -Property Name)) {
                $targetRoots.Add([pscustomobject]@{
                        ContainerName = [string]$container.Name
                        ContainerPath = [string]$container.FullName
                        Name = [string]$targetRoot.Name
                        FullName = [string]$targetRoot.FullName
                    }) | Out-Null
            }
            continue
        }

        foreach ($targetRoot in @(Get-ChildItem -LiteralPath $container.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'target_*' } | Sort-Object -Property Name)) {
            $targetRoots.Add([pscustomobject]@{
                    ContainerName = [string]$container.Name
                    ContainerPath = [string]$container.FullName
                    Name = [string]$targetRoot.Name
                    FullName = [string]$targetRoot.FullName
                }) | Out-Null
        }
    }

    return @($targetRoots)
}

function Resolve-MappingStudioTechDatasetContext {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$CatalogEntry
    )

    $collectorOutRoot = Join-Path (Join-Path (Join-Path $BundleRoot 'datasets') $TechId) 'collector-out'
    $targets = @(
        Get-CollectorTargetRoots -CollectorOutRoot $collectorOutRoot |
            ForEach-Object {
                $summary = Join-Path $_.FullName 'run_summary.json'
                [pscustomobject]@{
                    Name = $_.Name
                    FullName = $_.FullName
                    ContainerName = $_.ContainerName
                    ContainerPath = $_.ContainerPath
                    TargetKey = if ($_.Name.StartsWith('target_')) { $_.Name.Substring(7) } else { $_.Name }
                    HasRunSummary = (Test-Path -LiteralPath $summary -PathType Leaf)
                }
            }
    )

    if (@($targets).Count -eq 0) {
        throw "No target_* folders found under collector dataset root: $collectorOutRoot"
    }

    $explicitTargetKeys = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $CatalogEntry) {
        foreach ($keyField in @('targetKey', 'target', 'selectedTargetKey')) {
            if ((Test-MapHasKey -Map $CatalogEntry -Key $keyField) -and -not [string]::IsNullOrWhiteSpace([string]$CatalogEntry[$keyField])) {
                $explicitTargetKeys.Add(([string]$CatalogEntry[$keyField]).Trim()) | Out-Null
            }
        }

        $targetSelector = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $CatalogEntry -Key 'targetSelector')
        if ($null -ne $targetSelector -and (Test-MapHasKey -Map $targetSelector -Key 'key') -and -not [string]::IsNullOrWhiteSpace([string]$targetSelector.key)) {
            $explicitTargetKeys.Add(([string]$targetSelector.key).Trim()) | Out-Null
        }
    }

    $solutionPlanTargetKeys = [System.Collections.Generic.List[string]]::new()
    $solutionPlanPath = Join-Path (Join-Path $BundleRoot 'config') 'solution.plan.json'
    if (Test-Path -LiteralPath $solutionPlanPath -PathType Leaf) {
        try {
            $solutionPlan = Read-JsonFile -Path $solutionPlanPath
            foreach ($collector in @($solutionPlan.collectors)) {
                if ([string]$collector.techId -ne $TechId) { continue }
                foreach ($targetKey in @($collector.targetKeys)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$targetKey)) {
                        $solutionPlanTargetKeys.Add(([string]$targetKey).Trim()) | Out-Null
                    }
                }
            }
        }
        catch {
            # Fallback to lexical ordering.
        }
    }

    $targetByName = @{}
    $targetByKey = @{}
    foreach ($candidate in $targets) {
        if (-not $targetByName.ContainsKey([string]$candidate.Name)) {
            $targetByName[[string]$candidate.Name] = $candidate
        }
        if (-not $targetByKey.ContainsKey([string]$candidate.TargetKey)) {
            $targetByKey[[string]$candidate.TargetKey] = $candidate
        }
    }

    $selectedTarget = $null
    $selectionReason = $null
    foreach ($candidateKey in @($explicitTargetKeys)) {
        if ($targetByName.ContainsKey($candidateKey)) {
            $selectedTarget = $targetByName[$candidateKey]
            $selectionReason = "catalog-entry:$candidateKey"
            break
        }

        $prefixed = "target_$candidateKey"
        if ($targetByName.ContainsKey($prefixed)) {
            $selectedTarget = $targetByName[$prefixed]
            $selectionReason = "catalog-entry:$candidateKey"
            break
        }

        if ($targetByKey.ContainsKey($candidateKey)) {
            $selectedTarget = $targetByKey[$candidateKey]
            $selectionReason = "catalog-entry:$candidateKey"
            break
        }
    }

    if ($null -eq $selectedTarget) {
        foreach ($targetKey in @($solutionPlanTargetKeys)) {
            if ($targetByKey.ContainsKey($targetKey)) {
                $selectedTarget = $targetByKey[$targetKey]
                $selectionReason = "solution-plan:$targetKey"
                break
            }
        }
    }

    if ($null -eq $selectedTarget) {
        $selectedTarget = $targets | Sort-Object -Property @{ Expression = 'Name' }, @{ Expression = 'FullName' } | Select-Object -First 1
        $selectionReason = 'lexical-fallback'
    }

    $systems = @(
        Get-ChildItem -LiteralPath $selectedTarget.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'system_*' } |
            Sort-Object -Property Name |
            ForEach-Object { [string]$_.Name }
    )

    $techDatasetRoot = Join-Path (Join-Path $BundleRoot 'datasets') $TechId
    $targetRelativePrefix = [System.IO.Path]::GetRelativePath($techDatasetRoot, [string]$selectedTarget.FullName).Replace('\', '/')

    return [ordered]@{
        target = [string]$selectedTarget.Name
        targetKey = [string]$selectedTarget.TargetKey
        targetRoot = [string]$selectedTarget.FullName
        targetRelativePrefix = $targetRelativePrefix
        targetContainer = [string]$selectedTarget.ContainerName
        systems = $systems
        selectedSystem = if (@($systems).Count -gt 0) { [string]$systems[0] } else { $null }
        selectionReason = $selectionReason
        candidateTargets = @($targets | Sort-Object -Property @{ Expression = 'Name' }, @{ Expression = 'FullName' } | ForEach-Object { [string]$_.Name })
        candidateTargetRoots = @($targets | Sort-Object -Property @{ Expression = 'Name' }, @{ Expression = 'FullName' } | ForEach-Object { [string]$_.FullName })
    }
}

function Get-DatasetMetadataMap {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $datasetRoot = Join-Path (Join-Path (Join-Path $ContractsRoot 'tech') $TechId) 'dataset'
    if (-not (Test-Path -LiteralPath $datasetRoot -PathType Container)) {
        return @{}
    }

    $map = [ordered]@{}
    foreach ($metadataPath in @(Get-ChildItem -LiteralPath $datasetRoot -Filter '*.assembler.meta.json' -File | Sort-Object -Property Name)) {
        $metadata = Read-JsonFile -Path $metadataPath.FullName
        if ($null -eq $metadata) { continue }

        $datasetId = [string](Get-MapValueOrDefault -Map $metadata -Key 'dataset')
        if ([string]::IsNullOrWhiteSpace($datasetId)) { continue }

        $datasetPath = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $metadata -Key 'datasetPath')
        $pathTemplate = [string](Get-MapValueOrDefault -Map $metadata -Key 'datasetPathTemplate')
        $scope = ''
        if ($null -ne $datasetPath) {
            if ([string]::IsNullOrWhiteSpace($pathTemplate) -and (Test-MapHasKey -Map $datasetPath -Key 'template')) {
                $pathTemplate = [string]$datasetPath.template
            }
            if (Test-MapHasKey -Map $datasetPath -Key 'scope') {
                $scope = [string]$datasetPath.scope
            }
        }

        $map[$datasetId] = [pscustomobject]@{
            DatasetId = $datasetId
            MetadataPath = $metadataPath.FullName
            PresentationKind = [string](Get-MapValueOrDefault -Map $metadata -Key 'presentationKind')
            DefaultItemRoot = [string](Get-MapValueOrDefault -Map $metadata -Key 'defaultItemRoot')
            PathTemplate = $pathTemplate
            Scope = $scope
            PreferredProjectionViews = @(
                foreach ($view in @(Get-MapValueOrDefault -Map $metadata -Key 'preferredProjectionViews')) {
                    $viewTable = ConvertTo-Dictionary -Value $view
                    if ($null -eq $viewTable) { continue }
                    [pscustomobject]@{
                        Name = [string](Get-MapValueOrDefault -Map $viewTable -Key 'name')
                        ProjectionRef = [string](Get-MapValueOrDefault -Map $viewTable -Key 'projectionRef')
                    }
                }
            )
            Metadata = Copy-PlainValue -Value $metadata
        }
    }

    return $map
}

function Get-ProjectionContractSurface {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $path = Join-Path (Join-Path (Join-Path $ContractsRoot 'tech') $TechId) 'assembler.projections.v1.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{
            Path = $path
            Definitions = [ordered]@{}
            Aliases = [ordered]@{}
            AllRefs = @()
        }
    }

    $document = Read-JsonFile -Path $path
    $definitions = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $document -Key 'projections')
    $aliases = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $document -Key 'aliases')
    if ($null -eq $definitions) { $definitions = [ordered]@{} }
    if ($null -eq $aliases) { $aliases = [ordered]@{} }

    $allRefs = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($definitions.Keys)) {
        $allRefs.Add([string]$key) | Out-Null
    }
    foreach ($key in @($aliases.Keys)) {
        if (-not $allRefs.Contains([string]$key)) {
            $allRefs.Add([string]$key) | Out-Null
        }
    }

    return [ordered]@{
        Path = $path
        Definitions = $definitions
        Aliases = $aliases
        AllRefs = @($allRefs | Sort-Object -Unique)
    }
}

function Get-ProjectionDefinitionForRef {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ProjectionSurface,
        [Parameter(Mandatory = $false)][string]$ProjectionRef
    )

    if ([string]::IsNullOrWhiteSpace($ProjectionRef)) {
        return $null
    }

    $definitions = ConvertTo-Dictionary -Value $ProjectionSurface.Definitions
    $aliases = ConvertTo-Dictionary -Value $ProjectionSurface.Aliases

    if ($null -ne $definitions -and (Test-MapHasKey -Map $definitions -Key $ProjectionRef)) {
        return [ordered]@{
            RequestedRef = $ProjectionRef
            ResolvedRef = $ProjectionRef
            IsAlias = $false
            Definition = ConvertTo-Dictionary -Value $definitions[$ProjectionRef]
        }
    }

    if ($null -ne $aliases -and (Test-MapHasKey -Map $aliases -Key $ProjectionRef)) {
        $resolvedRef = [string]$aliases[$ProjectionRef]
        if ($null -ne $definitions -and (Test-MapHasKey -Map $definitions -Key $resolvedRef)) {
            return [ordered]@{
                RequestedRef = $ProjectionRef
                ResolvedRef = $resolvedRef
                IsAlias = $true
                Definition = ConvertTo-Dictionary -Value $definitions[$resolvedRef]
            }
        }
    }

    return $null
}

function Resolve-PreferredProjectionFromMetadata {
    param(
        [Parameter(Mandatory = $false)]$DatasetMetadata,
        [Parameter(Mandatory = $false)][string]$View
    )

    if ($null -eq $DatasetMetadata) {
        return $null
    }

    $candidates = @($DatasetMetadata.PreferredProjectionViews)
    if (@($candidates).Count -eq 0) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($View)) {
        $match = $candidates | Where-Object { [string]$_.Name -eq $View } | Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
    }

    return $candidates | Select-Object -First 1
}

function Get-ContractMappingTagPolicy {
    param([Parameter(Mandatory = $false)]$ContractDocument)

    $contract = ConvertTo-Dictionary -Value $ContractDocument
    $policyRoot = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $contract -Key 'collectorSdtTagPolicy')
    if ($null -eq $policyRoot) {
        return [ordered]@{
            required = $false
            tokenRewrites = [ordered]@{}
            tagAliases = [ordered]@{}
        }
    }

    $tokenRewrites = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $policyRoot -Key 'tokenRewrites')
    $tagAliases = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $policyRoot -Key 'tagAliases')
    if ($null -eq $tokenRewrites) { $tokenRewrites = [ordered]@{} }
    if ($null -eq $tagAliases) { $tagAliases = [ordered]@{} }

    return [ordered]@{
        required = [bool](Get-MapValueOrDefault -Map $policyRoot -Key 'required' -DefaultValue $false)
        tokenRewrites = Copy-PlainValue -Value $tokenRewrites
        tagAliases = Copy-PlainValue -Value $tagAliases
    }
}

function Resolve-CollectorTargetTag {
    param(
        [Parameter(Mandatory = $true)]$MappingEntry,
        [Parameter(Mandatory = $true)][hashtable]$TagPolicy
    )

    $entry = ConvertTo-Dictionary -Value $MappingEntry
    if ($null -eq $entry) {
        return ''
    }

    $target = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $entry -Key 'target')
    $tag = ''
    if ($null -ne $target) {
        if ((Test-MapHasKey -Map $target -Key 'path') -and -not [string]::IsNullOrWhiteSpace([string]$target.path)) {
            $tag = [string]$target.path
        }
        elseif ((Test-MapHasKey -Map $target -Key 'sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$target.sdtTag)) {
            $tag = [string]$target.sdtTag
        }
    }

    if ([string]::IsNullOrWhiteSpace($tag) -and (Test-MapHasKey -Map $entry -Key 'sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$entry.sdtTag)) {
        $tag = [string]$entry.sdtTag
    }
    if ([string]::IsNullOrWhiteSpace($tag)) {
        return ''
    }

    $normalized = $tag
    foreach ($sourceToken in @($TagPolicy.tokenRewrites.Keys)) {
        $normalized = $normalized.Replace([string]$sourceToken, [string]$TagPolicy.tokenRewrites[$sourceToken])
    }

    if (Test-MapHasKey -Map $TagPolicy.tagAliases -Key $normalized) {
        return [string]$TagPolicy.tagAliases[$normalized]
    }

    return $normalized
}

function Get-ContractSyncPolicy {
    param([Parameter(Mandatory = $false)]$ContractDocument)

    $defaultPolicy = [ordered]@{
        allowedRenderAs = @('table', 'scalar')
        selectorsByRenderAs = [ordered]@{
            table = @('items')
            scalar = @('items.0')
        }
        unsupportedRenderShape = [ordered]@{
            documentFacing = 'fail'
            nonDocumentFacing = 'skip'
        }
    }

    $contract = ConvertTo-Dictionary -Value $ContractDocument
    $syncPolicyRoot = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $contract -Key 'syncPolicy')
    $collectorPolicy = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $syncPolicyRoot -Key 'collectorSkeletonMapping')
    if ($null -eq $collectorPolicy) {
        return $defaultPolicy
    }

    $policy = Copy-PlainValue -Value $defaultPolicy
    if ((Test-MapHasKey -Map $collectorPolicy -Key 'allowedRenderAs') -and @($collectorPolicy.allowedRenderAs).Count -gt 0) {
        $policy.allowedRenderAs = @($collectorPolicy.allowedRenderAs | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }

    $selectorsRoot = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $collectorPolicy -Key 'selectors')
    $defaultByRenderAs = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $selectorsRoot -Key 'defaultByRenderAs')
    if ($null -ne $defaultByRenderAs) {
        $policy.selectorsByRenderAs = [ordered]@{}
        foreach ($key in @($defaultByRenderAs.Keys)) {
            $policy.selectorsByRenderAs[[string]$key] = @($defaultByRenderAs[$key] | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }
    }

    $unsupported = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $collectorPolicy -Key 'unsupportedRenderShape')
    if ($null -ne $unsupported) {
        foreach ($key in @('documentFacing', 'nonDocumentFacing')) {
            if ((Test-MapHasKey -Map $unsupported -Key $key) -and -not [string]::IsNullOrWhiteSpace([string]$unsupported[$key])) {
                $policy.unsupportedRenderShape[$key] = [string]$unsupported[$key]
            }
        }
    }

    return $policy
}

function Get-EffectiveMappingRenderHint {
    param(
        [Parameter(Mandatory = $false)]$Entry,
        [Parameter(Mandatory = $false)]$DatasetMetadata
    )

    $entryTable = ConvertTo-Dictionary -Value $Entry
    $renderHint = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $entryTable -Key 'renderHint')
    $hint = [ordered]@{}

    foreach ($key in @('renderAs', 'projectionRef', 'view', 'emptyBehavior')) {
        if ($null -ne $renderHint -and (Test-MapHasKey -Map $renderHint -Key $key) -and -not [string]::IsNullOrWhiteSpace([string]$renderHint[$key])) {
            $hint[$key] = [string]$renderHint[$key]
        }
    }

    if (-not (Test-MapHasKey -Map $hint -Key 'projectionRef')) {
        $preferred = Resolve-PreferredProjectionFromMetadata -DatasetMetadata $DatasetMetadata -View (Get-MapValueOrDefault -Map $hint -Key 'view')
        if ($null -ne $preferred -and -not [string]::IsNullOrWhiteSpace([string]$preferred.ProjectionRef)) {
            $hint.projectionRef = [string]$preferred.ProjectionRef
            if (-not (Test-MapHasKey -Map $hint -Key 'view') -and -not [string]::IsNullOrWhiteSpace([string]$preferred.Name)) {
                $hint.view = [string]$preferred.Name
            }
        }
    }

    if (-not (Test-MapHasKey -Map $hint -Key 'renderAs')) {
        $presentationKind = if ($null -ne $DatasetMetadata) { [string]$DatasetMetadata.PresentationKind } else { '' }
        switch ($presentationKind) {
            'summary' { $hint.renderAs = 'scalar' }
            'table' { $hint.renderAs = 'table' }
        }
    }

    return $hint
}

function Get-EffectiveRenderMode {
    param(
        [Parameter(Mandatory = $false)]$Entry,
        [Parameter(Mandatory = $false)]$DatasetMetadata,
        [Parameter(Mandatory = $true)][hashtable]$ProjectionSurface
    )

    $hint = Get-EffectiveMappingRenderHint -Entry $Entry -DatasetMetadata $DatasetMetadata
    $renderAs = [string](Get-MapValueOrDefault -Map $hint -Key 'renderAs')
    if (-not [string]::IsNullOrWhiteSpace($renderAs)) {
        return $renderAs
    }

    $projectionRef = [string](Get-MapValueOrDefault -Map $hint -Key 'projectionRef')
    $projection = Get-ProjectionDefinitionForRef -ProjectionSurface $ProjectionSurface -ProjectionRef $projectionRef
    if ($null -ne $projection -and $null -ne $projection.Definition) {
        $definition = ConvertTo-Dictionary -Value $projection.Definition
        if ((Test-MapHasKey -Map $definition -Key 'renderAs') -and -not [string]::IsNullOrWhiteSpace([string]$definition.renderAs)) {
            return [string]$definition.renderAs
        }
        if ((Test-MapHasKey -Map $definition -Key 'renderMode') -and -not [string]::IsNullOrWhiteSpace([string]$definition.renderMode)) {
            return [string]$definition.renderMode
        }
    }

    $presentationKind = if ($null -ne $DatasetMetadata) { [string]$DatasetMetadata.PresentationKind } else { '' }
    if ($presentationKind -eq 'summary') {
        return 'scalar'
    }
    if ($presentationKind -in @('table', 'relationship', 'relationshipTable')) {
        return 'table'
    }

    return ''
}

function Resolve-DatasetExamplePath {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $false)]$DatasetMetadata,
        [Parameter(Mandatory = $true)][string]$DatasetId,
        [Parameter(Mandatory = $true)][hashtable]$DatasetContext
    )

    if ($null -eq $DatasetMetadata -or [string]::IsNullOrWhiteSpace([string]$DatasetMetadata.PathTemplate)) {
        return $null
    }

    $resolvedRelative = [string]$DatasetMetadata.PathTemplate
    $resolvedRelative = $resolvedRelative.Replace('__TECH_ID__', $TechId)
    $resolvedRelative = $resolvedRelative.Replace('__DATASET__', $DatasetId)
    $resolvedRelative = $resolvedRelative.Replace('__TARGET__', [string]$DatasetContext.targetRelativePrefix)

    if ($resolvedRelative -match '__SYSTEM__') {
        $systemName = if (-not [string]::IsNullOrWhiteSpace([string]$DatasetContext.selectedSystem)) { [string]$DatasetContext.selectedSystem } else { '' }
        if ([string]::IsNullOrWhiteSpace($systemName)) {
            return $null
        }
        $resolvedRelative = $resolvedRelative.Replace('__SYSTEM__', $systemName)
    }

    $resolvedPath = Join-Path $BundleRoot $resolvedRelative
    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        return $resolvedPath
    }

    return $null
}

function Read-DatasetExample {
    param([Parameter(Mandatory = $false)][string]$ExamplePath)

    if ([string]::IsNullOrWhiteSpace($ExamplePath) -or -not (Test-Path -LiteralPath $ExamplePath -PathType Leaf)) {
        return $null
    }

    try {
        return (Read-JsonFile -Path $ExamplePath)
    }
    catch {
        return $null
    }
}

function Resolve-SelectorValue {
    param(
        [Parameter(Mandatory = $false)]$Data,
        [Parameter(Mandatory = $false)][string]$Selector
    )

    if ($null -eq $Data) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($Selector)) {
        return $Data
    }

    $current = $Data
    foreach ($segment in @($Selector -split '\.')) {
        if ($null -eq $current) {
            return $null
        }

        $currentTable = ConvertTo-Dictionary -Value $current
        if ($null -ne $currentTable) {
            if (-not (Test-MapHasKey -Map $currentTable -Key $segment)) {
                return $null
            }
            $current = $currentTable[$segment]
            continue
        }

        if (($current -is [System.Collections.IList]) -or ($current -is [object[]])) {
            $index = -1
            if (-not [int]::TryParse($segment, [ref]$index)) {
                return $null
            }
            if ($index -lt 0 -or $index -ge @($current).Count) {
                return $null
            }
            $current = @($current)[$index]
            continue
        }

        return $null
    }

    return $current
}

function Format-BytesHuman {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [ref]$number)) {
        return [string]$Value
    }

    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $unitIndex = 0
    while ($number -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $number = $number / 1024
        $unitIndex++
    }

    return ('{0:N2} {1}' -f $number, $units[$unitIndex])
}

function Format-ProjectionColumnValue {
    param(
        [Parameter(Mandatory = $false)]$Row,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Column
    )

    $source = [string](Get-MapValueOrDefault -Map $Column -Key 'source')
    $format = [string](Get-MapValueOrDefault -Map $Column -Key 'format')
    $delimiter = [string](Get-MapValueOrDefault -Map $Column -Key 'delimiter' -DefaultValue ', ')
    $value = Resolve-SelectorValue -Data $Row -Selector $source

    if ($format -eq 'bytesHuman') {
        return (Format-BytesHuman -Value $value)
    }
    if ($format -eq 'join') {
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            return ((@($value) | ForEach-Object { [string]$_ }) -join $delimiter)
        }
        return [string]$value
    }

    if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
        return ((@($value) | ForEach-Object { [string]$_ }) -join ', ')
    }

    return [string]$value
}

function Test-ProjectionFilterMatch {
    param(
        [Parameter(Mandatory = $false)]$Row,
        [Parameter(Mandatory = $false)]$FilterDefinition
    )

    if ($null -eq $FilterDefinition) {
        return $true
    }

    $filter = ConvertTo-Dictionary -Value $FilterDefinition
    if ($null -eq $filter) {
        return $true
    }

    $field = [string](Get-MapValueOrDefault -Map $filter -Key 'field')
    $equals = Get-MapValueOrDefault -Map $filter -Key 'equals'
    if ([string]::IsNullOrWhiteSpace($field)) {
        return $true
    }

    $value = Resolve-SelectorValue -Data $Row -Selector $field
    return ([string]$value -eq [string]$equals)
}

function Sort-PreviewRows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $false)]$RowOrder
    )

    if (@($Rows).Count -eq 0 -or $null -eq $RowOrder) {
        return @($Rows)
    }

    $sortExpressions = @()
    foreach ($order in @($RowOrder)) {
        $orderTable = ConvertTo-Dictionary -Value $order
        if ($null -eq $orderTable) {
            $field = [string]$order
            if ([string]::IsNullOrWhiteSpace($field)) { continue }
            $sortExpressions += @{
                Expression = { [string](Resolve-SelectorValue -Data $_ -Selector $field) }
                Descending = $false
            }
            continue
        }

        $field = [string](Get-MapValueOrDefault -Map $orderTable -Key 'by')
        if ([string]::IsNullOrWhiteSpace($field)) { continue }
        $descending = ([string](Get-MapValueOrDefault -Map $orderTable -Key 'direction') -eq 'desc')
        $sortExpressions += @{
            Expression = { [string](Resolve-SelectorValue -Data $_ -Selector $field) }
            Descending = $descending
        }
    }

    if (@($sortExpressions).Count -eq 0) {
        return @($Rows)
    }

    return @($Rows | Sort-Object -Property $sortExpressions)
}

function Add-SelectorCandidates {
    param(
        [Parameter(Mandatory = $true)]$Candidates,
        [Parameter(Mandatory = $false)][string]$Selector
    )

    if ([string]::IsNullOrWhiteSpace($Selector)) {
        return
    }

    if (-not $Candidates.Contains($Selector)) {
        $Candidates.Add($Selector) | Out-Null
    }
}

function ConvertTo-ObjectArray {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        return @($Value | ForEach-Object { $_ })
    }

    return @($Value)
}

function Get-DefaultSelectorForRenderAs {
    param(
        [Parameter(Mandatory = $true)][string]$RenderAs,
        [Parameter(Mandatory = $false)]$DatasetNode,
        [Parameter(Mandatory = $true)][hashtable]$SyncPolicy
    )

    $datasetDefault = if ($null -ne $DatasetNode -and -not [string]::IsNullOrWhiteSpace([string]$DatasetNode.DefaultItemRoot)) { [string]$DatasetNode.DefaultItemRoot } else { 'items' }
    if ($RenderAs -eq 'table') {
        $candidate = @($SyncPolicy.selectorsByRenderAs.table | Select-Object -First 1)[0]
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { $candidate = $datasetDefault }
        return [string]$candidate
    }

    $scalarCandidate = @($SyncPolicy.selectorsByRenderAs.scalar | Select-Object -First 1)[0]
    if (-not [string]::IsNullOrWhiteSpace([string]$scalarCandidate)) {
        return [string]$scalarCandidate
    }

    if ([string]::IsNullOrWhiteSpace($datasetDefault)) {
        return 'items.0'
    }
    if ($datasetDefault.EndsWith('.0')) {
        return $datasetDefault
    }
    return "$datasetDefault.0"
}

function Get-SelectorCandidatesForDataset {
    param(
        [Parameter(Mandatory = $false)]$DatasetNode,
        [Parameter(Mandatory = $false)]$ExampleData,
        [Parameter(Mandatory = $true)][string]$RenderAs,
        [Parameter(Mandatory = $true)][hashtable]$SyncPolicy
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    Add-SelectorCandidates -Candidates $candidates -Selector (Get-DefaultSelectorForRenderAs -RenderAs $RenderAs -DatasetNode $DatasetNode -SyncPolicy $SyncPolicy)

    if ($null -eq $DatasetNode) {
        return @($candidates)
    }

    $defaultRoot = if (-not [string]::IsNullOrWhiteSpace([string]$DatasetNode.DefaultItemRoot)) { [string]$DatasetNode.DefaultItemRoot } else { 'items' }
    Add-SelectorCandidates -Candidates $candidates -Selector $defaultRoot

    if ($null -eq $ExampleData) {
        return @($candidates)
    }

    $rootValue = Resolve-SelectorValue -Data $ExampleData -Selector $defaultRoot
    $sample = $rootValue
    if ($rootValue -is [System.Collections.IList] -or $rootValue -is [object[]]) {
        if (@($rootValue).Count -gt 0) {
            $sample = @($rootValue)[0]
        }
    }

    $sampleTable = ConvertTo-Dictionary -Value $sample
    if ($null -ne $sampleTable) {
        foreach ($key in @($sampleTable.Keys | Sort-Object)) {
            $prefix = if ($RenderAs -eq 'scalar') { "$defaultRoot.0.$key" } else { "$defaultRoot.$key" }
            Add-SelectorCandidates -Candidates $candidates -Selector $prefix

            $nestedTable = ConvertTo-Dictionary -Value $sampleTable[$key]
            if ($null -ne $nestedTable) {
                foreach ($nestedKey in @($nestedTable.Keys | Sort-Object | Select-Object -First 8)) {
                    Add-SelectorCandidates -Candidates $candidates -Selector ("{0}.{1}" -f $prefix, $nestedKey)
                }
            }
        }
    }

    return @($candidates)
}

function Get-TargetTagsFromText {
    param([Parameter(Mandatory = $false)][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $matches = [regex]::Matches($Text, 'LNV\.[A-Za-z0-9\.\[\]<>-]+')
    $tags = [System.Collections.Generic.List[string]]::new()
    foreach ($match in @($matches)) {
        $value = [string]$match.Value
        if (-not [string]::IsNullOrWhiteSpace($value) -and -not $tags.Contains($value)) {
            $tags.Add($value) | Out-Null
        }
    }

    return @($tags)
}

function Get-PlacementEvidence {
    param([Parameter(Mandatory = $true)]$Collection)

    $mappingPath = [string]$Collection.MappingPath
    $templatePath = [string]$Collection.TemplatePath
    $tokenAuditPath = $null
    if (-not [string]::IsNullOrWhiteSpace($mappingPath)) {
        $mappingDirectory = Split-Path -Parent $mappingPath
        $mappingFileName = [System.IO.Path]::GetFileName($mappingPath)
        $tokenAuditFileName = if ($mappingFileName -match '\.mapping\.(json|txt)$') {
            $mappingFileName -replace '\.mapping\.(json|txt)$', '.token-audit.md'
        }
        else {
            [System.IO.Path]::ChangeExtension($mappingFileName, '.token-audit.md')
        }
        $tokenAuditPath = Join-Path $mappingDirectory $tokenAuditFileName
    }
    $headingMapPath = if ([string]::IsNullOrWhiteSpace($templatePath)) { $null } else { [System.IO.Path]::ChangeExtension($templatePath, '.heading-tag-map.md') }
    $tokenAuditText = if ($null -ne $tokenAuditPath) { Get-FileTextIfExists -Path $tokenAuditPath } else { $null }
    $headingMapText = if ($null -ne $headingMapPath) { Get-FileTextIfExists -Path $headingMapPath } else { $null }

    $placedTags = [System.Collections.Generic.List[string]]::new()
    $stageOnlyTags = [System.Collections.Generic.List[string]]::new()

    foreach ($tag in @(Get-TargetTagsFromText -Text $tokenAuditText)) {
        if (-not $placedTags.Contains($tag)) {
            $placedTags.Add($tag) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($headingMapText)) {
        $currentSection = ''
        foreach ($line in @($headingMapText -split "(`r`n|`n)")) {
            if ($line -match '^##\s+') {
                $currentSection = [string]$line
            }
            foreach ($tag in @(Get-TargetTagsFromText -Text $line)) {
                if ($currentSection -match 'Available but not placed') {
                    if (-not $stageOnlyTags.Contains($tag)) {
                        $stageOnlyTags.Add($tag) | Out-Null
                    }
                    continue
                }
                if (-not $placedTags.Contains($tag)) {
                    $placedTags.Add($tag) | Out-Null
                }
            }
        }
    }

    return [ordered]@{
        tokenAuditPath = $tokenAuditPath
        headingMapPath = $headingMapPath
        hasEvidence = (-not [string]::IsNullOrWhiteSpace($tokenAuditText)) -or (-not [string]::IsNullOrWhiteSpace($headingMapText))
        placedTags = @($placedTags | Sort-Object -Unique)
        stageOnlyTags = @($stageOnlyTags | Sort-Object -Unique)
        missingTokenAudit = [string]::IsNullOrWhiteSpace($tokenAuditText)
        missingHeadingMap = [string]::IsNullOrWhiteSpace($headingMapText)
    }
}

function Get-EffectiveMappingDocument {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)]$Collection
    )

    $yamlSupport = Get-MappingStudioYamlSupport
    $techId = [string]$Collection.TechId
    $contractRelativePath = "tech/$techId/mapping.dataset-to-sdt.v1.yaml"
    $contractPath = Join-Path $ContractsRoot $contractRelativePath
    $runtimePath = [string]$Collection.MappingPath

    if ([bool]$yamlSupport.canRead -and (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        $contract = Read-YamlFileSafe -Path $contractPath
        return [ordered]@{
            source = 'contract'
            readOnly = (-not [bool]$yamlSupport.available)
            readOnlyReason = if ([bool]$yamlSupport.available) { '' } else { [string]$yamlSupport.message }
            yamlSupport = $yamlSupport
            contractRelativePath = $contractRelativePath
            contractPath = $contractPath
            runtimePath = $runtimePath
            document = Copy-PlainValue -Value $contract
        }
    }

    $runtime = if (-not [string]::IsNullOrWhiteSpace($runtimePath) -and (Test-Path -LiteralPath $runtimePath -PathType Leaf)) { Read-JsonFile -Path $runtimePath } else { [ordered]@{ mappings = @() } }
    return [ordered]@{
        source = 'runtime-fallback'
        readOnly = $true
        readOnlyReason = if ([string]::IsNullOrWhiteSpace([string]$yamlSupport.message)) { 'Contract YAML parsing is unavailable in this session, so Mapping Studio is read-only.' } else { [string]$yamlSupport.message }
        yamlSupport = $yamlSupport
        contractRelativePath = $contractRelativePath
        contractPath = $contractPath
        runtimePath = $runtimePath
        document = Copy-PlainValue -Value $runtime
    }
}

function Get-MappingTypeLabel {
    param(
        [Parameter(Mandatory = $false)]$Entry,
        [Parameter(Mandatory = $false)]$DatasetMetadata,
        [Parameter(Mandatory = $true)][hashtable]$ProjectionSurface,
        [Parameter(Mandatory = $false)][string]$TargetPath
    )

    $renderAs = Get-EffectiveRenderMode -Entry $Entry -DatasetMetadata $DatasetMetadata -ProjectionSurface $ProjectionSurface
    $presentationKind = if ($null -ne $DatasetMetadata) { [string]$DatasetMetadata.PresentationKind } else { '' }
    $datasetId = if ($null -ne $DatasetMetadata) { [string]$DatasetMetadata.DatasetId } else { '' }
    $hint = Get-EffectiveMappingRenderHint -Entry $Entry -DatasetMetadata $DatasetMetadata
    $projectionRef = [string](Get-MapValueOrDefault -Map $hint -Key 'projectionRef')

    if ($renderAs -eq 'scalar') {
        return 'Summary/Scalar'
    }

    if ($renderAs -eq 'table') {
        if ($presentationKind -in @('relationship', 'relationshipTable') -or $datasetId -match '-to-' -or $TargetPath -match 'To[A-Za-z]') {
            return 'Relationship Table'
        }
        if (-not [string]::IsNullOrWhiteSpace($projectionRef)) {
            return 'Table Projection'
        }
        if ($presentationKind -eq 'evidence') {
            return 'Evidence/Debug'
        }
        return 'Table Projection'
    }

    if ($presentationKind -eq 'evidence' -or $TargetPath -match 'Evidence|Debug|raw') {
        return 'Evidence/Debug'
    }

    return 'Unknown/Unsupported'
}

function New-MappingEntryView {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][hashtable]$DatasetMetadataMap,
        [Parameter(Mandatory = $true)][hashtable]$ProjectionSurface,
        [Parameter(Mandatory = $true)][hashtable]$TagPolicy,
        [Parameter(Mandatory = $true)][hashtable]$SyncPolicy
    )

    $entryTable = ConvertTo-Dictionary -Value $Entry
    if ($null -eq $entryTable) {
        return $null
    }

    $datasetId = [string](Get-MapValueOrDefault -Map $entryTable -Key 'dataset')
    if ($datasetId -match '[/\\]') {
        $datasetId = [System.IO.Path]::GetFileNameWithoutExtension($datasetId)
    }

    $datasetMetadata = if (Test-MapHasKey -Map $DatasetMetadataMap -Key $datasetId) { $DatasetMetadataMap[$datasetId] } else { $null }
    $targetPath = Resolve-CollectorTargetTag -MappingEntry $entryTable -TagPolicy $TagPolicy
    $target = ConvertTo-Dictionary -Value (Get-MapValueOrDefault -Map $entryTable -Key 'target')
    $canonicalTargetPath = if ($null -ne $target -and (Test-MapHasKey -Map $target -Key 'path') -and -not [string]::IsNullOrWhiteSpace([string]$target.path)) { [string]$target.path } elseif ((Test-MapHasKey -Map $entryTable -Key 'sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$entryTable.sdtTag)) { [string]$entryTable.sdtTag } else { $targetPath }
    $renderHint = Get-EffectiveMappingRenderHint -Entry $entryTable -DatasetMetadata $datasetMetadata
    $renderAs = Get-EffectiveRenderMode -Entry $entryTable -DatasetMetadata $datasetMetadata -ProjectionSurface $ProjectionSurface
    $selectors = @()
    if (Test-MapHasKey -Map $entryTable -Key 'selectors') {
        $selectors = @($entryTable.selectors | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if (@($selectors).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($renderAs)) {
        $selectors = @((Get-DefaultSelectorForRenderAs -RenderAs $renderAs -DatasetNode $datasetMetadata -SyncPolicy $SyncPolicy))
    }

    $typeLabel = Get-MappingTypeLabel -Entry $entryTable -DatasetMetadata $datasetMetadata -ProjectionSurface $ProjectionSurface -TargetPath $targetPath
    return [pscustomobject]@{
        DatasetId = $datasetId
        DatasetMetadata = $datasetMetadata
        CanonicalTargetPath = $canonicalTargetPath
        TargetPath = $targetPath
        RenderAs = $renderAs
        ProjectionRef = [string](Get-MapValueOrDefault -Map $renderHint -Key 'projectionRef')
        View = [string](Get-MapValueOrDefault -Map $renderHint -Key 'view')
        Selectors = @($selectors)
        PrimarySelector = if (@($selectors).Count -gt 0) { [string]$selectors[0] } else { '' }
        Required = [bool](Get-MapValueOrDefault -Map $entryTable -Key 'required' -DefaultValue $false)
        Notes = [string](Get-MapValueOrDefault -Map $entryTable -Key 'notes')
        TypeLabel = $typeLabel
        Entry = Copy-PlainValue -Value $entryTable
        Label = ("{0} -> {1} [{2}]" -f $datasetId, $targetPath, $typeLabel)
    }
}

function Get-ConnectionPlacementBadge {
    param([Parameter(Mandatory = $false)]$TargetNode)

    if ($null -eq $TargetNode) {
        return 'unknown'
    }

    switch ([string]$TargetNode.PlacementGroup) {
        'Placed in template' { return 'placed' }
        'Available to stage' { return 'staged' }
        'Mapped but not placed' { return 'not placed' }
        default { return 'unknown' }
    }
}

function New-ConnectionRowView {
    param(
        [Parameter(Mandatory = $true)]$MappingView,
        [Parameter(Mandatory = $false)]$DatasetNode,
        [Parameter(Mandatory = $false)]$TargetNode
    )

    $badges = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$MappingView.RenderAs)) {
        $badges.Add([string]$MappingView.RenderAs) | Out-Null
    }

    $placementBadge = Get-ConnectionPlacementBadge -TargetNode $TargetNode
    if (-not [string]::IsNullOrWhiteSpace([string]$placementBadge)) {
        $badges.Add([string]$placementBadge) | Out-Null
    }

    if ([bool]$MappingView.Required) {
        $badges.Add('required') | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$MappingView.ProjectionRef)) {
        $badges.Add('projection') | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$MappingView.View)) {
        $badges.Add(("view:{0}" -f [string]$MappingView.View)) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$MappingView.TypeLabel)) {
        $badges.Add([string]$MappingView.TypeLabel) | Out-Null
    }

    $summarySegments = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$MappingView.PrimarySelector)) {
        $summarySegments.Add(("selector={0}" -f [string]$MappingView.PrimarySelector)) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$MappingView.ProjectionRef)) {
        $summarySegments.Add(("projection={0}" -f [string]$MappingView.ProjectionRef)) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$MappingView.View)) {
        $summarySegments.Add(("view={0}" -f [string]$MappingView.View)) | Out-Null
    }

    $datasetScope = if ($null -ne $DatasetNode) { [string]$DatasetNode.Scope } elseif ($null -ne $MappingView.DatasetMetadata) { [string]$MappingView.DatasetMetadata.Scope } else { '' }
    $datasetPresentation = if ($null -ne $DatasetNode) { [string]$DatasetNode.PresentationKind } elseif ($null -ne $MappingView.DatasetMetadata) { [string]$MappingView.DatasetMetadata.PresentationKind } else { '' }

    $connectionKey = "{0}|{1}|{2}|{3}|{4}|{5}" -f `
        [string]$MappingView.DatasetId, `
        [string]$MappingView.TargetPath, `
        [string]$MappingView.RenderAs, `
        [string]$MappingView.PrimarySelector, `
        [string]$MappingView.ProjectionRef, `
        [string]$MappingView.View

    return [pscustomobject]@{
        ConnectionKey = $connectionKey
        DatasetId = [string]$MappingView.DatasetId
        DatasetNode = $DatasetNode
        DatasetScope = $datasetScope
        DatasetPresentationKind = $datasetPresentation
        TargetPath = [string]$MappingView.TargetPath
        TargetNode = $TargetNode
        PlacementGroup = if ($null -ne $TargetNode) { [string]$TargetNode.PlacementGroup } else { 'Placement unknown' }
        PlacementBadge = $placementBadge
        RenderAs = [string]$MappingView.RenderAs
        ProjectionRef = [string]$MappingView.ProjectionRef
        View = [string]$MappingView.View
        PrimarySelector = [string]$MappingView.PrimarySelector
        Required = [bool]$MappingView.Required
        TypeLabel = [string]$MappingView.TypeLabel
        HasExampleData = if ($null -ne $DatasetNode) { [bool]$DatasetNode.HasExampleData } else { $false }
        ExamplePath = if ($null -ne $DatasetNode) { [string]$DatasetNode.ExamplePath } else { '' }
        TargetMappingCount = if ($null -ne $TargetNode) { [int]$TargetNode.MappingCount } else { 1 }
        DuplicateTargetMapping = if ($null -ne $TargetNode) { [int]$TargetNode.MappingCount -gt 1 } else { $false }
        MappingView = $MappingView
        Label = ("{0} -> {1}" -f [string]$MappingView.DatasetId, [string]$MappingView.TargetPath)
        Summary = if ($summarySegments.Count -gt 0) { ($summarySegments -join ' | ') } else { 'No selector or projection summary is available for this mapping.' }
        BadgeText = ($badges -join ' | ')
        SearchText = ((@(
                    [string]$MappingView.DatasetId
                    [string]$MappingView.TargetPath
                    [string]$MappingView.RenderAs
                    [string]$MappingView.PrimarySelector
                    [string]$MappingView.ProjectionRef
                    [string]$MappingView.View
                    [string]$MappingView.TypeLabel
                    [string]$datasetScope
                    [string]$datasetPresentation
                    if ($null -ne $TargetNode) { [string]$TargetNode.PlacementGroup }
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ')
    }
}

function Select-MappingStudioConnectionRows {
    param(
        [Parameter(Mandatory = $false)][object[]]$ConnectionRows = @(),
        [Parameter(Mandatory = $false)][string]$SearchText = '',
        [Parameter(Mandatory = $false)][string]$QuickFilter = 'All'
    )

    $filtered = @($ConnectionRows)
    $normalizedQuickFilter = if ([string]::IsNullOrWhiteSpace([string]$QuickFilter)) { 'all' } else { [string]$QuickFilter }
    $normalizedQuickFilter = $normalizedQuickFilter.ToLowerInvariant()
    switch ($normalizedQuickFilter) {
        'placed' {
            $filtered = @($filtered | Where-Object { [string]$_.PlacementGroup -eq 'Placed in template' })
        }
        'staged' {
            $filtered = @($filtered | Where-Object { [string]$_.PlacementGroup -eq 'Available to stage' })
        }
        'scalar' {
            $filtered = @($filtered | Where-Object { [string]$_.RenderAs -eq 'scalar' })
        }
        'table' {
            $filtered = @($filtered | Where-Object { [string]$_.RenderAs -eq 'table' })
        }
        'mapped' {
            $filtered = @($filtered | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.TargetPath) })
        }
        default { }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$SearchText)) {
        $needle = [string]$SearchText
        $filtered = @($filtered | Where-Object {
                $haystack = [string]$_.SearchText
                $haystack.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            })
    }

    return @($filtered | Sort-Object @{ Expression = { [string]$_.TargetPath } }, @{ Expression = { [string]$_.DatasetId } }, @{ Expression = { [string]$_.PrimarySelector } })
}

function Get-MappingStudioPreview {
    param(
        [Parameter(Mandatory = $true)]$Workbench,
        [Parameter(Mandatory = $true)][string]$DatasetId,
        [Parameter(Mandatory = $true)][string]$RenderAs,
        [Parameter(Mandatory = $false)][string]$Selector,
        [Parameter(Mandatory = $false)][string]$ProjectionRef,
        [Parameter(Mandatory = $false)][string]$View
    )

    $datasetById = ConvertTo-Dictionary -Value $Workbench.DatasetById
    if ($null -eq $datasetById -or -not (Test-MapHasKey -Map $datasetById -Key $DatasetId)) {
        return [ordered]@{
            Status = 'missing-dataset'
            Message = "Dataset '$DatasetId' is not available in the current Mapping Studio workbench."
        }
    }

    $datasetNode = $datasetById[$DatasetId]
    if (-not $datasetNode.HasExampleData) {
        return [ordered]@{
            Status = 'missing-example'
            Message = "No example bundle data was found for dataset '$DatasetId'. Preview is unavailable, but the mapping can still be authored."
            ExamplePath = $datasetNode.ExamplePath
        }
    }

    $selectorToUse = if ([string]::IsNullOrWhiteSpace($Selector)) {
        Get-DefaultSelectorForRenderAs -RenderAs $RenderAs -DatasetNode $datasetNode -SyncPolicy $Workbench.SyncPolicy
    }
    else {
        $Selector
    }

    $resolvedValue = Resolve-SelectorValue -Data $datasetNode.ExampleData -Selector $selectorToUse
    if ($RenderAs -eq 'scalar') {
        return [ordered]@{
            Status = 'ok'
            RenderAs = 'scalar'
            Selector = $selectorToUse
            ProjectionRef = $ProjectionRef
            View = $View
            ExamplePath = $datasetNode.ExamplePath
            SampleValue = if ($resolvedValue -is [System.Collections.IEnumerable] -and -not ($resolvedValue -is [string])) { (ConvertTo-ObjectArray -Value $resolvedValue | ConvertTo-Json -Depth 20 -Compress) } else { [string]$resolvedValue }
        }
    }

    if ($RenderAs -ne 'table') {
        return [ordered]@{
            Status = 'unsupported'
            RenderAs = $RenderAs
            Message = "Render shape '$RenderAs' is not authoring-capable in Mapping Studio v1."
        }
    }

    $rows = @()
    if ($resolvedValue -is [System.Collections.IEnumerable] -and -not ($resolvedValue -is [string])) {
        $rows = @($resolvedValue)
    }
    elseif ($null -ne $resolvedValue) {
        $rows = @($resolvedValue)
    }

    $projection = Get-ProjectionDefinitionForRef -ProjectionSurface $Workbench.ProjectionSurface -ProjectionRef $ProjectionRef
    $filters = @()
    $columns = @()
    $rowOrder = @()
    $projectionSummary = $null
    $previewRows = [System.Collections.Generic.List[object]]::new()

    if ($null -ne $projection -and $null -ne $projection.Definition) {
        $definition = ConvertTo-Dictionary -Value $projection.Definition
        $filters = @(Get-MapValueOrDefault -Map $definition -Key 'filter')
        $columns = @(Get-MapValueOrDefault -Map $definition -Key 'columns')
        $rowOrder = @(Get-MapValueOrDefault -Map $definition -Key 'rowOrder')
        $projectionSummary = $projection.ResolvedRef
    }

    $filteredRows = @()
    foreach ($row in @($rows)) {
        $include = $true
        foreach ($filter in @($filters)) {
            if (-not (Test-ProjectionFilterMatch -Row $row -FilterDefinition $filter)) {
                $include = $false
                break
            }
        }
        if ($include) {
            $filteredRows += ,$row
        }
    }

    $filteredRows = @(Sort-PreviewRows -Rows @($filteredRows) -RowOrder $rowOrder)
    foreach ($row in @($filteredRows | Select-Object -First 8)) {
        if (@($columns).Count -gt 0) {
            $previewRow = [ordered]@{}
            foreach ($column in @($columns)) {
                $columnTable = ConvertTo-Dictionary -Value $column
                if ($null -eq $columnTable) { continue }
                $columnName = [string](Get-MapValueOrDefault -Map $columnTable -Key 'name')
                $previewRow[$columnName] = Format-ProjectionColumnValue -Row $row -Column $columnTable
            }
            $previewRows.Add($previewRow) | Out-Null
            continue
        }

        $rowTable = ConvertTo-Dictionary -Value $row
        if ($null -ne $rowTable) {
            $previewRow = [ordered]@{}
            foreach ($key in @($rowTable.Keys | Select-Object -First 8)) {
                $previewRow[[string]$key] = [string]$rowTable[$key]
            }
            $previewRows.Add($previewRow) | Out-Null
            continue
        }

        $previewRows.Add([ordered]@{ Value = [string]$row }) | Out-Null
    }

    return [ordered]@{
        Status = 'ok'
        RenderAs = 'table'
        Selector = $selectorToUse
        ProjectionRef = $ProjectionRef
        View = $View
        ProjectionSummary = $projectionSummary
        ExamplePath = $datasetNode.ExamplePath
        FilterSummary = @($filters | ForEach-Object {
                $filterTable = ConvertTo-Dictionary -Value $_
                if ($null -eq $filterTable) { return }
                "{0} = {1}" -f [string](Get-MapValueOrDefault -Map $filterTable -Key 'field'), [string](Get-MapValueOrDefault -Map $filterTable -Key 'equals')
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        ColumnNames = @($columns | ForEach-Object {
                $columnTable = ConvertTo-Dictionary -Value $_
                if ($null -eq $columnTable) { return }
                [string](Get-MapValueOrDefault -Map $columnTable -Key 'name')
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        RowOrder = @($rowOrder | ForEach-Object {
                $orderTable = ConvertTo-Dictionary -Value $_
                if ($null -ne $orderTable) {
                    "{0} ({1})" -f [string](Get-MapValueOrDefault -Map $orderTable -Key 'by'), [string](Get-MapValueOrDefault -Map $orderTable -Key 'direction' -DefaultValue 'asc')
                }
                else {
                    [string]$_
                }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        RowCount = @($filteredRows).Count
        PreviewRows = ConvertTo-ObjectArray -Value $previewRows
    }
}

function Get-MappingStudioWorkbench {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)]$Collection
    )

    $resolvedBundle = Resolve-MappingStudioBundleRoot -BundleRoot $BundleRoot
    $mappingDoc = Get-EffectiveMappingDocument -ContractsRoot $ContractsRoot -Collection $Collection
    $tagPolicy = Get-ContractMappingTagPolicy -ContractDocument $mappingDoc.document
    $syncPolicy = Get-ContractSyncPolicy -ContractDocument $mappingDoc.document
    $projectionSurface = Get-ProjectionContractSurface -ContractsRoot $ContractsRoot -TechId ([string]$Collection.TechId)
    $datasetMetadataMap = Get-DatasetMetadataMap -ContractsRoot $ContractsRoot -TechId ([string]$Collection.TechId)
    $datasetContext = Resolve-MappingStudioTechDatasetContext -BundleRoot ([string]$resolvedBundle.bundleRoot) -TechId ([string]$Collection.TechId) -CatalogEntry (ConvertTo-Dictionary -Value $Collection.Entry)
    $placementEvidence = Get-PlacementEvidence -Collection $Collection

    $mappingViews = [System.Collections.Generic.List[object]]::new()
    $mappingByTarget = [ordered]@{}
    foreach ($entry in @($mappingDoc.document.mappings)) {
        $view = New-MappingEntryView -Entry $entry -DatasetMetadataMap $datasetMetadataMap -ProjectionSurface $projectionSurface -TagPolicy $tagPolicy -SyncPolicy $syncPolicy
        if ($null -eq $view) { continue }
        $mappingViews.Add($view) | Out-Null
        if (-not (Test-MapHasKey -Map $mappingByTarget -Key $view.TargetPath)) {
            $mappingByTarget[$view.TargetPath] = New-Object System.Collections.Generic.List[object]
        }
        $mappingByTarget[$view.TargetPath].Add($view) | Out-Null
    }

    $datasetNodes = [System.Collections.Generic.List[object]]::new()
    $datasetById = [ordered]@{}
    foreach ($datasetId in @($datasetMetadataMap.Keys | Sort-Object)) {
        $metadata = $datasetMetadataMap[$datasetId]
        $examplePath = Resolve-DatasetExamplePath -BundleRoot ([string]$resolvedBundle.bundleRoot) -TechId ([string]$Collection.TechId) -DatasetMetadata $metadata -DatasetId $datasetId -DatasetContext $datasetContext
        $exampleData = Read-DatasetExample -ExamplePath $examplePath
        $mappedEntries = @($mappingViews | Where-Object { $_.DatasetId -eq $datasetId })

        $node = [pscustomobject]@{
            DatasetId = $datasetId
            Scope = [string]$metadata.Scope
            PresentationKind = [string]$metadata.PresentationKind
            DefaultItemRoot = [string]$metadata.DefaultItemRoot
            PathTemplate = [string]$metadata.PathTemplate
            PreferredProjectionViews = @($metadata.PreferredProjectionViews)
            ExamplePath = $examplePath
            ExampleData = $exampleData
            HasExampleData = ($null -ne $exampleData)
            Mappings = $mappedEntries
            MappingCount = @($mappedEntries).Count
            Label = ("[{0}/{1}] {2}" -f ([string]$metadata.Scope), ([string]$metadata.PresentationKind), $datasetId)
        }
        $datasetNodes.Add($node) | Out-Null
        $datasetById[$datasetId] = $node
    }

    $knownTargetPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($tag in @($placementEvidence.placedTags + $placementEvidence.stageOnlyTags + $projectionSurface.AllRefs + ($mappingViews | ForEach-Object { $_.TargetPath }))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$tag) -and -not $knownTargetPaths.Contains([string]$tag)) {
            $knownTargetPaths.Add([string]$tag) | Out-Null
        }
    }

    $targetNodes = [System.Collections.Generic.List[object]]::new()
    $targetByPath = [ordered]@{}
    foreach ($targetPath in @($knownTargetPaths | Sort-Object -Unique)) {
        $mappedEntries = if (Test-MapHasKey -Map $mappingByTarget -Key $targetPath) { ConvertTo-ObjectArray -Value $mappingByTarget[$targetPath] } else { @() }
        $placementGroup = 'Placement unknown'
        if ($placementEvidence.stageOnlyTags -contains $targetPath) {
            $placementGroup = 'Available to stage'
        }
        elseif ($placementEvidence.placedTags -contains $targetPath) {
            $placementGroup = 'Placed in template'
        }
        elseif (@($mappedEntries).Count -gt 0) {
            $placementGroup = if ([bool]$placementEvidence.hasEvidence) { 'Mapped but not placed' } else { 'Placement unknown' }
        }
        elseif ([bool]$placementEvidence.hasEvidence) {
            $placementGroup = 'Available to stage'
        }

        $datasetMetadata = if (@($mappedEntries).Count -gt 0) { $mappedEntries[0].DatasetMetadata } else { $null }
        $typeLabel = if (@($mappedEntries).Count -gt 0) {
            [string]$mappedEntries[0].TypeLabel
        }
        else {
            Get-MappingTypeLabel -Entry $null -DatasetMetadata $datasetMetadata -ProjectionSurface $projectionSurface -TargetPath $targetPath
        }

        $targetNode = [pscustomobject]@{
                TargetPath = $targetPath
                PlacementGroup = $placementGroup
                IsPlaced = ($placementEvidence.placedTags -contains $targetPath)
                IsStageOnly = ($placementEvidence.stageOnlyTags -contains $targetPath)
                IsMapped = (@($mappedEntries).Count -gt 0)
                MappingCount = @($mappedEntries).Count
                Mappings = $mappedEntries
                TypeLabel = $typeLabel
                Label = ("[{0}] {1} [{2}]" -f $placementGroup, $targetPath, $typeLabel)
            }
        $targetNodes.Add($targetNode) | Out-Null
        $targetByPath[$targetPath] = $targetNode
    }

    $connectionRows = [System.Collections.Generic.List[object]]::new()
    foreach ($mappingView in @($mappingViews | Sort-Object @{ Expression = { [string]$_.TargetPath } }, @{ Expression = { [string]$_.DatasetId } }, @{ Expression = { [string]$_.PrimarySelector } })) {
        $datasetNode = if (Test-MapHasKey -Map $datasetById -Key ([string]$mappingView.DatasetId)) { $datasetById[[string]$mappingView.DatasetId] } else { $null }
        $targetNode = if (Test-MapHasKey -Map $targetByPath -Key ([string]$mappingView.TargetPath)) { $targetByPath[[string]$mappingView.TargetPath] } else { $null }
        $connectionRows.Add((New-ConnectionRowView -MappingView $mappingView -DatasetNode $datasetNode -TargetNode $targetNode)) | Out-Null
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($targetPath in @($mappingByTarget.Keys)) {
        $mappedEntries = ConvertTo-ObjectArray -Value $mappingByTarget[$targetPath]
        if (@($mappedEntries).Count -gt 1) {
            $warnings.Add("Duplicate mappings detected for target '$targetPath'. Saving a queued change for this target will replace all current duplicates.") | Out-Null
        }
    }
    if ($placementEvidence.missingTokenAudit) {
        $warnings.Add('Token-audit artifact was not found. Template placement coverage is partially inferred.') | Out-Null
    }
    if ($placementEvidence.missingHeadingMap) {
        $warnings.Add('Heading-tag map artifact was not found. Template placement coverage is partially inferred.') | Out-Null
    }
    foreach ($datasetNode in @($datasetNodes)) {
        if (-not [bool]$datasetNode.HasExampleData) {
            $warnings.Add("Example bundle data is missing for dataset '$($datasetNode.DatasetId)'. Live preview is unavailable for that dataset.") | Out-Null
        }
    }

    return [ordered]@{
        RepoRoot = $RepoRoot
        BundleRoot = [string]$resolvedBundle.bundleRoot
        ContractsRoot = $ContractsRoot
        Collection = $Collection
        MappingDocument = $mappingDoc
        TagPolicy = $tagPolicy
        SyncPolicy = $syncPolicy
        ProjectionSurface = $projectionSurface
        DatasetContext = $datasetContext
        PlacementEvidence = $placementEvidence
        Datasets = ConvertTo-ObjectArray -Value $datasetNodes
        DatasetById = $datasetById
        Targets = ConvertTo-ObjectArray -Value $targetNodes
        TargetByPath = $targetByPath
        KnownTargetPaths = @($knownTargetPaths | Sort-Object -Unique)
        MappingViews = ConvertTo-ObjectArray -Value $mappingViews
        ConnectionRows = ConvertTo-ObjectArray -Value $connectionRows
        Warnings = ConvertTo-ObjectArray -Value $warnings
    }
}

function Format-MappingStudioOverview {
    param(
        [Parameter(Mandatory = $true)]$Workbench,
        [Parameter(Mandatory = $false)][object[]]$PendingChanges = @()
    )

    $placedTargets = @($Workbench.Targets | Where-Object { $_.PlacementGroup -eq 'Placed in template' })
    $mappedPlacedTargets = @($placedTargets | Where-Object { $_.IsMapped })
    $unmappedPlacedTargets = @($placedTargets | Where-Object { -not $_.IsMapped })
    $stagedTargets = @($Workbench.Targets | Where-Object { $_.PlacementGroup -eq 'Available to stage' })
    $mappedNotPlaced = @($Workbench.Targets | Where-Object { $_.PlacementGroup -eq 'Mapped but not placed' })
    $placementUnknown = @($Workbench.Targets | Where-Object { $_.PlacementGroup -eq 'Placement unknown' })
    $datasetsWithMappings = @($Workbench.Datasets | Where-Object { $_.MappingCount -gt 0 })
    $datasetsWithoutMappings = @($Workbench.Datasets | Where-Object { $_.MappingCount -eq 0 })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Template collection: $($Workbench.Collection.DisplayName)")
    $lines.Add("Tech: $($Workbench.Collection.TechId)")
    $lines.Add("Mapping source: $($Workbench.MappingDocument.source)")
    $lines.Add("Bundle target: $($Workbench.DatasetContext.target) ($($Workbench.DatasetContext.selectionReason))")
    $lines.Add("System example: $($Workbench.DatasetContext.selectedSystem)")
    $lines.Add('')
    $lines.Add('Coverage')
    $lines.Add("  Mapped targets: $(@($Workbench.Targets | Where-Object { $_.IsMapped }).Count)")
    $lines.Add("  Unmapped placed targets: $(@($unmappedPlacedTargets).Count)")
    $lines.Add("  Staged targets: $(@($stagedTargets).Count)")
    $lines.Add("  Mapped but not placed: $(@($mappedNotPlaced).Count)")
    $lines.Add("  Placement unknown: $(@($placementUnknown).Count)")
    $lines.Add("  Datasets with mappings: $(@($datasetsWithMappings).Count)")
    $lines.Add("  Datasets without mappings: $(@($datasetsWithoutMappings).Count)")
    $lines.Add("  Pending changes: $(@($PendingChanges).Count)")

    if (@($Workbench.Warnings).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Warnings')
        foreach ($warning in @($Workbench.Warnings)) {
            $lines.Add("  - $warning")
        }
    }

    if ([bool]$Workbench.MappingDocument.readOnly) {
        $lines.Add('')
        $lines.Add('Read-only mode')
        $lines.Add("  $($Workbench.MappingDocument.readOnlyReason)")
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-MappingStudioPreview {
    param([Parameter(Mandatory = $true)]$Preview)

    $previewTable = ConvertTo-Dictionary -Value $Preview
    if ($null -eq $previewTable) {
        return 'Preview unavailable.'
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ((Test-MapHasKey -Map $previewTable -Key 'Status') -and [string]$previewTable.Status -ne 'ok') {
        $lines.Add([string](Get-MapValueOrDefault -Map $previewTable -Key 'Message'))
        return ($lines -join [Environment]::NewLine)
    }

    $lines.Add("RenderAs: $([string]$previewTable.RenderAs)")
    $lines.Add("Selector: $([string]$previewTable.Selector)")
    if ((Test-MapHasKey -Map $previewTable -Key 'ProjectionSummary') -and -not [string]::IsNullOrWhiteSpace([string]$previewTable.ProjectionSummary)) {
        $lines.Add("Projection: $([string]$previewTable.ProjectionSummary)")
    }
    if ((Test-MapHasKey -Map $previewTable -Key 'View') -and -not [string]::IsNullOrWhiteSpace([string]$previewTable.View)) {
        $lines.Add("View: $([string]$previewTable.View)")
    }
    if ((Test-MapHasKey -Map $previewTable -Key 'ExamplePath') -and -not [string]::IsNullOrWhiteSpace([string]$previewTable.ExamplePath)) {
        $lines.Add("Example: $([string]$previewTable.ExamplePath)")
    }

    if ([string]$previewTable.RenderAs -eq 'scalar') {
        $lines.Add('')
        $lines.Add('Sample value')
        $lines.Add("  $([string]$previewTable.SampleValue)")
        return ($lines -join [Environment]::NewLine)
    }

    $lines.Add("Rows: $([int]$previewTable.RowCount)")
    if (@($previewTable.FilterSummary).Count -gt 0) {
        $lines.Add("Filters: $((@($previewTable.FilterSummary)) -join '; ')")
    }
    if (@($previewTable.RowOrder).Count -gt 0) {
        $lines.Add("Sort: $((@($previewTable.RowOrder)) -join ', ')")
    }

    if (@($previewTable.ColumnNames).Count -gt 0) {
        $lines.Add("Columns: $((@($previewTable.ColumnNames)) -join ', ')")
    }

    if (@($previewTable.PreviewRows).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Preview rows')
        foreach ($row in @($previewTable.PreviewRows)) {
            $rowTable = ConvertTo-Dictionary -Value $row
            if ($null -eq $rowTable) { continue }
            $segments = @()
            foreach ($key in @($rowTable.Keys)) {
                $segments += ("{0}={1}" -f [string]$key, [string]$rowTable[$key])
            }
            $lines.Add("  - $($segments -join ' | ')")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-MappingStudioConnectionDetail {
    param([Parameter(Mandatory = $true)]$ConnectionRow)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Dataset: $([string]$ConnectionRow.DatasetId)")
    if (-not [string]::IsNullOrWhiteSpace([string]$ConnectionRow.DatasetScope)) {
        $lines.Add("Scope: $([string]$ConnectionRow.DatasetScope)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ConnectionRow.DatasetPresentationKind)) {
        $lines.Add("Presentation: $([string]$ConnectionRow.DatasetPresentationKind)")
    }
    $lines.Add("Target: $([string]$ConnectionRow.TargetPath)")
    $lines.Add("Placement: $([string]$ConnectionRow.PlacementGroup)")
    $lines.Add("Mapping type: $([string]$ConnectionRow.TypeLabel)")
    $lines.Add("Render shape: $([string]$ConnectionRow.RenderAs)")
    $lines.Add("Selector: $([string]$ConnectionRow.PrimarySelector)")
    if (-not [string]::IsNullOrWhiteSpace([string]$ConnectionRow.ProjectionRef)) {
        $lines.Add("Projection: $([string]$ConnectionRow.ProjectionRef)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ConnectionRow.View)) {
        $lines.Add("View: $([string]$ConnectionRow.View)")
    }
    $lines.Add("Required: $([bool]$ConnectionRow.Required)")
    $lines.Add("Example data: $(if ([bool]$ConnectionRow.HasExampleData) { 'available' } else { 'missing' })")
    if (-not [string]::IsNullOrWhiteSpace([string]$ConnectionRow.ExamplePath)) {
        $lines.Add("Example path: $([string]$ConnectionRow.ExamplePath)")
    }

    if ([bool]$ConnectionRow.DuplicateTargetMapping) {
        $lines.Add('')
        $lines.Add('Warning')
        $lines.Add("  Target '$([string]$ConnectionRow.TargetPath)' currently has $([int]$ConnectionRow.TargetMappingCount) active mappings. Saving a replacement will collapse duplicates to one active mapping.")
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-DatasetNodeDetail {
    param([Parameter(Mandatory = $true)]$DatasetNode)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Dataset: $($DatasetNode.DatasetId)")
    $lines.Add("Scope: $($DatasetNode.Scope)")
    $lines.Add("Presentation: $($DatasetNode.PresentationKind)")
    $lines.Add("Default item root: $($DatasetNode.DefaultItemRoot)")
    $lines.Add("Path template: $($DatasetNode.PathTemplate)")
    $lines.Add("Mappings: $($DatasetNode.MappingCount)")
    $lines.Add("Example data: $(if ($DatasetNode.HasExampleData) { 'available' } else { 'missing' })")
    if (-not [string]::IsNullOrWhiteSpace([string]$DatasetNode.ExamplePath)) {
        $lines.Add("Example path: $($DatasetNode.ExamplePath)")
    }

    if (@($DatasetNode.PreferredProjectionViews).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Preferred projections')
        foreach ($view in @($DatasetNode.PreferredProjectionViews)) {
            $lines.Add("  - $([string]$view.Name): $([string]$view.ProjectionRef)")
        }
    }

    if (@($DatasetNode.Mappings).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Current mappings')
        foreach ($mapping in @($DatasetNode.Mappings)) {
            $lines.Add("  - $($mapping.TargetPath) [$($mapping.RenderAs)]")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-TargetNodeDetail {
    param([Parameter(Mandatory = $true)]$TargetNode)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Target: $($TargetNode.TargetPath)")
    $lines.Add("Placement: $($TargetNode.PlacementGroup)")
    $lines.Add("Type: $($TargetNode.TypeLabel)")
    $lines.Add("Mapped: $($TargetNode.IsMapped)")
    $lines.Add("Mappings: $($TargetNode.MappingCount)")

    if (@($TargetNode.Mappings).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Current mappings')
        foreach ($mapping in @($TargetNode.Mappings)) {
            $lines.Add("  - $($mapping.DatasetId) [$($mapping.RenderAs)] selector=$($mapping.PrimarySelector)")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-PendingChangesDetail {
    param([Parameter(Mandatory = $false)][object[]]$PendingChanges = @())

    if (@($PendingChanges).Count -eq 0) {
        return 'No pending Mapping Studio changes queued.'
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Pending changes: $(@($PendingChanges).Count)")
    foreach ($change in @($PendingChanges)) {
        $lines.Add("  - $($change.DatasetId) -> $($change.TargetPath) [$($change.RenderAs)] selector=$($change.Selector)")
        if (-not [string]::IsNullOrWhiteSpace([string]$change.ProjectionRef)) {
            $lines.Add("    projection=$($change.ProjectionRef)")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Add-MappingStudioPendingChange {
    param(
        [Parameter(Mandatory = $true)]$Workbench,
        [Parameter(Mandatory = $false)][object[]]$PendingChanges = @(),
        [Parameter(Mandatory = $true)][string]$DatasetId,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$RenderAs,
        [Parameter(Mandatory = $false)][string]$Selector,
        [Parameter(Mandatory = $false)][string]$ProjectionRef,
        [Parameter(Mandatory = $false)][string]$View,
        [Parameter(Mandatory = $false)][bool]$Required = $false,
        [Parameter(Mandatory = $false)][string]$Notes = ''
    )

    if ($RenderAs -notin @('table', 'scalar')) {
        throw "Mapping Studio v1 supports only 'table' and 'scalar' renderAs values. Requested: $RenderAs"
    }
    if ($Workbench.KnownTargetPaths -notcontains $TargetPath) {
        throw "Target '$TargetPath' is not part of the selected template collection target inventory."
    }

    $datasetById = ConvertTo-Dictionary -Value $Workbench.DatasetById
    if ($null -eq $datasetById -or -not (Test-MapHasKey -Map $datasetById -Key $DatasetId)) {
        throw "Dataset '$DatasetId' is not available for tech '$($Workbench.Collection.TechId)'."
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectionRef)) {
        $projection = Get-ProjectionDefinitionForRef -ProjectionSurface $Workbench.ProjectionSurface -ProjectionRef $ProjectionRef
        if ($null -eq $projection) {
            throw "Projection '$ProjectionRef' is not defined in the current projection contract surface."
        }
    }

    $datasetNode = $datasetById[$DatasetId]
    $selectorToUse = if ([string]::IsNullOrWhiteSpace($Selector)) {
        Get-DefaultSelectorForRenderAs -RenderAs $RenderAs -DatasetNode $datasetNode -SyncPolicy $Workbench.SyncPolicy
    }
    else {
        $Selector
    }

    $nextChanges = [System.Collections.Generic.List[object]]::new()
    foreach ($change in @($PendingChanges)) {
        if ([string]$change.TargetPath -eq $TargetPath) {
            continue
        }
        $nextChanges.Add($change) | Out-Null
    }

    $nextChanges.Add([pscustomobject]@{
            DatasetId = $DatasetId
            TargetPath = $TargetPath
            RenderAs = $RenderAs
            Selector = $selectorToUse
            ProjectionRef = $ProjectionRef
            View = $View
            Required = $Required
            Notes = $Notes
            QueuedAt = (Get-Date).ToString('o')
            Label = ("{0} -> {1} [{2}]" -f $DatasetId, $TargetPath, $RenderAs)
        }) | Out-Null

    return (ConvertTo-ObjectArray -Value $nextChanges)
}

function New-ContractMappingEntryFromDraft {
    param(
        [Parameter(Mandatory = $true)]$Draft,
        [Parameter(Mandatory = $false)]$ExistingEntry
    )

    $draftTable = ConvertTo-Dictionary -Value $Draft
    $existing = ConvertTo-Dictionary -Value $ExistingEntry
    $mappingEntry = [ordered]@{
        phase = 'dual'
        dataset = [string]$draftTable.DatasetId
        sdtTag = [string]$draftTable.TargetPath
        target = [ordered]@{
            kind = 'sdt'
            path = [string]$draftTable.TargetPath
        }
        required = [bool](Get-MapValueOrDefault -Map $draftTable -Key 'Required' -DefaultValue $false)
    }

    $selector = [string](Get-MapValueOrDefault -Map $draftTable -Key 'Selector')
    if (-not [string]::IsNullOrWhiteSpace($selector)) {
        $mappingEntry.selectors = @($selector)
    }

    $notes = [string](Get-MapValueOrDefault -Map $draftTable -Key 'Notes')
    if ([string]::IsNullOrWhiteSpace($notes) -and $null -ne $existing) {
        $notes = [string](Get-MapValueOrDefault -Map $existing -Key 'notes')
    }
    if (-not [string]::IsNullOrWhiteSpace($notes)) {
        $mappingEntry.notes = $notes
    }

    $renderHint = [ordered]@{
        renderAs = [string]$draftTable.RenderAs
    }
    $projectionRef = [string](Get-MapValueOrDefault -Map $draftTable -Key 'ProjectionRef')
    $view = [string](Get-MapValueOrDefault -Map $draftTable -Key 'View')
    if (-not [string]::IsNullOrWhiteSpace($projectionRef)) {
        $renderHint.projectionRef = $projectionRef
    }
    if (-not [string]::IsNullOrWhiteSpace($view)) {
        $renderHint.view = $view
    }
    $mappingEntry.renderHint = $renderHint

    return $mappingEntry
}

function Apply-PendingMappingDrafts {
    param(
        [Parameter(Mandatory = $true)]$ContractDocument,
        [Parameter(Mandatory = $true)][object[]]$PendingChanges,
        [Parameter(Mandatory = $true)][hashtable]$TagPolicy
    )

    $doc = Copy-PlainValue -Value $ContractDocument
    $mappings = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($doc.mappings)) {
        $mappings.Add((Copy-PlainValue -Value $entry)) | Out-Null
    }

    foreach ($draft in @($PendingChanges)) {
        $matchedIndexes = [System.Collections.Generic.List[int]]::new()
        for ($index = 0; $index -lt $mappings.Count; $index++) {
            $resolvedTarget = Resolve-CollectorTargetTag -MappingEntry $mappings[$index] -TagPolicy $TagPolicy
            if ($resolvedTarget -eq [string]$draft.TargetPath) {
                $matchedIndexes.Add($index) | Out-Null
            }
        }

        $existingEntry = $null
        if ($matchedIndexes.Count -gt 0) {
            $existingEntry = $mappings[$matchedIndexes[0]]
            for ($removeIndex = $matchedIndexes.Count - 1; $removeIndex -ge 0; $removeIndex--) {
                $mappings.RemoveAt($matchedIndexes[$removeIndex])
            }
        }

        $newEntry = New-ContractMappingEntryFromDraft -Draft $draft -ExistingEntry $existingEntry
        $insertIndex = if ($matchedIndexes.Count -gt 0) { [Math]::Min($matchedIndexes[0], $mappings.Count) } else { $mappings.Count }
        $mappings.Insert($insertIndex, $newEntry)
    }

    $seenTargets = @{}
    foreach ($entry in @($mappings)) {
        $resolvedTarget = Resolve-CollectorTargetTag -MappingEntry $entry -TagPolicy $TagPolicy
        if ([string]::IsNullOrWhiteSpace($resolvedTarget)) {
            continue
        }
        if (Test-MapHasKey -Map $seenTargets -Key $resolvedTarget) {
            throw "Duplicate active mappings detected for target '$resolvedTarget' after applying pending changes."
        }
        $seenTargets[$resolvedTarget] = $true
    }

    $doc.mappings = ConvertTo-ObjectArray -Value $mappings
    return $doc
}

function Resolve-RuntimeDatasetPathFromMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $true)]$DatasetMetadata,
        [Parameter(Mandatory = $true)][string]$DatasetId
    )

    if ($null -eq $DatasetMetadata -or [string]::IsNullOrWhiteSpace([string]$DatasetMetadata.PathTemplate)) {
        throw "Dataset '$DatasetId' is missing datasetPath.template metadata."
    }

    $resolved = [string]$DatasetMetadata.PathTemplate
    $resolved = $resolved.Replace('__TECH_ID__', $TechId)
    $resolved = $resolved.Replace('__DATASET__', $DatasetId)
    return $resolved
}

function Write-RuntimeMappingFromContract {
    param(
        [Parameter(Mandatory = $true)]$ContractDocument,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ContractRelativePath,
        [Parameter(Mandatory = $true)][hashtable]$DatasetMetadataMap,
        [Parameter(Mandatory = $true)][hashtable]$TagPolicy,
        [Parameter(Mandatory = $true)][hashtable]$SyncPolicy,
        [Parameter(Mandatory = $false)][string]$DisplayName = ''
    )

    $generatedMappings = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($ContractDocument.mappings)) {
        $entryTable = ConvertTo-Dictionary -Value $entry
        if ($null -eq $entryTable) { continue }

        $datasetId = [string](Get-MapValueOrDefault -Map $entryTable -Key 'dataset')
        if ([string]::IsNullOrWhiteSpace($datasetId) -or -not (Test-MapHasKey -Map $DatasetMetadataMap -Key $datasetId)) {
            continue
        }

        $resolvedTargetTag = Resolve-CollectorTargetTag -MappingEntry $entryTable -TagPolicy $TagPolicy
        if ([string]::IsNullOrWhiteSpace($resolvedTargetTag)) {
            continue
        }

        $datasetMetadata = $DatasetMetadataMap[$datasetId]
        $runtimeEntry = [ordered]@{
            dataset = (Resolve-RuntimeDatasetPathFromMetadata -TechId $TechId -DatasetMetadata $datasetMetadata -DatasetId $datasetId)
            required = [bool](Get-MapValueOrDefault -Map $entryTable -Key 'required' -DefaultValue $false)
            sdtTag = $resolvedTargetTag
            target = [ordered]@{
                sdtTag = $resolvedTargetTag
            }
        }

        $hint = Get-EffectiveMappingRenderHint -Entry $entryTable -DatasetMetadata $datasetMetadata
        $renderAs = [string](Get-MapValueOrDefault -Map $hint -Key 'renderAs')
        if (-not [string]::IsNullOrWhiteSpace($renderAs)) {
            if ($renderAs -notin @($SyncPolicy.allowedRenderAs)) {
                continue
            }

            $selectors = @($entryTable.selectors | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if (@($selectors).Count -eq 0) {
                $selectors = @((Get-DefaultSelectorForRenderAs -RenderAs $renderAs -DatasetNode $datasetMetadata -SyncPolicy $SyncPolicy))
            }
            if (@($selectors).Count -gt 0) {
                $runtimeEntry.selectors = @($selectors)
            }

            $renderHint = [ordered]@{
                renderAs = $renderAs
            }
            foreach ($key in @('projectionRef', 'view', 'emptyBehavior')) {
                if ((Test-MapHasKey -Map $hint -Key $key) -and -not [string]::IsNullOrWhiteSpace([string]$hint[$key])) {
                    $renderHint[$key] = [string]$hint[$key]
                }
            }
            $runtimeEntry.renderHint = $renderHint
        }

        $generatedMappings.Add($runtimeEntry) | Out-Null
    }

    $runtimeDocument = [ordered]@{
        schema = 'mapping.dataset-to-sdt'
        schemaVersion = 1
        techId = $TechId
        displayName = if ([string]::IsNullOrWhiteSpace($DisplayName)) { "$TechId collector blueprint mapping" } else { $DisplayName }
        generatedFromContract = [ordered]@{
            path = $ContractRelativePath
        }
        mappings = ConvertTo-ObjectArray -Value $generatedMappings
    }

    Ensure-Directory -Path (Split-Path -Parent $OutputPath)
    $runtimeDocument | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    return $runtimeDocument
}

function Save-MappingStudioPendingChanges {
    param(
        [Parameter(Mandatory = $true)]$Workbench,
        [Parameter(Mandatory = $true)][object[]]$PendingChanges
    )

    if (@($PendingChanges).Count -eq 0) {
        throw 'No Mapping Studio changes are queued.'
    }
    if ([bool]$Workbench.MappingDocument.readOnly) {
        throw $Workbench.MappingDocument.readOnlyReason
    }

    $contractPath = [string]$Workbench.MappingDocument.contractPath
    $contractRelativePath = [string]$Workbench.MappingDocument.contractRelativePath
    $runtimePath = [string]$Workbench.MappingDocument.runtimePath
    $repoRoot = [string]$Workbench.RepoRoot
    $techId = [string]$Workbench.Collection.TechId
    $exportMirrorPath = Join-Path $repoRoot ("exports/LNV.AsBuiltDoc.Contracts/tech/{0}/mapping.dataset-to-sdt.v1.yaml" -f $techId)

    $contractDocument = Read-YamlFileSafe -Path $contractPath
    $updatedContract = Apply-PendingMappingDrafts -ContractDocument $contractDocument -PendingChanges $PendingChanges -TagPolicy $Workbench.TagPolicy
    Write-YamlFileSafe -Path $contractPath -Value $updatedContract
    Write-YamlFileSafe -Path $exportMirrorPath -Value $updatedContract
    $runtimeDocument = Write-RuntimeMappingFromContract -ContractDocument $updatedContract -TechId $techId -OutputPath $runtimePath -ContractRelativePath $contractRelativePath -DatasetMetadataMap $Workbench.DatasetById -TagPolicy $Workbench.TagPolicy -SyncPolicy $Workbench.SyncPolicy -DisplayName ([string]$Workbench.Collection.DisplayName)

    return [ordered]@{
        ContractPath = $contractPath
        ExportMirrorPath = $exportMirrorPath
        RuntimePath = $runtimePath
        SavedCount = @($PendingChanges).Count
        RuntimeMappingCount = @($runtimeDocument.mappings).Count
    }
}

Export-ModuleMember -Function `
    Get-MappingStudioYamlSupport, `
    Get-TemplateCollections, `
    Resolve-MappingStudioBundleRoot, `
    Resolve-MappingStudioTechDatasetContext, `
    Get-MappingStudioWorkbench, `
    Get-MappingStudioPreview, `
    Get-SelectorCandidatesForDataset, `
    Select-MappingStudioConnectionRows, `
    Format-MappingStudioOverview, `
    Format-MappingStudioPreview, `
    Format-MappingStudioConnectionDetail, `
    Format-DatasetNodeDetail, `
    Format-TargetNodeDetail, `
    Format-PendingChangesDetail, `
    Add-MappingStudioPendingChange, `
    Save-MappingStudioPendingChanges
