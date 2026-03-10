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
    [Parameter(Mandatory = $false)][string[]]$TechId
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

function Resolve-BundleRoot {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)

    $resolvedInput = (Resolve-Path -LiteralPath $BundleRoot -ErrorAction Stop).Path
    $directObjectIndex = Join-Path $resolvedInput 'objectIndex.json'
    if (Test-Path -LiteralPath $directObjectIndex -PathType Leaf) {
        return [ordered]@{
            bundleRoot = $resolvedInput
            objectIndexPath = $directObjectIndex
            autoSelected = $false
            candidateCount = 0
        }
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $resolvedInput -Directory -ErrorAction Stop |
            ForEach-Object {
                $candidateObjectIndex = Join-Path $_.FullName 'objectIndex.json'
                if (Test-Path -LiteralPath $candidateObjectIndex -PathType Leaf) {
                    [pscustomobject]@{
                        bundleRoot = $_.FullName
                        objectIndexPath = $candidateObjectIndex
                        objectIndexWriteTimeUtc = (Get-Item -LiteralPath $candidateObjectIndex).LastWriteTimeUtc
                    }
                }
            }
    )

    if (@($candidates).Count -eq 0) {
        throw "Required file not found: $directObjectIndex"
    }

    $selected = $candidates |
        Sort-Object -Property @{ Expression = { $_.objectIndexWriteTimeUtc }; Descending = $true }, @{ Expression = { $_.bundleRoot }; Descending = $false } |
        Select-Object -First 1

    return [ordered]@{
        bundleRoot = [string]$selected.bundleRoot
        objectIndexPath = [string]$selected.objectIndexPath
        autoSelected = $true
        candidateCount = @($candidates).Count
    }
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



function Resolve-TechDatasetContext {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $multiRoot = Join-Path (Join-Path (Join-Path $BundleRoot 'datasets') $TechId) 'collector-out/_multi'
    if (-not (Test-Path -LiteralPath $multiRoot -PathType Container)) {
        throw "Expected collector dataset root not found: $multiRoot"
    }

    $targets = @(
        Get-ChildItem -LiteralPath $multiRoot -Directory -ErrorAction Stop |
            Where-Object { $_.Name -like 'target_*' } |
            ForEach-Object {
                $summary = Join-Path $_.FullName 'run_summary.json'
                [pscustomobject]@{
                    Name = $_.Name
                    FullName = $_.FullName
                    Rank = if (Test-Path -LiteralPath $summary -PathType Leaf) { (Get-Item -LiteralPath $summary).LastWriteTimeUtc.Ticks } else { 0 }
                }
            }
    )
    if (@($targets).Count -eq 0) {
        throw "No target_* folders found in: $multiRoot"
    }

    $target = $targets | Sort-Object -Property @{Expression={$_.Rank};Descending=$true}, @{Expression={$_.Name}} | Select-Object -First 1

    $systems = @(
        Get-ChildItem -LiteralPath $target.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'system_*' } |
            Sort-Object -Property Name |
            ForEach-Object { [string]$_.Name }
    )

    return [ordered]@{ target = [string]$target.Name; systems = $systems }
}

function Resolve-MappingPathForBundle {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$MappingPath,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $false)][string]$EntryId
    )

    $effectiveEntryId = if ([string]::IsNullOrWhiteSpace($EntryId)) {
        [System.IO.Path]::GetFileNameWithoutExtension($MappingPath)
    }
    else {
        $EntryId
    }

    $variants = Resolve-MappingVariantsForBundle -BundleRoot $BundleRoot -MappingPath $MappingPath -TechId $TechId -OutputRoot $OutputRoot -EntryId $effectiveEntryId
    if (@($variants).Count -lt 1) {
        throw "Failed to resolve mapping variants for '$MappingPath'."
    }

    return [string]$variants[0].mappingPath
}

function Resolve-MappingVariantsForBundle {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$MappingPath,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string]$EntryId
    )

    $mappingText = Get-Content -LiteralPath $MappingPath -Raw -Encoding UTF8
    if (($mappingText -notmatch '__TARGET__') -and ($mappingText -notmatch '__SYSTEM__')) {
        return @([pscustomobject]@{ mappingPath = $MappingPath; variantName = $null })
    }

    $ctx = Resolve-TechDatasetContext -BundleRoot $BundleRoot -TechId $TechId
    $targetResolved = $mappingText.Replace('__TARGET__', [string]$ctx.target)

    $tempDir = Join-Path $OutputRoot '.resolved-mappings'
    Ensure-Directory -Path $tempDir

    if ($targetResolved -notmatch '__SYSTEM__') {
        $resolvedPath = Join-Path $tempDir ("$EntryId.target.$([string]$ctx.target).resolved.json")
        Set-Content -LiteralPath $resolvedPath -Value $targetResolved -Encoding UTF8
        return @([pscustomobject]@{ mappingPath = $resolvedPath; variantName = [string]$ctx.target })
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
        $variants.Add([pscustomobject]@{ mappingPath = $resolvedPath; variantName = [string]$systemName })
    }

    return @($variants)
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-TemplateCatalogMinimumContract {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Catalog,
        [Parameter(Mandatory = $true)][hashtable]$Schema
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($requiredKey in ($Schema.required ?? @())) {
        if (-not $Catalog.ContainsKey([string]$requiredKey)) {
            $errors.Add("ASB-ASM-CATALOG-REQUIRED: missing required property '$requiredKey'")
        }
    }

    if ($Catalog.ContainsKey('schema') -and $Catalog.schema -ne 'assembler.template-catalog') {
        $errors.Add("ASB-ASM-CATALOG-CONST: schema must be 'assembler.template-catalog'")
    }
    if ($Catalog.ContainsKey('schemaVersion') -and [int]$Catalog.schemaVersion -ne 1) {
        $errors.Add("ASB-ASM-CATALOG-CONST: schemaVersion must be 1")
    }

    if (-not $Catalog.ContainsKey('entries') -or -not ($Catalog.entries -is [System.Collections.IList])) {
        $errors.Add("ASB-ASM-CATALOG-TYPE: 'entries' must be an array")
        return @($errors.ToArray())
    }

    if (@($Catalog.entries).Count -lt 1) {
        $errors.Add("ASB-ASM-CATALOG-MINITEMS: entries must contain at least one item")
    }

    foreach ($entry in @($Catalog.entries)) {
        foreach ($field in @('id', 'techId', 'mappingPath', 'templatePath', 'outputFileName')) {
            if (-not $entry.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$entry[$field])) {
                $errors.Add("ASB-ASM-CATALOG-ENTRY-REQUIRED: catalog entry requires non-empty '$field'")
            }
        }
    }

    return @($errors.ToArray())
}

$startedUtc = Get-UtcTimestamp
$issues = [System.Collections.Generic.List[hashtable]]::new()
$runs = [System.Collections.Generic.List[hashtable]]::new()
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

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $invokeRenderScript = Join-Path $PSScriptRoot 'Invoke-AssemblerSdtRender.ps1'

    Start-BundleStage -Stage $stageMap.Load
    $effectiveContractsRoot = Resolve-AssemblerContractsRoot -ContractsRoot $ContractsRoot -RepoRoot $repoRoot
    $catalogSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.template-catalog.schema.v1.json'

    $catalog = Read-JsonFile -Path $CatalogPath
    $catalogSchema = Read-JsonFile -Path $catalogSchemaPath

    $bundleResolution = Resolve-BundleRoot -BundleRoot $BundleRoot
    $effectiveBundleRoot = [string]$bundleResolution.bundleRoot
    $objectIndex = Read-JsonFile -Path ([string]$bundleResolution.objectIndexPath)
    if ($bundleResolution.autoSelected) {
        $issues.Add([ordered]@{
            code = 'ASB-ASM-BUNDLE-AUTOSELECTED'
            severity = 'WARN'
            message = "BundleRoot '$BundleRoot' did not contain objectIndex.json. Auto-selected '$effectiveBundleRoot' from $($bundleResolution.candidateCount) child bundle directories."
            path = [string]$bundleResolution.objectIndexPath
        })
    }
    Complete-BundleStage -Stage $stageMap.Load -Status $(if ($bundleResolution.autoSelected) { 'WARN' } else { 'OK' })

    Start-BundleStage -Stage $stageMap.Validate
    $catalogErrors = @(Test-TemplateCatalogMinimumContract -Catalog $catalog -Schema $catalogSchema)
    foreach ($errorText in $catalogErrors) {
        $issues.Add([ordered]@{ code = 'ASB-ASM-CATALOG-VALIDATE'; severity = 'ERROR'; message = $errorText; path = $CatalogPath })
    }
    if (@($catalogErrors).Count -gt 0) {
        Complete-BundleStage -Stage $stageMap.Validate -Status 'ERROR'
        throw 'Template catalog validation failed.'
    }
    Complete-BundleStage -Stage $stageMap.Validate -Status 'OK'

    Start-BundleStage -Stage $stageMap.Transform
    $detectedTechIds = @($objectIndex.objects | ForEach-Object { [string]$_.techId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $requestedTechIds = if ($TechId -and @($TechId).Count -gt 0) { @($TechId) } else { $detectedTechIds }

    Ensure-Directory -Path $OutputRoot

    $catalogBase = Split-Path -Parent (Resolve-Path -LiteralPath $CatalogPath).Path
    $entries = @($catalog.entries | Where-Object { ($_.enabled -ne $false) -and ($requestedTechIds -contains [string]$_.techId) })
    $entries = @($entries | Sort-Object -Property @{ Expression = { if ($_.ContainsKey('priority')) { [int]$_.priority } else { 100 } } }, @{ Expression = { [string]$_.id } })
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
            $mappingPath = Resolve-MappingPathForBundle -BundleRoot $effectiveBundleRoot -MappingPath $mappingPath -TechId ([string]$entry.techId) -OutputRoot $OutputRoot
            $mappingVariants = Resolve-MappingVariantsForBundle -BundleRoot $effectiveBundleRoot -MappingPath $mappingPath -TechId ([string]$entry.techId) -OutputRoot $OutputRoot -EntryId ([string]$entry.id)
            Complete-BundleStage -Stage $runStageMap.Transform -Status 'OK' -Details ([ordered]@{ variantCount = @($mappingVariants).Count })

            Start-BundleStage -Stage $runStageMap.Render
            foreach ($variant in @($mappingVariants)) {
                $variantName = if ([string]::IsNullOrWhiteSpace([string]$variant.variantName)) { 'default' } else { [string]$variant.variantName }
                $variantSafe = $variantName.Replace('/', '_').Replace('\', '_')
                $variantOutputPath = if (@($mappingVariants).Count -gt 1) { Join-Path $techOutputRoot ("$([System.IO.Path]::GetFileNameWithoutExtension([string]$entry.outputFileName)).$variantSafe.rendered.txt") } else { $outputPath }
                $variantReportPath = if (@($mappingVariants).Count -gt 1) { Join-Path $techOutputRoot ("$([string]$entry.id).$variantSafe.render-report.json") } else { $reportPath }

                $json = & $invokeRenderScript -BundleRoot $effectiveBundleRoot -MappingPath ([string]$variant.mappingPath) -TemplatePath $templatePath -OutputPath $variantOutputPath -ReportPath $variantReportPath -ContractsRoot $effectiveContractsRoot

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
                    $issues.Add([ordered]@{ code = 'ASB-ASM-BUNDLE-ENTRY-FAILED'; severity = 'ERROR'; message = "Entry '$($entry.id)' variant '$variantName' failed render."; path = $variantReportPath })
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
    stages = $stages
    runs = $runs
    issues = $issues
}

$reportJson = $report | ConvertTo-Json -Depth 12
Ensure-Directory -Path $OutputRoot
$bundleReportPath = Join-Path $OutputRoot 'assembler-bundle-render-report.json'
Set-Content -LiteralPath $bundleReportPath -Value $reportJson -Encoding UTF8

$reportJson
if ($status -eq 'ERROR') {
    exit 1
}
