BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:canonicalBundleRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-de'
    $script:catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'
    $script:pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
}

Describe 'Invoke-AssemblerBundleRender canonical orchestration' {
    BeforeEach {
        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-" + [guid]::NewGuid().ToString('N'))
        $script:outputRoot = Join-Path $script:tempRoot 'out'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'renders one composition from all canonical targets' {
        $json = & $script:pwshPath -NoLogo -NoProfile -File (Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1') `
            -BundleRoot $script:canonicalBundleRoot `
            -CatalogPath $script:catalogPath `
            -OutputRoot $script:outputRoot `
            -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')

        $LASTEXITCODE | Should -Be 0
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        @($report.runs).Count | Should -Be 1
        @($report.runs[0].variants).Count | Should -Be 1
        $report.runs[0].variants[0].targetSelectionReason | Should -Be 'composition-map'
        @($report.runs[0].variants[0].targetCandidates | Sort-Object) | Should -Be @('de-a','de-b')
        Test-Path -LiteralPath $report.compositionMapPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:outputRoot '.render-plan/mappings/lenovo-de-dummy.json') -PathType Leaf | Should -BeTrue
    }

    It 'fails with a canonical catalog issue when a required dataset file is absent' {
        $bundleCopy = Join-Path $script:tempRoot 'bundle'
        Copy-Item -LiteralPath $script:canonicalBundleRoot -Destination $bundleCopy -Recurse
        Remove-Item -LiteralPath (Join-Path $bundleCopy 'datasets/Lenovo.DE/core/de-a/systems.json') -Force

        $json = & $script:pwshPath -NoLogo -NoProfile -File (Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1') `
            -BundleRoot $bundleCopy `
            -CatalogPath $script:catalogPath `
            -OutputRoot $script:outputRoot `
            -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')

        $LASTEXITCODE | Should -Be 1
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'ERROR'
        @($report.issues | Where-Object message -Match 'ASB-ASM-CATALOG-FILE-MISSING').Count | Should -BeGreaterThan 0
    }

    It 'fails fast when a staging directory contains multiple valid bundles' {
        $stagingRoot = Join-Path $script:tempRoot 'staging'
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        Copy-Item -LiteralPath $script:canonicalBundleRoot -Destination (Join-Path $stagingRoot 'bundle-a') -Recurse
        Copy-Item -LiteralPath $script:canonicalBundleRoot -Destination (Join-Path $stagingRoot 'bundle-b') -Recurse

        $json = & $script:pwshPath -NoLogo -NoProfile -File (Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1') `
            -BundleRoot $stagingRoot `
            -CatalogPath $script:catalogPath `
            -OutputRoot $script:outputRoot `
            -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')

        $LASTEXITCODE | Should -Be 1
        $report = $json | ConvertFrom-Json -AsHashtable
        @($report.issues | Where-Object message -Match 'multiple bundle candidates').Count | Should -BeGreaterThan 0
    }

    It 'forwards annotate-resolved-tags to text rendering' {
        $json = & $script:pwshPath -NoLogo -NoProfile -File (Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1') `
            -BundleRoot $script:canonicalBundleRoot `
            -CatalogPath $script:catalogPath `
            -OutputRoot $script:outputRoot `
            -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts') `
            -OutputType text `
            -AnnotateResolvedTags

        $LASTEXITCODE | Should -Be 0
        $report = $json | ConvertFrom-Json -AsHashtable
        $rendered = Get-Content -LiteralPath $report.runs[0].outputPath -Raw -Encoding UTF8
        $rendered | Should -Match '\[SDT-TAG:DE_SYSTEM_NAME\]'
    }
}
