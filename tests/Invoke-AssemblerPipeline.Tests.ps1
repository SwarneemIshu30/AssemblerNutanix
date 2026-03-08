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

        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'

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
    }
}
