Describe 'Invoke-AssemblerBundleRender orchestration' {
    It 'runs renderer per catalog entry for selected tech' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleRoot = Join-Path $repoRoot 'bundle/417f4663-0922-423b-92a9-34d4e33ecd0e'
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
        $sourceBundleRoot = Join-Path $repoRoot 'bundle/417f4663-0922-423b-92a9-34d4e33ecd0e'
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

            $legacyRoot = Join-Path $bundleRoot 'datasets/Lenovo.DE/collector-out/_multi'
            $singleTargetRoot = Join-Path $bundleRoot 'datasets/Lenovo.DE/collector-out/de-prod-01/target_de-prod-01'
            $legacyTargetOneRoot = Join-Path $legacyRoot 'target_de-prod-01'
            $legacyTargetTwoRoot = Join-Path $legacyRoot 'target_de-prod-02'

            New-Item -ItemType Directory -Path $legacyRoot -Force | Out-Null
            Copy-Item -LiteralPath $singleTargetRoot -Destination $legacyTargetOneRoot -Recurse -Force
            Copy-Item -LiteralPath $singleTargetRoot -Destination $legacyTargetTwoRoot -Recurse -Force

            $targetOneSummary = Join-Path $legacyTargetOneRoot 'run_summary.json'
            $targetTwoSummary = Join-Path $legacyTargetTwoRoot 'run_summary.json'
            (Get-Item -LiteralPath $targetOneSummary).LastWriteTimeUtc = [datetime]::Parse('2022-01-01T00:00:00Z')
            (Get-Item -LiteralPath $targetTwoSummary).LastWriteTimeUtc = [datetime]::Parse('2030-01-01T00:00:00Z')

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
            $expectedTargetRoot = Join-Path $bundleRoot 'datasets/Lenovo.DE/collector-out/_multi/target_de-prod-01'
            if ($variant.selectedTargetRoot -ne $expectedTargetRoot) {
                throw "Expected selectedTargetRoot '$expectedTargetRoot', got '$($variant.selectedTargetRoot)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }



    It 'writes resolved Lenovo.DE mappings against discovered target roots' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleRoot = Join-Path $repoRoot 'bundle/417f4663-0922-423b-92a9-34d4e33ecd0e'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-resolved-mapping-test-" + [guid]::NewGuid().ToString())
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

            $variant = @(@($report.runs)[0].variants)[0]
            $resolvedMappingPath = [string]$variant.mappingPath
            if (-not (Test-Path -LiteralPath $resolvedMappingPath -PathType Leaf)) {
                throw "Expected resolved mapping path '$resolvedMappingPath' to exist"
            }

            $resolvedMapping = Get-Content -LiteralPath $resolvedMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $expectedDataset = 'datasets/Lenovo.DE/collector-out/de-prod-01/target_de-prod-01/systems.json'
            $actualDataset = [string]$resolvedMapping.mappings[0].dataset
            if ($actualDataset -ne $expectedDataset) {
                throw "Expected resolved dataset '$expectedDataset', got '$actualDataset'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'resolves Lenovo.DE datasets from single-target-per-folder layout' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleRoot = Join-Path $repoRoot 'bundle/417f4663-0922-423b-92a9-34d4e33ecd0e'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-single-layout-test-" + [guid]::NewGuid().ToString())
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

            $variant = @(@($report.runs)[0].variants)[0]
            $expectedTargetRoot = Join-Path $bundleRoot 'datasets/Lenovo.DE/collector-out/de-prod-01/target_de-prod-01'
            if ($variant.selectedTarget -ne 'target_de-prod-01') {
                throw "Expected selected target 'target_de-prod-01', got '$($variant.selectedTarget)'"
            }
            if ($variant.selectedTargetRoot -ne $expectedTargetRoot) {
                throw "Expected selectedTargetRoot '$expectedTargetRoot', got '$($variant.selectedTargetRoot)'"
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
        $sourceBundleRoot = Join-Path $repoRoot 'bundle/417f4663-0922-423b-92a9-34d4e33ecd0e'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-multibundle-test-" + [guid]::NewGuid().ToString())
        $bundleStagingRoot = Join-Path $tempRoot 'bundle-staging'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            New-Item -ItemType Directory -Path $bundleStagingRoot -Force | Out-Null
            Copy-Item -LiteralPath $sourceBundleRoot -Destination (Join-Path $bundleStagingRoot 'bundle-a') -Recurse -Force
            Copy-Item -LiteralPath $sourceBundleRoot -Destination (Join-Path $bundleStagingRoot 'bundle-b') -Recurse -Force

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
