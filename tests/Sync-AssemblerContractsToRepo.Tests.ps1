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
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        try {
            $result = & $pwshPath -NoLogo -NoProfile -File $scriptPath -ExportContractsPath $sourceRoot -DepsContractsPath $destinationRoot -SkeletonMappingOutputPath $skeletonMappingPath -Clean
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
            if (-not (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf)) {
                throw 'Expected Lenovo.DE collector skeleton mapping generated from contract during sync'
            }

            $generatedMapping = Get-Content -LiteralPath $skeletonMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if ($generatedMapping.generatedFromContract.path -ne 'tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml') {
                throw "Expected generatedFromContract.path to be contract yaml path, got '$($generatedMapping.generatedFromContract.path)'"
            }
            if ((@($generatedMapping.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.Controllers' }).Count) -eq 0) {
                throw 'Expected generated skeleton mapping to include Controllers table mapping from contract'
            }

            $report = $result | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ok') {
                throw "Expected sync status ok, got '$($report.status)'"
            }
            if ($report.mode -ne 'LocalExport') {
                throw "Expected sync mode LocalExport, got '$($report.mode)'"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$report.skeletonMappingPath) -and -not (Test-Path -LiteralPath ([string]$report.skeletonMappingPath) -PathType Leaf)) {
                throw "Expected report.skeletonMappingPath '$($report.skeletonMappingPath)' to exist"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
