BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:successfulBundleRoot = Join-Path $script:repoRoot 'bundle/b0c8360d-800e-4cab-a84f-d1bc53c8646f'
    Import-Module (Join-Path $script:repoRoot 'scripts/internal/AssemblerSchemaValidation.psm1') -Force
}

Describe 'Invoke-AssemblerBundleRender orchestration' {
    It 'runs renderer per catalog entry for selected tech' {
        $repoRoot = $script:repoRoot
        $bundleRoot = $script:successfulBundleRoot
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

            $jsonText = ($json |
                ForEach-Object { ([string]$_ -replace "`e\[[0-9;]*m", '') } |
                Where-Object { $_ -notmatch '^WARNING: Resulting JSON is truncated' }) -join [Environment]::NewLine
            $report = $jsonText | ConvertFrom-Json -AsHashtable

            $bundleReportPath = Join-Path $outputRoot 'assembler-bundle-render-report.json'
            if (-not (Test-Path -LiteralPath $bundleReportPath -PathType Leaf)) {
                throw 'Expected bundle render report file'
            }

            $contractsRoot = Join-Path $repoRoot '.deps/contracts'
            $bundleSchemaPath = Join-Path $contractsRoot 'standards/assembler/assembler.bundle-render-report.schema.v1.json'
            $bundleReportValidation = Test-AssemblerSchemaFile -DocumentPath $bundleReportPath -SchemaPath $bundleSchemaPath
            if (-not $bundleReportValidation.isValid) {
                throw "Expected bundle report to validate against dedicated schema, got '$($bundleReportValidation.message)'"
            }

            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }
            foreach ($requiredProperty in @('bundleRoot', 'catalogPath', 'outputRoot', 'runs')) {
                if (-not $report.ContainsKey($requiredProperty)) {
                    throw "Expected report to include '$requiredProperty'"
                }
            }
            $schemaIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-AGGREGATEREPORT-INVALID' })
            if ($schemaIssues.Count -gt 0) {
                throw "Did not expect aggregate report schema issues, got '$($schemaIssues[0].message)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'selects deterministic target even when run_summary mtimes differ' {
        $repoRoot = $script:repoRoot
        $sourceBundleRoot = $script:successfulBundleRoot
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
        $repoRoot = $script:repoRoot
        $bundleRoot = $script:successfulBundleRoot
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

            $resolvedMappingPath = [string](Get-ChildItem -LiteralPath (Join-Path $outputRoot '.resolved-mappings') -Filter '*.resolved.json' |
                Sort-Object Name |
                Select-Object -First 1 -ExpandProperty FullName)
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

    It 'renders one variant per discovered system folder when mapping uses __SYSTEM__' {
        $repoRoot = $script:repoRoot
        $sourceBundleRoot = $script:successfulBundleRoot
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-system-variants-test-" + [guid]::NewGuid().ToString())
        $bundleRoot = Join-Path $tempRoot 'bundle-copy'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            Copy-Item -LiteralPath $sourceBundleRoot -Destination $bundleRoot -Recurse -Force

            $selectedTargetRoot = Join-Path $bundleRoot 'datasets/Lenovo.DE/collector-out/de-prod-01/target_de-prod-01'
            $sourceSystemRoot = Join-Path $selectedTargetRoot 'system_1_DE4200_Rack4'
            $addedSystemRoot = Join-Path $selectedTargetRoot 'system_2_DE4200_Rack4'
            Copy-Item -LiteralPath $sourceSystemRoot -Destination $addedSystemRoot -Recurse -Force

            $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -TechId 'Lenovo.DE'
            if ($LASTEXITCODE -ne 0) {
                throw "Expected exit code 0, got $LASTEXITCODE"
            }

            $jsonText = ($json |
                ForEach-Object { ([string]$_ -replace "`e\[[0-9;]*m", '') } |
                Where-Object { $_ -notmatch '^WARNING: Resulting JSON is truncated' }) -join [Environment]::NewLine
            $report = $jsonText | ConvertFrom-Json -AsHashtable
            if (-not $report.ContainsKey('runs') -or @($report.runs).Count -lt 1) {
                throw 'Expected at least one run in bundle report'
            }

            $run = @($report.runs)[0]
            $variantNames = @(@($run.variants) | ForEach-Object { [string]$_.variant } | Sort-Object)
            $expectedVariants = @('system_1_DE4200_Rack4', 'system_2_DE4200_Rack4')
            if ($variantNames.Count -ne $expectedVariants.Count) {
                throw "Expected $($expectedVariants.Count) variants, got $($variantNames.Count)"
            }
            foreach ($expectedVariant in $expectedVariants) {
                if ($variantNames -notcontains $expectedVariant) {
                    throw "Expected variant '$expectedVariant' in output variants: $($variantNames -join ', ')"
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'resolves Lenovo.DE datasets from single-target-per-folder layout' {
        $repoRoot = $script:repoRoot
        $bundleRoot = $script:successfulBundleRoot
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

    It 'classifies bundle entry failures as derived wrapper errors that point to nested renderer issues' {
        $repoRoot = $script:repoRoot
        $sourceBundleRoot = $script:successfulBundleRoot
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-wrapper-issue-test-" + [guid]::NewGuid().ToString())
        $bundleRoot = Join-Path $tempRoot 'bundle-copy'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            Copy-Item -LiteralPath $sourceBundleRoot -Destination $bundleRoot -Recurse -Force
            Get-ChildItem -Path $bundleRoot -Recurse -Filter 'systems.json' | Remove-Item -Force

            $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -TechId 'Lenovo.DE'
            if ($LASTEXITCODE -eq 0) {
                throw 'Expected non-zero exit code for known failing Lenovo.DE collector render'
            }

            $jsonText = ($json |
                ForEach-Object { ([string]$_ -replace "`e\[[0-9;]*m", '') } |
                Where-Object { $_ -notmatch '^WARNING: Resulting JSON is truncated' }) -join [Environment]::NewLine
            $report = $jsonText | ConvertFrom-Json -AsHashtable
            $bundleWrapperIssue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-BUNDLE-ENTRY-FAILED' } | Select-Object -First 1)
            if (@($bundleWrapperIssue).Count -eq 0) {
                throw 'Expected ASB-ASM-BUNDLE-ENTRY-FAILED issue in aggregate report'
            }

            $issue = $bundleWrapperIssue[0]
            if ([string]$issue.message -notmatch 'wrapper/aggregation error') {
                throw "Expected wrapper/aggregation wording, got '$($issue.message)'"
            }
            if ([string]$issue.message -notmatch 'nested renderer report') {
                throw "Expected nested renderer report guidance, got '$($issue.message)'"
            }
            if ([string]$issue.message -notmatch 'issues array') {
                throw "Expected issues array guidance, got '$($issue.message)'"
            }

            $variant = @(@($report.runs)[0].variants)[0]
            if ([string]$issue.path -ne [string]$variant.reportPath) {
                throw "Expected bundle wrapper path '$($variant.reportPath)', got '$($issue.path)'"
            }
            if ($null -eq $variant.rendererOutput -or -not $variant.rendererOutput.ContainsKey('issues') -or @($variant.rendererOutput.issues).Count -eq 0) {
                throw 'Expected nested renderer report issues to be present for derived wrapper error'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails fast when BundleRoot staging directory contains multiple bundles' {
        $repoRoot = $script:repoRoot
        $sourceBundleRoot = $script:successfulBundleRoot
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

    It 'forwards annotate-resolved-tags switch to text SDT render entries' {
        $repoRoot = $script:repoRoot
        $bundleRoot = $script:successfulBundleRoot
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-annotate-test-" + [guid]::NewGuid().ToString())
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -OutputType 'text' -AnnotateResolvedTags
            if ($LASTEXITCODE -ne 0) {
                throw "Expected exit code 0, got $LASTEXITCODE"
            }

            $report = $json | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }

            $run = @($report.runs)[0]
            $renderedPath = [string]$run.outputPath
            if (-not (Test-Path -LiteralPath $renderedPath -PathType Leaf)) {
                throw "Expected rendered output path '$renderedPath' to exist"
            }

            $renderedText = Get-Content -LiteralPath $renderedPath -Raw -Encoding UTF8
            if ($renderedText -notmatch '\[SDT-TAG:') {
                throw 'Expected rendered text to include [SDT-TAG:*] annotation markers when -AnnotateResolvedTags is forwarded'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

}
