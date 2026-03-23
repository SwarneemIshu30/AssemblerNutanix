Describe 'Sync-AssemblerContractsToRepo' {
    It 'copies an explicit local contracts source into the deterministic destination' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path $repoRoot 'scripts/Sync-AssemblerContractsToRepo.ps1'
        $sourceRoot = Join-Path $repoRoot '.deps/contracts'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-contract-sync-test-" + [guid]::NewGuid().ToString())
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'

        try {
            $result = & $pwshPath -NoLogo -NoProfile -File $scriptPath -ExportContractsPath $sourceRoot -DepsContractsPath $destinationRoot -Clean
            if ($LASTEXITCODE -ne 0) {
                throw "Expected exit code 0 from contract sync, got $LASTEXITCODE"
            }

            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'standards/mapping.dataset-to-sdt.schema.v1.json') -PathType Leaf)) {
                throw 'Expected mapping contract schema in destination after sync'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'standards/assembler/assembler.bundle-render-report.schema.v1.json') -PathType Leaf)) {
                throw 'Expected bundle render report schema in destination after sync'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'standards/assembler/assembler.projections.schema.v1.json') -PathType Leaf)) {
                throw 'Expected projection contract schema in destination after sync'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'contracts.snapshot.json') -PathType Leaf)) {
                throw 'Expected contracts snapshot in destination after sync'
            }

            $report = $result | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ok') {
                throw "Expected sync status ok, got '$($report.status)'"
            }
            if ($report.mode -ne 'LocalExport') {
                throw "Expected sync mode LocalExport, got '$($report.mode)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
