<#
.SYNOPSIS
Bootstrap Assembler ingestion pipeline for Direct-v1 inputs.

.DESCRIPTION
Loads required bundle artifacts (`manifest.json`, `objectIndex.json`, `config/solution.plan.json`) and
`solution.plan.schema.v1.json` from the contracts root, performs minimum contract checks, and emits
a machine-readable JSON report with staged diagnostics.

.PARAMETER BundleRoot
Path to the Direct-v1 bundle root. Required files under this root are:
- `manifest.json`
- `objectIndex.json`
- `config/solution.plan.json`

.PARAMETER ContractsRoot
Path to the contracts root containing `standards/solution.plan.schema.v1.json`.

.PARAMETER OutputPath
Optional output file path for the JSON report. If omitted, report JSON is written to stdout.

.PARAMETER RenderCatalogPath
Optional TemplateCatalog path. When provided with `RenderOutputRoot`, the pipeline hands off to
`Invoke-AssemblerBundleRender.ps1` after validation.

.PARAMETER RenderOutputRoot
Optional render output root. Must be supplied together with `RenderCatalogPath` to enable render handoff.

.PARAMETER RenderTechId
Optional one-or-more tech filters forwarded to `Invoke-AssemblerBundleRender.ps1` when render handoff is enabled.

.PARAMETER MappingShapeMode
Optional rollout mode (`legacy`, `dual`, `target`) used to enforce mapping output shape in both contract and runtime mapping files.

.PARAMETER ContractMappingPath
Optional path to the contract mapping file for shape-mode validation. Requires `-MappingShapeMode`.

.PARAMETER RuntimeMappingPath
Optional path to the runtime/generated mapping file for shape-mode validation. Requires `-MappingShapeMode`.

.NOTES
Exit code is `0` when `status=ok` and `1` when `status=error`.
#>
#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$ContractsRoot,
    [Parameter(Mandatory = $false)][string]$OutputPath,
    [Parameter(Mandatory = $false)][string]$RenderCatalogPath,
    [Parameter(Mandatory = $false)][string]$RenderOutputRoot,
    [Parameter(Mandatory = $false)][string[]]$RenderTechId,
    [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
    [Parameter(Mandatory = $false)][ValidateSet('legacy', 'dual', 'target')][string]$MappingShapeMode,
    [Parameter(Mandatory = $false)][string]$ContractMappingPath,
    [Parameter(Mandatory = $false)][string]$RuntimeMappingPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerSchemaValidation.psm1') -Force

function Get-UtcTimestamp { (Get-Date).ToUniversalTime().ToString('o') }

function New-Diagnostic {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [ordered]@{ tsUtc = Get-UtcTimestamp; stage = $Stage; level = $Level; code = $Code; message = $Message }
}

function New-StageRecord {
    param([Parameter(Mandatory = $true)][string]$Name)
    [ordered]@{ name = $Name; status = 'SKIPPED'; startedUtc = $null; completedUtc = $null; details = $null }
}

function Start-Stage {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Stage)
    $Stage.startedUtc = Get-UtcTimestamp
    $Stage.completedUtc = $null
    $Stage.status = 'OK'
}

function Complete-Stage {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][hashtable]$Details
    )

    $Stage.status = $Status
    $Stage.completedUtc = Get-UtcTimestamp
    if ($PSBoundParameters.ContainsKey('Details')) { $Stage.details = $Details }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ASB-ASM-INPUT-MISSING: required file not found: $Path"
    }

    try {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "ASB-ASM-INPUT-INVALIDJSON: invalid JSON in $Path :: $($_.Exception.Message)"
    }
}

function Invoke-AssemblerPipeline {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $false)][string]$OutputPath,
        [Parameter(Mandatory = $false)][string]$RenderCatalogPath,
        [Parameter(Mandatory = $false)][string]$RenderOutputRoot,
        [Parameter(Mandatory = $false)][string[]]$RenderTechId,
        [Parameter(Mandatory = $false)][ValidateSet('legacy', 'dual', 'target')][string]$MappingShapeMode,
        [Parameter(Mandatory = $false)][string]$ContractMappingPath,
        [Parameter(Mandatory = $false)][string]$RuntimeMappingPath
    )

    $diagnostics = [System.Collections.Generic.List[hashtable]]::new()
    $stages = [ordered]@{
        Load = (New-StageRecord -Name 'Load')
        Validate = (New-StageRecord -Name 'Validate')
        Transform = (New-StageRecord -Name 'Transform')
        Render = (New-StageRecord -Name 'Render')
        Finalize = (New-StageRecord -Name 'Finalize')
    }

    $report = $null
    $renderReport = $null
    $manifest = $null
    $objectIndex = $null
    $solutionPlan = $null
    try {
        $renderCatalogProvided = -not [string]::IsNullOrWhiteSpace($RenderCatalogPath)
        $renderOutputProvided = -not [string]::IsNullOrWhiteSpace($RenderOutputRoot)
        if ($renderCatalogProvided -xor $renderOutputProvided) {
            throw 'ASB-ASM-RENDER-PARAMS-INCOMPLETE: supply both -RenderCatalogPath and -RenderOutputRoot to enable render handoff.'
        }
        if ((-not [string]::IsNullOrWhiteSpace($ContractMappingPath) -or -not [string]::IsNullOrWhiteSpace($RuntimeMappingPath)) -and [string]::IsNullOrWhiteSpace($MappingShapeMode)) {
            throw 'ASB-ASM-MAPPING-SHAPE-PARAMS-INCOMPLETE: supply -MappingShapeMode when using -ContractMappingPath or -RuntimeMappingPath.'
        }

        Start-Stage -Stage $stages.Load
        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message 'Resolving required Direct-v1 input paths'))

        $manifestPath = Join-Path $BundleRoot 'manifest.json'
        $objectIndexPath = Join-Path $BundleRoot 'objectIndex.json'
        $solutionPlanPath = Join-Path (Join-Path $BundleRoot 'config') 'solution.plan.json'
        $manifestSchemaPath = Join-Path (Join-Path $ContractsRoot 'standards') 'bundle.manifest.schema.v1.json'
        $objectIndexSchemaPath = Join-Path (Join-Path $ContractsRoot 'standards') 'objectIndex.schema.v1.json'
        $solutionPlanSchemaPath = Join-Path (Join-Path $ContractsRoot 'standards') 'solution.plan.schema.v1.json'

        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message "Loading $manifestPath"))
        $manifest = Read-JsonFile -Path $manifestPath
        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message "Loading $objectIndexPath"))
        $objectIndex = Read-JsonFile -Path $objectIndexPath
        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message "Loading $solutionPlanPath"))
        $solutionPlan = Read-JsonFile -Path $solutionPlanPath
        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-CONTRACT-LOAD' -Message "Resolved schema paths from $ContractsRoot/standards"))
        Complete-Stage -Stage $stages.Load -Status 'OK'

        Start-Stage -Stage $stages.Validate
        $schemaFailures = [System.Collections.Generic.List[hashtable]]::new()
        $schemaChecks = @(
            [ordered]@{ artifact = 'manifest.json'; documentPath = $manifestPath; schemaPath = $manifestSchemaPath; code = 'ASB-ASM-SCHEMA-MANIFEST-INVALID' },
            [ordered]@{ artifact = 'objectIndex.json'; documentPath = $objectIndexPath; schemaPath = $objectIndexSchemaPath; code = 'ASB-ASM-SCHEMA-OBJECTINDEX-INVALID' },
            [ordered]@{ artifact = 'config/solution.plan.json'; documentPath = $solutionPlanPath; schemaPath = $solutionPlanSchemaPath; code = 'ASB-ASM-SCHEMA-SOLUTIONPLAN-INVALID' }
        )

        foreach ($schemaCheck in $schemaChecks) {
            $validationResult = Test-AssemblerSchemaFile -DocumentPath $schemaCheck.documentPath -SchemaPath $schemaCheck.schemaPath
            if (-not $validationResult.isValid) {
                $schemaFailures.Add([ordered]@{ code = $schemaCheck.code; message = [string]$validationResult.message })
                $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'ERROR' -Code $schemaCheck.code -Message $validationResult.message))
            }
            else {
                $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'INFO' -Code 'ASB-ASM-CONTRACT-VALIDATE' -Message "Schema validation passed for $($schemaCheck.artifact)"))
            }
        }

        if ($schemaFailures.Count -gt 0) {
            Complete-Stage -Stage $stages.Validate -Status 'ERROR'
            throw 'ASB-ASM-CONTRACT-FAIL: required input schema validation failed'
        }

        $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'INFO' -Code 'ASB-ASM-CONTRACT-VALIDATE' -Message 'Required input schema checks passed'))

        if (-not [string]::IsNullOrWhiteSpace($MappingShapeMode)) {
            $resolvedContractMappingPath = if (-not [string]::IsNullOrWhiteSpace($ContractMappingPath)) {
                $ContractMappingPath
            }
            else {
                Join-Path (Join-Path $ContractsRoot 'tech/Lenovo.DE') 'mapping.dataset-to-sdt.v1.yaml'
            }
            $resolvedRuntimeMappingPath = if (-not [string]::IsNullOrWhiteSpace($RuntimeMappingPath)) {
                $RuntimeMappingPath
            }
            else {
                Join-Path (Join-Path $PSScriptRoot '..') 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
            }

            $mappingValidationScript = Join-Path $PSScriptRoot 'Test-AssemblerMappingShapeMode.ps1'
            if (-not (Test-Path -LiteralPath $mappingValidationScript -PathType Leaf)) {
                throw "ASB-ASM-MAPPING-SHAPE-VALIDATION-MISSING: required script not found: $mappingValidationScript"
            }

            $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if ([string]::IsNullOrWhiteSpace([string]$pwshPath)) {
                throw 'ASB-ASM-MAPPING-SHAPE-PWSH-MISSING: pwsh is required to execute Test-AssemblerMappingShapeMode.ps1.'
            }

            $shapeValidationOutput = & $pwshPath -NoLogo -NoProfile -File $mappingValidationScript -Mode $MappingShapeMode -ContractMappingPath $resolvedContractMappingPath -RuntimeMappingPath $resolvedRuntimeMappingPath
            if ($LASTEXITCODE -ne 0) {
                throw "ASB-ASM-MAPPING-SHAPE-VALIDATION-FAILED: $shapeValidationOutput"
            }

            $shapeValidationReport = $shapeValidationOutput | ConvertFrom-Json -AsHashtable
            $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'INFO' -Code 'ASB-ASM-MAPPING-SHAPE-VALIDATE' -Message "Mapping shape mode '$MappingShapeMode' validated for contract/runtime mappings."))
            $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'INFO' -Code 'ASB-ASM-MAPPING-MIGRATION-DASHBOARD' -Message "contract[sdtTagOnly=$($shapeValidationReport.dashboard.contract.sdtTagOnly),dual=$($shapeValidationReport.dashboard.contract.dual),targetOnly=$($shapeValidationReport.dashboard.contract.targetOnly)] runtime[sdtTagOnly=$($shapeValidationReport.dashboard.runtime.sdtTagOnly),dual=$($shapeValidationReport.dashboard.runtime.dual),targetOnly=$($shapeValidationReport.dashboard.runtime.targetOnly)]"))
        }

        Complete-Stage -Stage $stages.Validate -Status 'OK'

        Start-Stage -Stage $stages.Transform
        Complete-Stage -Stage $stages.Transform -Status 'SKIPPED' -Details ([ordered]@{ reason = 'No transform operation in bootstrap pipeline.' })

        Start-Stage -Stage $stages.Render
        if ($renderCatalogProvided -and $renderOutputProvided) {
            $invokeBundleRenderScript = Join-Path $PSScriptRoot 'Invoke-AssemblerBundleRender.ps1'
            if (-not (Test-Path -LiteralPath $invokeBundleRenderScript -PathType Leaf)) {
                throw "ASB-ASM-RENDER-HANDOFF-MISSING: required script not found: $invokeBundleRenderScript"
            }

            $renderArguments = @(
                '-NoLogo', '-NoProfile',
                '-File', $invokeBundleRenderScript,
                '-BundleRoot', $BundleRoot,
                '-CatalogPath', $RenderCatalogPath,
                '-OutputRoot', $RenderOutputRoot,
                '-ContractsRoot', $ContractsRoot,
                '-DocxMatchMode', $DocxMatchMode
            )
            if ($RenderTechId -and @($RenderTechId).Count -gt 0) {
                $renderArguments += @('-TechId')
                $renderArguments += @($RenderTechId)
            }

            $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if ([string]::IsNullOrWhiteSpace([string]$pwshPath)) {
                throw 'ASB-ASM-RENDER-HANDOFF-PWSH-MISSING: pwsh is required to execute Invoke-AssemblerBundleRender.ps1.'
            }

            $renderOutputJson = & $pwshPath @renderArguments
            if ($LASTEXITCODE -ne 0) {
                throw "ASB-ASM-RENDER-HANDOFF-FAILED: Invoke-AssemblerBundleRender.ps1 exited with code $LASTEXITCODE."
            }

            $renderReport = $renderOutputJson | ConvertFrom-Json -AsHashtable
            $renderStatus = if ($renderReport.ContainsKey('status')) { [string]$renderReport.status } else { 'OK' }
            $renderStageStatus = switch ($renderStatus) {
                'ERROR' { 'ERROR' }
                'WARN' { 'WARN' }
                'PARTIAL' { 'WARN' }
                default { 'OK' }
            }
            $renderIssueCount = if ($renderReport.ContainsKey('issues')) { @($renderReport.issues).Count } else { 0 }
            $diagnostics.Add((New-Diagnostic -Stage 'Render' -Level 'INFO' -Code 'ASB-ASM-RENDER-HANDOFF' -Message "Render handoff executed via Invoke-AssemblerBundleRender.ps1 (status=$renderStatus, issues=$renderIssueCount, docxMatchMode=$DocxMatchMode)."))
            Complete-Stage -Stage $stages.Render -Status $renderStageStatus -Details ([ordered]@{
                handoffScript = $invokeBundleRenderScript
                catalogPath = $RenderCatalogPath
                outputRoot = $RenderOutputRoot
                techId = @($RenderTechId)
                renderStatus = $renderStatus
                issueCount = $renderIssueCount
            })
        }
        else {
            $guidanceCommand = "pwsh ./scripts/Invoke-AssemblerBundleRender.ps1 -BundleRoot '$BundleRoot' -CatalogPath <catalog.json> -OutputRoot <out>"
            $diagnostics.Add((New-Diagnostic -Stage 'Render' -Level 'INFO' -Code 'ASB-ASM-RENDER-NEXT-COMMAND' -Message "Render step skipped. Next command: $guidanceCommand"))
            Complete-Stage -Stage $stages.Render -Status 'SKIPPED' -Details ([ordered]@{
                reason = 'Render handoff not requested.'
                nextCommand = $guidanceCommand
                requires = @('-RenderCatalogPath', '-RenderOutputRoot')
            })
        }

        $report = [ordered]@{
            schemaVersion = 1
            status = 'ok'
            bundle = [ordered]@{
                root = $BundleRoot
                manifestSchemaVersion = $manifest.schemaVersion
                objectCount = if ($objectIndex.ContainsKey('objectCount')) { $objectIndex.objectCount } else { @($objectIndex.objects).Count }
                solutionId = $solutionPlan.solutionId
                targetCount = @($solutionPlan.targets).Count
                collectorCount = @($solutionPlan.collectors).Count
            }
            render = if ($null -ne $renderReport) { $renderReport } else { $null }
            stages = @($stages.Load, $stages.Validate, $stages.Transform, $stages.Render, $stages.Finalize)
            diagnostics = $diagnostics
        }
    }
    catch {
        if ($null -ne $stages.Load.startedUtc -and $null -eq $stages.Load.completedUtc) { Complete-Stage -Stage $stages.Load -Status 'ERROR' }
        if ($null -ne $stages.Validate.startedUtc -and $null -eq $stages.Validate.completedUtc) { Complete-Stage -Stage $stages.Validate -Status 'ERROR' }

        $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'ERROR' -Code 'ASB-ASM-INPUT-FAIL' -Message $_.Exception.Message))
        $report = [ordered]@{
            schemaVersion = 1
            status = 'error'
            stages = @($stages.Load, $stages.Validate, $stages.Transform, $stages.Render, $stages.Finalize)
            diagnostics = $diagnostics
        }
    }

    Start-Stage -Stage $stages.Finalize
    $parent = if ($OutputPath) { Split-Path -Path $OutputPath -Parent } else { $null }
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Complete-Stage -Stage $stages.Finalize -Status $(if ($report.status -eq 'error') { 'ERROR' } else { 'OK' })
    $json = $report | ConvertTo-Json -Depth 10
    if ($OutputPath) { Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8 } else { $json }

    if ($report.status -eq 'error') { exit 1 }
}

Invoke-AssemblerPipeline -BundleRoot $BundleRoot -ContractsRoot $ContractsRoot -OutputPath $OutputPath -RenderCatalogPath $RenderCatalogPath -RenderOutputRoot $RenderOutputRoot -RenderTechId $RenderTechId -MappingShapeMode $MappingShapeMode -ContractMappingPath $ContractMappingPath -RuntimeMappingPath $RuntimeMappingPath

