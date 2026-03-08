Describe 'Invoke-AssemblerPipeline validation result handling' {
    It 'returns status ok for a valid solution plan without throwing on planErrors.Count' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $bundleRoot = Join-Path $repoRoot 'sample/577f2001-d0e6-4ec8-81ac-025c367a0112'
        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'

        $output = & pwsh -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -ContractsRoot $contractsRoot
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $output | Should -Not -BeNullOrEmpty

        $report = $output | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'ok'
    }
}
