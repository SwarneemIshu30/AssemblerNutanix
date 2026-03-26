#!/usr/bin/env pwsh
<#
.SYNOPSIS
Bundle-aware render orchestrator that executes SDT render once per catalog mapping/template entry.
#>
param(
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $false)][string]$ContractsRoot,
    [Parameter(Mandatory = $false)][string[]]$TechId,
    [Parameter(Mandatory = $false)][string[]]$EntryId,
    [Parameter(Mandatory = $false)][ValidateSet('docx','text')][string[]]$OutputType,
    [Parameter(Mandatory = $false)][switch]$AnnotateResolvedTags
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

function Resolve-BundleRoot {
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
            objectIndexPath = $directCandidate.objectIndexPath
            autoSelected = $false
            candidateCount = 1
            selectionReason = 'direct'
        }
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $resolvedInput -Directory -ErrorAction Stop |
            ForEach-Object {
                $candidate = Test-BundleCandidate -Path $_.FullName
                if ($candidate.isValid) {
                    [pscustomobject]@{
                        bundleRoot = [string]$candidate.path
                        objectIndexPath = [string]$candidate.objectIndexPath
                        solutionPlanPath = [string]$candidate.solutionPlanPath
                    }
                }
            }
    )

    if (@($candidates).Count -eq 1) {
        $selected = $candidates[0]
        return [ordered]@{
            bundleRoot = [string]$selected.bundleRoot
            objectIndexPath = [string]$selected.objectIndexPath
            autoSelected = $true
            candidateCount = 1
            selectionReason = 'single-staged-child'
        }
    }

    if (@($candidates).Count -gt 1) {
        $candidateRoots = @($candidates | Sort-Object -Property bundleRoot | ForEach-Object { [string]$_.bundleRoot })
        throw "BundleRoot '$BundleRoot' resolves to a staging directory containing multiple bundle candidates. Provide a specific bundle directory (contains manifest.json, objectIndex.json, config/solution.plan.json). Candidates: $($candidateRoots -join ', ')"
    }

    throw "BundleRoot '$BundleRoot' does not resolve to a valid bundle directory. Expected manifest.json, objectIndex.json, and config/solution.plan.json at '$resolvedInput' or exactly one child bundle directory."
}

function Resolve-AssemblerContractsRoot {
    param(
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ContractsRoot)) {
        return (Resolve-Path -LiteralPath $ContractsRoot -ErrorAction Stop).Path
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


function Get-CollectorTargetRoots {
    param(
        [Parameter(Mandatory = $true)][string]$CollectorOutRoot
    )

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
                })
            }
            continue
        }

        foreach ($targetRoot in @(Get-ChildItem -LiteralPath $container.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'target_*' } | Sort-Object -Property Name)) {
            $targetRoots.Add([pscustomobject]@{
                ContainerName = [string]$container.Name
                ContainerPath = [string]$container.FullName
                Name = [string]$targetRoot.Name
                FullName = [string]$targetRoot.FullName
            })
        }
    }

    return @($targetRoots)
}

function Resolve-TechDatasetContext {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $false)][hashtable]$CatalogEntry
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

    # Deterministic precedence (never timestamp-based):
    # 1) Explicit catalog metadata key (targetKey, target, selectedTargetKey, targetSelector.key).
    # 2) First matching key from config/solution.plan.json collectors[].targetKeys for this TechId.
    # 3) Lexical Name order (stable fallback).
    $explicitTargetKeys = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $CatalogEntry) {
        foreach ($keyField in @('targetKey','target','selectedTargetKey')) {
            if ($CatalogEntry.ContainsKey($keyField) -and -not [string]::IsNullOrWhiteSpace([string]$CatalogEntry[$keyField])) {
                $explicitTargetKeys.Add(([string]$CatalogEntry[$keyField]).Trim())
            }
        }
        if ($CatalogEntry.ContainsKey('targetSelector') -and $null -ne $CatalogEntry.targetSelector) {
            $selector = $CatalogEntry.targetSelector
            if ($selector -is [hashtable] -and $selector.ContainsKey('key') -and -not [string]::IsNullOrWhiteSpace([string]$selector.key)) {
                $explicitTargetKeys.Add(([string]$selector.key).Trim())
            }
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
                        $solutionPlanTargetKeys.Add(([string]$targetKey).Trim())
                    }
                }
            }
        }
        catch {
            # Selection can still continue via explicit entry metadata or lexical fallback.
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

    return [ordered]@{
        target = [string]$selectedTarget.Name
        targetRoot = [string]$selectedTarget.FullName
        targetContainer = [string]$selectedTarget.ContainerName
        systems = $systems
        selectionReason = $selectionReason
        candidateTargets = @($targets | Sort-Object -Property @{ Expression = 'Name' }, @{ Expression = 'FullName' } | ForEach-Object { [string]$_.Name })
        candidateTargetRoots = @($targets | Sort-Object -Property @{ Expression = 'Name' }, @{ Expression = 'FullName' } | ForEach-Object { [string]$_.FullName })
    }
}

function Resolve-MappingVariantsForBundle {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$MappingPath,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string]$EntryId,
        [Parameter(Mandatory = $false)][hashtable]$CatalogEntry
    )

    $mappingText = Get-Content -LiteralPath $MappingPath -Raw -Encoding UTF8
    if (($mappingText -notmatch '__TARGET__') -and ($mappingText -notmatch '__SYSTEM__')) {
        return @([pscustomobject]@{ mappingPath = $MappingPath; variantName = $null; selectedTarget = $null; selectedTargetRoot = $null; targetSelectionReason = $null; targetCandidates = @(); targetCandidateRoots = @() })
    }

    $ctx = Resolve-TechDatasetContext -BundleRoot $BundleRoot -TechId $TechId -CatalogEntry $CatalogEntry
    $techDatasetRoot = Join-Path (Join-Path $BundleRoot 'datasets') $TechId
    $resolvedTargetPrefix = [System.IO.Path]::GetRelativePath($techDatasetRoot, [string]$ctx.targetRoot)
    $resolvedTargetPrefix = $resolvedTargetPrefix.Replace('\', '/')
    $targetResolved = $mappingText.Replace('__TARGET__', $resolvedTargetPrefix)

    $tempDir = Join-Path $OutputRoot '.resolved-mappings'
    Ensure-Directory -Path $tempDir

    if ($targetResolved -notmatch '__SYSTEM__') {
        $resolvedPath = Join-Path $tempDir ("$EntryId.target.$([string]$ctx.target).resolved.json")
        Set-Content -LiteralPath $resolvedPath -Value $targetResolved -Encoding UTF8
        return @([pscustomobject]@{ mappingPath = $resolvedPath; variantName = [string]$ctx.target; selectedTarget = [string]$ctx.target; selectedTargetRoot = [string]$ctx.targetRoot; targetSelectionReason = [string]$ctx.selectionReason; targetCandidates = @($ctx.candidateTargets); targetCandidateRoots = @($ctx.candidateTargetRoots) })
    }

    if (@($ctx.systems).Count -eq 0) {
        throw "Mapping '$MappingPath' requires __SYSTEM__ but no system_* directory found under target '$($ctx.target)'."
    }

    $variants = [System.Collections.Generic.List[psobject]]::new()
    foreach ($systemName in @($ctx.systems)) {
        $resolved = $targetResolved.Replace('__SYSTEM__', [string]$systemName)
        $safeSystem = ([string]$systemName).Replace('/', '_').Replace('\', '_')
        $resolvedPath = Join-Path $tempDir ("$EntryId.$safeSystem.resolved.json")
        Set-Content -LiteralPath $resolvedPath -Value $resolved -Encoding UTF8
        $variants.Add([pscustomobject]@{ mappingPath = $resolvedPath; variantName = [string]$systemName; selectedTarget = [string]$ctx.target; selectedTargetRoot = [string]$ctx.targetRoot; targetSelectionReason = [string]$ctx.selectionReason; targetCandidates = @($ctx.candidateTargets); targetCandidateRoots = @($ctx.candidateTargetRoots) })
    }

    return @($variants)
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-CatalogEntryOutputType {
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $templatePath = if ($Entry.ContainsKey('templatePath')) { [string]$Entry.templatePath } else { '' }
    $extension = [System.IO.Path]::GetExtension($templatePath)
    if ([string]::Equals($extension, '.docx', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'docx'
    }

    return 'text'
}

$startedUtc = Get-UtcTimestamp
$issues = [System.Collections.Generic.List[hashtable]]::new()
$runs = [System.Collections.Generic.List[hashtable]]::new()
$requestedTechIds = @()
$requestedEntryIds = @()
$requestedOutputTypes = @()

function Get-BundleEntryFailureMessage {
    param(
        [Parameter(Mandatory = $true)][string]$EntryId,
        [Parameter(Mandatory = $true)][string]$VariantName,
        [Parameter(Mandatory = $false)]$RendererReport,
        [Parameter(Mandatory = $false)][string]$RendererReportPath
    )

    $rendererIssues = @()
    if ($null -ne $RendererReport -and $RendererReport -is [System.Collections.IDictionary] -and $RendererReport.ContainsKey('issues')) {
        $rendererIssues = @($RendererReport.issues)
    }

    if (@($rendererIssues).Count -gt 0) {
        $errorCount = @($rendererIssues | Where-Object { [string]$_.severity -eq 'ERROR' }).Count
        $rootCauseCount = if ($errorCount -gt 0) { $errorCount } else { @($rendererIssues).Count }
        $rootCauseLabel = if ($errorCount -gt 0) { 'ERROR issue(s)' } else { 'issue(s)' }
        return "Entry '$EntryId' variant '$VariantName' failed render as a wrapper/aggregation error. Inspect nested renderer report '$RendererReportPath' and its issues array for the $rootCauseCount underlying renderer $rootCauseLabel."
    }

    if (-not [string]::IsNullOrWhiteSpace($RendererReportPath)) {
        return "Entry '$EntryId' variant '$VariantName' failed render as a wrapper/aggregation error. Inspect nested renderer report '$RendererReportPath' and its issues array for the underlying renderer failure details."
    }

    return "Entry '$EntryId' variant '$VariantName' failed render as a wrapper/aggregation error. Inspect the nested renderer report and its issues array for the underlying renderer failure details."
}
$stages = [System.Collections.Generic.List[hashtable]]::new()
$status = 'OK'
$effectiveBundleRoot = $BundleRoot

$stageMap = [ordered]@{}
foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
    $stage = [ordered]@{ name = $stageName; status = 'SKIPPED'; startedUtc = $null; completedUtc = $null; details = $null }
    $stageMap[$stageName] = $stage
    $stages.Add($stage)
}

function Start-BundleStage {
    param([Parameter(Mandatory = $true)][hashtable]$Stage)
    $Stage.startedUtc = Get-UtcTimestamp
    $Stage.completedUtc = $null
    $Stage.status = 'OK'
}

function Complete-BundleStage {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][hashtable]$Details
    )
    $Stage.status = $Status
    $Stage.completedUtc = Get-UtcTimestamp
    if ($PSBoundParameters.ContainsKey('Details')) { $Stage.details = $Details }
}

function Add-BundleSchemaIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$PathValue
    )

    $issues.Add([ordered]@{ code = $Code; severity = 'ERROR'; message = $Message; path = $PathValue })
}

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $invokeRenderScript = Join-Path $PSScriptRoot 'Invoke-AssemblerSdtRender.ps1'

    Start-BundleStage -Stage $stageMap.Load
    $effectiveContractsRoot = Resolve-AssemblerContractsRoot -ContractsRoot $ContractsRoot -RepoRoot $repoRoot
    $catalogSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.template-catalog.schema.v1.json'
    $aggregateReportSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.bundle-render-report.schema.v1.json'

    $catalog = Read-JsonFile -Path $CatalogPath

    $bundleResolution = Resolve-BundleRoot -BundleRoot $BundleRoot
    $effectiveBundleRoot = [string]$bundleResolution.bundleRoot
    $objectIndex = Read-JsonFile -Path ([string]$bundleResolution.objectIndexPath)
    if ($bundleResolution.autoSelected) {
        $issues.Add([ordered]@{
            code = 'ASB-ASM-BUNDLE-AUTOSELECTED'
            severity = 'WARN'
            message = "BundleRoot '$BundleRoot' was treated as staging input and auto-selected child bundle '$effectiveBundleRoot' (single valid candidate with manifest.json, objectIndex.json, config/solution.plan.json)."
            path = [string]$bundleResolution.objectIndexPath
        })
    }
    Complete-BundleStage -Stage $stageMap.Load -Status $(if ($bundleResolution.autoSelected) { 'WARN' } else { 'OK' })

    Start-BundleStage -Stage $stageMap.Validate
    $catalogValidation = Test-AssemblerSchemaFile -DocumentPath $CatalogPath -SchemaPath $catalogSchemaPath
    if (-not $catalogValidation.isValid) {
        Add-BundleSchemaIssue -Code 'ASB-ASM-SCHEMA-CATALOG-INVALID' -Message ([string]$catalogValidation.message) -PathValue $CatalogPath
        Complete-BundleStage -Stage $stageMap.Validate -Status 'ERROR'
        throw 'Template catalog schema validation failed.'
    }
    Complete-BundleStage -Stage $stageMap.Validate -Status 'OK'

    Start-BundleStage -Stage $stageMap.Transform
    $detectedTechIds = @($objectIndex.objects | ForEach-Object { [string]$_.techId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $requestedTechIds = if ($TechId -and @($TechId).Count -gt 0) { @($TechId) } else { $detectedTechIds }

    Ensure-Directory -Path $OutputRoot

    $catalogBase = Split-Path -Parent (Resolve-Path -LiteralPath $CatalogPath).Path
    $entries = @($catalog.entries | Where-Object { ($_.enabled -ne $false) -and ($requestedTechIds -contains [string]$_.techId) })
    $requestedEntryIds = @($EntryId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($requestedEntryIds.Count -gt 0) {
        $requestedEntryIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($requestedEntryId in $requestedEntryIds) {
            [void]$requestedEntryIdSet.Add(([string]$requestedEntryId).Trim())
        }
        $entries = @($entries | Where-Object { $requestedEntryIdSet.Contains([string]$_.id) })
    }

    $requestedOutputTypes = @($OutputType | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($requestedOutputTypes.Count -gt 0) {
        $requestedOutputTypeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($requestedOutputType in $requestedOutputTypes) {
            [void]$requestedOutputTypeSet.Add(([string]$requestedOutputType).Trim())
        }
        $entries = @($entries | Where-Object { $requestedOutputTypeSet.Contains((Get-CatalogEntryOutputType -Entry $_)) })
    }

    $entries = @($entries | Sort-Object -Property @{ Expression = { if ($_.ContainsKey('priority')) { [int]$_.priority } else { 100 } } }, @{ Expression = { [string]$_.id } })
    if (@($entries).Count -eq 0) {
        $issues.Add([ordered]@{
            code = 'ASB-ASM-BUNDLE-FILTERS-NO-ENTRIES'
            severity = 'WARN'
            message = "No catalog entries selected for rendering after applying enabled/tech and optional filters (TechId='$($requestedTechIds -join ',')'; EntryId='$($requestedEntryIds -join ',')'; OutputType='$($requestedOutputTypes -join ',')')."
            path = $CatalogPath
        })
    }
    Complete-BundleStage -Stage $stageMap.Transform -Status 'OK' -Details ([ordered]@{ selectedEntryCount = @($entries).Count })

    Start-BundleStage -Stage $stageMap.Render
    foreach ($entry in $entries) {
        $runStages = [System.Collections.Generic.List[hashtable]]::new()
        $runStageMap = [ordered]@{}
        foreach ($runStageName in @('Load','Validate','Transform','Render','Finalize')) {
            $runStage = [ordered]@{ name = $runStageName; status = 'SKIPPED'; startedUtc = $null; completedUtc = $null; details = $null }
            $runStageMap[$runStageName] = $runStage
            $runStages.Add($runStage)
        }

        $techOutputRoot = Join-Path $OutputRoot ([string]$entry.techId)
        if (-not (Test-Path -LiteralPath $techOutputRoot -PathType Container)) {
            New-Item -Path $techOutputRoot -ItemType Directory -Force | Out-Null
        }

        $mappingPath = Join-Path $catalogBase ([string]$entry.mappingPath)
        $templatePath = Join-Path $catalogBase ([string]$entry.templatePath)
        $outputPath = Join-Path $techOutputRoot ([string]$entry.outputFileName)
        $reportPath = Join-Path $techOutputRoot ("$([string]$entry.id).render-report.json")

        $variantReports = [System.Collections.Generic.List[hashtable]]::new()
        $sectionTexts = [System.Collections.Generic.List[string]]::new()
        $runStatus = 'OK'

        try {
            Start-BundleStage -Stage $runStageMap.Load
            Complete-BundleStage -Stage $runStageMap.Load -Status 'OK' -Details ([ordered]@{ mappingPath = $mappingPath; templatePath = $templatePath })

            Start-BundleStage -Stage $runStageMap.Validate
            if (-not (Test-Path -LiteralPath $mappingPath -PathType Leaf)) { throw "Required file not found: $mappingPath" }
            if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Required file not found: $templatePath" }
            Complete-BundleStage -Stage $runStageMap.Validate -Status 'OK'

            Start-BundleStage -Stage $runStageMap.Transform
            $mappingVariants = Resolve-MappingVariantsForBundle -BundleRoot $effectiveBundleRoot -MappingPath $mappingPath -TechId ([string]$entry.techId) -OutputRoot $OutputRoot -EntryId ([string]$entry.id) -CatalogEntry $entry
            $selectionReason = if (@($mappingVariants).Count -gt 0) { [string]$mappingVariants[0].targetSelectionReason } else { $null }
            $selectedTarget = if (@($mappingVariants).Count -gt 0) { [string]$mappingVariants[0].selectedTarget } else { $null }
            $selectedTargetRoot = if (@($mappingVariants).Count -gt 0) { [string]$mappingVariants[0].selectedTargetRoot } else { $null }
            if ($selectionReason -eq 'lexical-fallback') {
                $issues.Add([ordered]@{
                    code = 'ASB-ASM-TARGET-AUTOSELECTED'
                    severity = 'WARN'
                    message = "Entry '$($entry.id)' selected target '$selectedTarget' via lexical fallback. Configure catalog target metadata or solution.plan targetKeys to avoid fallback."
                    path = if ([string]::IsNullOrWhiteSpace($selectedTargetRoot)) { Join-Path (Join-Path (Join-Path $effectiveBundleRoot 'datasets') ([string]$entry.techId)) 'collector-out' } else { $selectedTargetRoot }
                })
            }
            Complete-BundleStage -Stage $runStageMap.Transform -Status 'OK' -Details ([ordered]@{ variantCount = @($mappingVariants).Count; selectedTarget = $selectedTarget; selectedTargetRoot = $selectedTargetRoot; targetSelectionReason = $selectionReason })

            Start-BundleStage -Stage $runStageMap.Render
            foreach ($variant in @($mappingVariants)) {
                $variantName = if ([string]::IsNullOrWhiteSpace([string]$variant.variantName)) { 'default' } else { [string]$variant.variantName }
                $variantSafe = $variantName.Replace('/', '_').Replace('\', '_')
                $variantOutputPath = if (@($mappingVariants).Count -gt 1) { Join-Path $techOutputRoot ("$([System.IO.Path]::GetFileNameWithoutExtension([string]$entry.outputFileName)).$variantSafe.rendered.txt") } else { $outputPath }
                $variantReportPath = if (@($mappingVariants).Count -gt 1) { Join-Path $techOutputRoot ("$([string]$entry.id).$variantSafe.render-report.json") } else { $reportPath }

                $renderParams = @{
                    BundleRoot = $effectiveBundleRoot
                    MappingPath = [string]$variant.mappingPath
                    TemplatePath = $templatePath
                    OutputPath = $variantOutputPath
                    ReportPath = $variantReportPath
                    ContractsRoot = $effectiveContractsRoot
                }
                if ($AnnotateResolvedTags.IsPresent) {
                    $renderParams.AnnotateResolvedTags = $true
                }
                $json = & $invokeRenderScript @renderParams

                $rendererReport = $null
                $variantStatus = 'OK'
                try {
                    $rendererReport = $json | ConvertFrom-Json -AsHashtable
                    if ($rendererReport.ContainsKey('status') -and [string]$rendererReport.status -eq 'ERROR') {
                        $variantStatus = 'ERROR'
                    }
                    elseif ($rendererReport.ContainsKey('status') -and [string]$rendererReport.status -eq 'PARTIAL') {
                        $variantStatus = 'WARN'
                    }
                }
                catch {
                    $variantStatus = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'ERROR' }
                }

                if ($variantStatus -eq 'ERROR') {
                    $runStatus = 'ERROR'
                    $status = 'ERROR'
                    $issues.Add([ordered]@{ code = 'ASB-ASM-BUNDLE-ENTRY-FAILED'; severity = 'ERROR'; message = (Get-BundleEntryFailureMessage -EntryId ([string]$entry.id) -VariantName $variantName -RendererReport $rendererReport -RendererReportPath $variantReportPath); path = $variantReportPath })
                }
                elseif ($variantStatus -eq 'WARN' -and $runStatus -ne 'ERROR') {
                    $runStatus = 'WARN'
                }

                if (Test-Path -LiteralPath $variantOutputPath -PathType Leaf) {
                    $sectionTexts.Add((Get-Content -LiteralPath $variantOutputPath -Raw -Encoding UTF8).TrimEnd())
                }

                $variantReports.Add([ordered]@{
                    variant = $variantName
                    status = $variantStatus
                    outputPath = $variantOutputPath
                    reportPath = $variantReportPath
                    rendererOutput = $rendererReport
                    rendererOutputRaw = $json
                    selectedTarget = [string]$variant.selectedTarget
                    targetSelectionReason = [string]$variant.targetSelectionReason
                    selectedTargetRoot = [string]$variant.selectedTargetRoot
                    targetCandidates = @($variant.targetCandidates)
                    targetCandidateRoots = @($variant.targetCandidateRoots)
                })
            }
            Complete-BundleStage -Stage $runStageMap.Render -Status $runStatus

            Start-BundleStage -Stage $runStageMap.Finalize
            if (@($mappingVariants).Count -gt 1 -and $sectionTexts.Count -gt 0) {
                Set-Content -LiteralPath $outputPath -Value (($sectionTexts -join ([Environment]::NewLine + [Environment]::NewLine)) + [Environment]::NewLine) -Encoding UTF8
            }
            Complete-BundleStage -Stage $runStageMap.Finalize -Status $runStatus
        }
        catch {
            $runStatus = 'ERROR'
            $status = 'ERROR'
            $issues.Add([ordered]@{ code = 'ASB-ASM-BUNDLE-ENTRY-UNHANDLED'; severity = 'ERROR'; message = "Entry '$($entry.id)' failed: $($_.Exception.Message)"; path = $null })
            foreach ($runStageName in @('Load','Validate','Transform','Render','Finalize')) {
                $runStage = $runStageMap[$runStageName]
                if ($null -ne $runStage.startedUtc -and $null -eq $runStage.completedUtc) {
                    Complete-BundleStage -Stage $runStage -Status 'ERROR'
                    break
                }
            }
        }

        $primaryVariant = if ($variantReports.Count -gt 0) { $variantReports[0] } else { $null }
        $runs.Add([ordered]@{
            entryId = [string]$entry.id
            techId = [string]$entry.techId
            status = $runStatus
            outputPath = $outputPath
            reportPath = $reportPath
            rendererOutput = if ($null -ne $primaryVariant) { $primaryVariant.rendererOutput } else { $null }
            rendererOutputRaw = if ($null -ne $primaryVariant) { $primaryVariant.rendererOutputRaw } else { $null }
            variants = $variantReports
            stages = $runStages
        })
    }

    $renderWarn = @($runs | Where-Object { $_.status -eq 'WARN' }).Count -gt 0
    $renderStatus = if ($status -eq 'ERROR') { 'ERROR' } elseif ($renderWarn) { 'WARN' } else { 'OK' }
    Complete-BundleStage -Stage $stageMap.Render -Status $renderStatus -Details ([ordered]@{ runCount = $runs.Count })

    Start-BundleStage -Stage $stageMap.Finalize
    Complete-BundleStage -Stage $stageMap.Finalize -Status $(if ($status -eq 'ERROR') { 'ERROR' } else { 'OK' })
}
catch {
    $status = 'ERROR'
    $issues.Add([ordered]@{ code = 'ASB-ASM-BUNDLE-UNHANDLED'; severity = 'ERROR'; message = $_.Exception.Message; path = $null })
    foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
        $stage = $stageMap[$stageName]
        if ($null -ne $stage.startedUtc -and $null -eq $stage.completedUtc) {
            Complete-BundleStage -Stage $stage -Status 'ERROR'
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
    bundleRoot = $effectiveBundleRoot
    catalogPath = $CatalogPath
    outputRoot = $OutputRoot
    filters = [ordered]@{
        techId = @($requestedTechIds)
        entryId = @($requestedEntryIds)
        outputType = @($requestedOutputTypes)
    }
    stages = $stages
    runs = $runs
    issues = $issues
}

$reportJson = $report | ConvertTo-Json -Depth 12
$aggregateReportValidation = Test-AssemblerSchemaJson -JsonText $reportJson -SchemaPath $aggregateReportSchemaPath -DocumentLabel 'assembler-bundle-render-report'
if (-not $aggregateReportValidation.isValid) {
    Add-BundleSchemaIssue -Code 'ASB-ASM-SCHEMA-AGGREGATEREPORT-INVALID' -Message ([string]$aggregateReportValidation.message) -PathValue (Join-Path $OutputRoot 'assembler-bundle-render-report.json')
    $status = 'ERROR'
    $report.status = $status
    $report.issues = $issues
    if ($null -ne $stageMap.Finalize.startedUtc) {
        $stageMap.Finalize.status = 'ERROR'
    }
    $report.completedUtc = Get-UtcTimestamp
    $reportJson = $report | ConvertTo-Json -Depth 12
}
Ensure-Directory -Path $OutputRoot
$bundleReportPath = Join-Path $OutputRoot 'assembler-bundle-render-report.json'
Set-Content -LiteralPath $bundleReportPath -Value $reportJson -Encoding UTF8

$reportJson
if ($status -eq 'ERROR') {
    exit 1
}
