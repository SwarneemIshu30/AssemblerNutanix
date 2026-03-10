Describe 'Invoke-AssemblerBundleRender orchestration' {
    It 'runs renderer per catalog entry for selected tech' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleRoot = Join-Path $repoRoot 'bundle/66694360-25ba-40de-8fbd-07ebce431c53'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-test-" + [guid]::NewGuid().ToString())
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -TechId 'Lenovo.DE'
            if ($LASTEXITCODE -ne 0) {
                throw "Expected exit code 0, got $LASTEXITCODE"
            }

            $report = $json | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }

            $bundleReportPath = Join-Path $outputRoot 'assembler-bundle-render-report.json'
            if (-not (Test-Path -LiteralPath $bundleReportPath -PathType Leaf)) {
                throw 'Expected bundle render report file'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'selects deterministic target even when run_summary mtimes differ' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sourceBundleRoot = Join-Path $repoRoot 'bundle/fc2c8a97-9214-456c-9d2f-4fcaba90e8ef'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-stable-target-test-" + [guid]::NewGuid().ToString())
        $bundleRoot = Join-Path $tempRoot 'bundle-copy'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            Copy-Item -LiteralPath $sourceBundleRoot -Destination $bundleRoot -Recurse -Force

            $targetOneSummary = Join-Path $bundleRoot 'datasets/Lenovo.DE/collector-out/_multi/target_de-prod-01/run_summary.json'
            $targetTwoSummary = Join-Path $bundleRoot 'datasets/Lenovo.DE/collector-out/_multi/target_de-prod-02/run_summary.json'

            if ((Test-Path -LiteralPath $targetOneSummary -PathType Leaf) -and (Test-Path -LiteralPath $targetTwoSummary -PathType Leaf)) {
                (Get-Item -LiteralPath $targetOneSummary).LastWriteTimeUtc = [datetime]::Parse('2022-01-01T00:00:00Z')
                (Get-Item -LiteralPath $targetTwoSummary).LastWriteTimeUtc = [datetime]::Parse('2030-01-01T00:00:00Z')
            }
            else {
                throw 'Expected run_summary.json files for both targets in fixture bundle copy'
            }

            $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -TechId 'Lenovo.DE'
            if ($LASTEXITCODE -ne 0) {
                throw "Expected exit code 0, got $LASTEXITCODE"
            }

            $report = $json | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }

            $run = @($report.runs)[0]
            $variant = @($run.variants)[0]
            if ($variant.selectedTarget -ne 'target_de-prod-01') {
                throw "Expected stable deterministic target 'target_de-prod-01', got '$($variant.selectedTarget)'"
            }
            if ($variant.targetSelectionReason -ne 'solution-plan:de-prod-01') {
                throw "Expected solution-plan selection reason, got '$($variant.targetSelectionReason)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails fast when BundleRoot staging directory contains multiple bundles' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleStagingRoot = Join-Path $repoRoot 'bundle'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        if (-not (Test-Path -LiteralPath $bundleStagingRoot -PathType Container)) {
            throw "Expected bundle staging root: $bundleStagingRoot"
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-multibundle-test-" + [guid]::NewGuid().ToString())
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleStagingRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -TechId 'Lenovo.DE' 2>&1
            if ($LASTEXITCODE -eq 0) {
                throw 'Expected non-zero exit code when bundle staging root contains multiple bundle candidates'
            }

            $errorText = [string]($json | Out-String)
            if ($errorText -notmatch 'multiple bundle candidates') {
                throw "Expected error about multiple bundle candidates, got: $errorText"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

}
