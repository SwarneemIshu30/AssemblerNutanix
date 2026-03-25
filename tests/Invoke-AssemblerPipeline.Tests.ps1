Describe 'Invoke-AssemblerPipeline validation result handling' {
    It 'returns status ok for a valid solution plan without throwing on planErrors.Count' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $sampleRoot = if (Test-Path -LiteralPath (Join-Path $repoRoot 'samples')) {
            Join-Path $repoRoot 'samples'
        }
        else {
            Join-Path $repoRoot 'sample'
        }

        $preferredBundleRoot = Join-Path $sampleRoot 'fc2c8a97-9214-456c-9d2f-4fcaba90e8ef'
        if (Test-Path -LiteralPath $preferredBundleRoot -PathType Container) {
            $bundleRoot = $preferredBundleRoot
        }
        else {
            $bundleRoot = Get-ChildItem -LiteralPath $sampleRoot -Directory |
                Where-Object {
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'objectIndex.json') -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'config/solution.plan.json') -PathType Leaf)
                } |
                Select-Object -First 1 -ExpandProperty FullName
        }

        if ([string]::IsNullOrWhiteSpace([string]$bundleRoot)) {
            throw "No valid sample bundle directory found under '$sampleRoot'"
        }

        $contractsRoot = Join-Path $repoRoot '.deps/contracts'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts/Invoke-AssemblerPipeline.ps1 in this test'
        }

        $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -ContractsRoot $contractsRoot
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            throw "Expected exit code 0 for valid bundle, got $exitCode"
        }
        if ([string]::IsNullOrWhiteSpace([string]$output)) {
            throw 'Expected non-empty output from Invoke-AssemblerPipeline'
        }

        $report = $output | ConvertFrom-Json -AsHashtable
        if ($report.status -ne 'ok') {
            throw "Expected report.status to be 'ok' for valid bundle, got '$($report.status)'"
        }

        $renderStage = @($report.stages | Where-Object { [string]$_.name -eq 'Render' })[0]
        if ($null -eq $renderStage) {
            throw 'Expected Render stage to be present in pipeline report'
        }
        if ([string]$renderStage.status -ne 'SKIPPED') {
            throw "Expected Render stage status SKIPPED by default, got '$($renderStage.status)'"
        }

        $guidanceDiagnostic = @($report.diagnostics | Where-Object { [string]$_.code -eq 'ASB-ASM-RENDER-NEXT-COMMAND' })[0]
        if ($null -eq $guidanceDiagnostic) {
            throw 'Expected ASB-ASM-RENDER-NEXT-COMMAND diagnostic when render handoff is not requested'
        }
        if ([string]$guidanceDiagnostic.message -notlike '*Invoke-AssemblerBundleRender.ps1*') {
            throw "Expected guidance diagnostic to reference Invoke-AssemblerBundleRender.ps1, got '$($guidanceDiagnostic.message)'"
        }
    }

    It 'returns status error and guidance when render handoff parameters are incomplete' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $sampleRoot = if (Test-Path -LiteralPath (Join-Path $repoRoot 'samples')) {
            Join-Path $repoRoot 'samples'
        }
        else {
            Join-Path $repoRoot 'sample'
        }

        $bundleRoot = Get-ChildItem -LiteralPath $sampleRoot -Directory |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'objectIndex.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'config/solution.plan.json') -PathType Leaf)
            } |
            Select-Object -First 1 -ExpandProperty FullName

        if ([string]::IsNullOrWhiteSpace([string]$bundleRoot)) {
            throw "No valid sample bundle directory found under '$sampleRoot'"
        }

        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts/Invoke-AssemblerPipeline.ps1 in this test'
        }

        $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -ContractsRoot $contractsRoot -RenderCatalogPath './templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            throw 'Expected non-zero exit code when render handoff parameters are incomplete'
        }

        $report = $output | ConvertFrom-Json -AsHashtable
        if ($report.status -ne 'error') {
            throw "Expected report.status to be 'error' for incomplete render handoff params, got '$($report.status)'"
        }
        $failureDiagnostic = @($report.diagnostics | Where-Object { [string]$_.code -eq 'ASB-ASM-INPUT-FAIL' })[0]
        if ($null -eq $failureDiagnostic -or [string]$failureDiagnostic.message -notlike '*ASB-ASM-RENDER-PARAMS-INCOMPLETE*') {
            throw "Expected failure diagnostic to include ASB-ASM-RENDER-PARAMS-INCOMPLETE, got '$($failureDiagnostic.message)'"
        }
    }
}
