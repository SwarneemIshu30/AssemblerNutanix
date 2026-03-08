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

.OUTPUTS
JSON text representing a report object with:
- `schemaVersion`
- `status` (`ok` or `error`)
- optional `bundle` summary block
- `diagnostics` list

.EXAMPLE
pwsh ./scripts/Invoke-AssemblerPipeline.ps1 `
  -BundleRoot ./sample/bundle `
  -ContractsRoot ./export/repo-ready/contracts

.EXAMPLE
pwsh ./scripts/Invoke-AssemblerPipeline.ps1 `
  -BundleRoot ./sample/bundle `
  -ContractsRoot ./export/repo-ready/contracts `
  -OutputPath ./out/assembler-bootstrap-report.json

.NOTES
Exit code is `0` when `status=ok` and `1` when `status=error`.
#>
#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$ContractsRoot,
    [Parameter(Mandatory = $false)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp {
    (Get-Date).ToUniversalTime().ToString('o')
}

function New-Diagnostic {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [ordered]@{
        tsUtc   = Get-UtcTimestamp
        stage   = $Stage
        level   = $Level
        code    = $Code
        message = $Message
    }
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

function Test-SolutionPlanMinimumContract {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$Schema
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($requiredKey in ($Schema.required ?? @())) {
        if (-not $Plan.ContainsKey([string]$requiredKey)) {
            $errors.Add("ASB-ASM-CONTRACT-SOLUTIONPLAN-REQUIRED: missing required property '$requiredKey'")
        }
    }

    $schemaProperties = $Schema.properties
    if ($null -ne $schemaProperties) {
        foreach ($entry in $schemaProperties.GetEnumerator()) {
            $propertyName = [string]$entry.Key
            $propertySchema = $entry.Value
            if ($Plan.ContainsKey($propertyName) -and $propertySchema.ContainsKey('const')) {
                if ($Plan[$propertyName] -ne $propertySchema.const) {
                    $errors.Add("ASB-ASM-CONTRACT-SOLUTIONPLAN-CONST: property '$propertyName' must be '$($propertySchema.const)'")
                }
            }
        }
    }

    if ($Plan.ContainsKey('targets') -and -not ($Plan.targets -is [System.Collections.IList])) {
        $errors.Add("ASB-ASM-CONTRACT-SOLUTIONPLAN-TARGETS-TYPE: 'targets' must be an array")
    }
    if ($Plan.ContainsKey('collectors') -and -not ($Plan.collectors -is [System.Collections.IList])) {
        $errors.Add("ASB-ASM-CONTRACT-SOLUTIONPLAN-COLLECTORS-TYPE: 'collectors' must be an array")
    }

    return $errors
}

function Invoke-AssemblerPipeline {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $false)][string]$OutputPath
    )

    $diagnostics = [System.Collections.Generic.List[hashtable]]::new()
    $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message 'Resolving required Direct-v1 input paths'))

    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    $objectIndexPath = Join-Path $BundleRoot 'objectIndex.json'
    $solutionPlanPath = Join-Path (Join-Path $BundleRoot 'config') 'solution.plan.json'
    $solutionPlanSchemaPath = Join-Path (Join-Path $ContractsRoot 'standards') 'solution.plan.schema.v1.json'

    try {
        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message "Loading $manifestPath"))
        $manifest = Read-JsonFile -Path $manifestPath

        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message "Loading $objectIndexPath"))
        $objectIndex = Read-JsonFile -Path $objectIndexPath

        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-INPUT-LOAD' -Message "Loading $solutionPlanPath"))
        $solutionPlan = Read-JsonFile -Path $solutionPlanPath

        $diagnostics.Add((New-Diagnostic -Stage 'Load' -Level 'INFO' -Code 'ASB-ASM-CONTRACT-LOAD' -Message "Loading $solutionPlanSchemaPath"))
        $solutionPlanSchema = Read-JsonFile -Path $solutionPlanSchemaPath

        $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'INFO' -Code 'ASB-ASM-CONTRACT-VALIDATE' -Message 'Performing minimum solution plan contract checks'))
        $planErrors = Test-SolutionPlanMinimumContract -Plan $solutionPlan -Schema $solutionPlanSchema
        foreach ($err in $planErrors) {
            $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'ERROR' -Code 'ASB-ASM-CONTRACT-VALIDATE' -Message $err))
        }

        if ($planErrors.Count -gt 0) {
            throw 'ASB-ASM-CONTRACT-FAIL: solution plan validation failed'
        }

        $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'INFO' -Code 'ASB-ASM-CONTRACT-VALIDATE' -Message 'Minimum contract checks passed'))

        $report = [ordered]@{
            schemaVersion = 1
            status        = 'ok'
            bundle        = [ordered]@{
                root                  = $BundleRoot
                manifestSchemaVersion = $manifest.schemaVersion
                objectCount           = $objectIndex.objectCount
                solutionId            = $solutionPlan.solutionId
                targetCount           = @($solutionPlan.targets).Count
                collectorCount        = @($solutionPlan.collectors).Count
            }
            diagnostics  = $diagnostics
        }
    }
    catch {
        $diagnostics.Add((New-Diagnostic -Stage 'Validate' -Level 'ERROR' -Code 'ASB-ASM-INPUT-FAIL' -Message $_.Exception.Message))
        $report = [ordered]@{
            schemaVersion = 1
            status        = 'error'
            diagnostics   = $diagnostics
        }
    }

    $json = $report | ConvertTo-Json -Depth 10

    if ($OutputPath) {
        $parent = Split-Path -Path $OutputPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
    }
    else {
        $json
    }

    if ($report.status -eq 'error') {
        exit 1
    }
}

Invoke-AssemblerPipeline -BundleRoot $BundleRoot -ContractsRoot $ContractsRoot -OutputPath $OutputPath
