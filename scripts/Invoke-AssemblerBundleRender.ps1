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
$status = 'OK'
$effectiveBundleRoot = $BundleRoot

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $invokeRenderScript = Join-Path $PSScriptRoot 'Invoke-AssemblerSdtRender.ps1'

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

    $catalogErrors = @(Test-TemplateCatalogMinimumContract -Catalog $catalog -Schema $catalogSchema)
    foreach ($errorText in $catalogErrors) {
        $issues.Add([ordered]@{ code = 'ASB-ASM-CATALOG-VALIDATE'; severity = 'ERROR'; message = $errorText; path = $CatalogPath })
    }
    if (@($catalogErrors).Count -gt 0) {
        throw 'Template catalog validation failed.'
    }

    $detectedTechIds = @($objectIndex.objects | ForEach-Object { [string]$_.techId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $requestedTechIds = if ($TechId -and @($TechId).Count -gt 0) { @($TechId) } else { $detectedTechIds }

    Ensure-Directory -Path $OutputRoot

    $catalogBase = Split-Path -Parent (Resolve-Path -LiteralPath $CatalogPath).Path
    $entries = @($catalog.entries | Where-Object { ($_.enabled -ne $false) -and ($requestedTechIds -contains [string]$_.techId) })
    $entries = @($entries | Sort-Object -Property @{ Expression = { if ($_.ContainsKey('priority')) { [int]$_.priority } else { 100 } } }, @{ Expression = { [string]$_.id } })

    foreach ($entry in $entries) {
        $techOutputRoot = Join-Path $OutputRoot ([string]$entry.techId)
        if (-not (Test-Path -LiteralPath $techOutputRoot -PathType Container)) {
            New-Item -Path $techOutputRoot -ItemType Directory -Force | Out-Null
        }

        $mappingPath = Join-Path $catalogBase ([string]$entry.mappingPath)
        $mappingPath = Resolve-MappingPathForBundle -BundleRoot $effectiveBundleRoot -MappingPath $mappingPath -TechId ([string]$entry.techId) -OutputRoot $OutputRoot
        $templatePath = Join-Path $catalogBase ([string]$entry.templatePath)
        $outputPath = Join-Path $techOutputRoot ([string]$entry.outputFileName)
        $reportPath = Join-Path $techOutputRoot ("$([string]$entry.id).render-report.json")

        $mappingVariants = Resolve-MappingVariantsForBundle -BundleRoot $effectiveBundleRoot -MappingPath $mappingPath -TechId ([string]$entry.techId) -OutputRoot $OutputRoot -EntryId ([string]$entry.id)
        $variantReports = [System.Collections.Generic.List[hashtable]]::new()
        $sectionTexts = [System.Collections.Generic.List[string]]::new()
        $runStatus = 'OK'

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
            }
            catch {
                $variantStatus = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'ERROR' }
            }

            if ($variantStatus -eq 'ERROR') {
                $runStatus = 'ERROR'
                $status = 'ERROR'
                $issues.Add([ordered]@{ code = 'ASB-ASM-BUNDLE-ENTRY-FAILED'; severity = 'ERROR'; message = "Entry '$($entry.id)' variant '$variantName' failed render."; path = $variantReportPath })
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

        if (@($mappingVariants).Count -gt 1 -and $sectionTexts.Count -gt 0) {
            Set-Content -LiteralPath $outputPath -Value (($sectionTexts -join ([Environment]::NewLine + [Environment]::NewLine)) + [Environment]::NewLine) -Encoding UTF8
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
        })
    }
}
catch {
    $status = 'ERROR'
    $issues.Add([ordered]@{ code = 'ASB-ASM-BUNDLE-UNHANDLED'; severity = 'ERROR'; message = $_.Exception.Message; path = $null })
}

$report = [ordered]@{
    schemaVersion = 1
    status = $status
    startedUtc = $startedUtc
    completedUtc = Get-UtcTimestamp
    bundleRoot = $effectiveBundleRoot
    catalogPath = $CatalogPath
    outputRoot = $OutputRoot
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
