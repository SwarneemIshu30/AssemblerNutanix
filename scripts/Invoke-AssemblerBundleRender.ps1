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
        $templatePath = Join-Path $catalogBase ([string]$entry.templatePath)
        $outputPath = Join-Path $techOutputRoot ([string]$entry.outputFileName)
        $reportPath = Join-Path $techOutputRoot ("$([string]$entry.id).render-report.json")

        $json = & $invokeRenderScript -BundleRoot $effectiveBundleRoot -MappingPath $mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $effectiveContractsRoot

        $runStatus = 'OK'
        try {
            $rendererReport = $json | ConvertFrom-Json -AsHashtable
            if ($rendererReport.ContainsKey('status') -and [string]$rendererReport.status -eq 'ERROR') {
                $runStatus = 'ERROR'
            }
        }
        catch {
            $runStatus = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'ERROR' }
        }
        if ($runStatus -eq 'ERROR') {
            $status = 'ERROR'
            $issues.Add([ordered]@{ code = 'ASB-ASM-BUNDLE-ENTRY-FAILED'; severity = 'ERROR'; message = "Entry '$($entry.id)' failed render."; path = $reportPath })
        }

        $runs.Add([ordered]@{
            entryId = [string]$entry.id
            techId = [string]$entry.techId
            status = $runStatus
            outputPath = $outputPath
            reportPath = $reportPath
            rendererOutputJson = $json
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
