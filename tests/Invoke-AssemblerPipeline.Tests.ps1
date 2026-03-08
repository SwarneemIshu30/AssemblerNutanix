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

        $bundleRoot = Join-Path $sampleRoot 'fc2c8a97-9214-456c-9d2f-4fcaba90e8ef'
        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'

        $output = & $scriptPath -BundleRoot $bundleRoot -ContractsRoot $contractsRoot
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
    }
}
