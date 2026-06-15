BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'scripts/internal/AssemblerDatasetCatalog.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'scripts/internal/AssemblerComposition.psm1') -Force
}

Describe 'Canonical Direct-v1 dataset catalog and composition' {
    BeforeEach {
        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-canonical-" + [guid]::NewGuid().ToString('N'))
        $script:bundleRoot = Join-Path $script:tempRoot 'bundle'
        $script:outputRoot = Join-Path $script:tempRoot 'out'
        New-Item -ItemType Directory -Path (Join-Path $script:bundleRoot 'config') -Force | Out-Null

        [ordered]@{
            schemaVersion = 2
            solutionId = 'solution-a'
            targets = @(
                [ordered]@{ techId = 'Test.Tech'; kind = 'Array'; key = 'array-a'; displayName = 'Array A'; endpoints = @{ mgmt = 'a' }; tags = @{ site = 'dc1' } },
                [ordered]@{ techId = 'Test.Tech'; kind = 'Array'; key = 'array-b'; displayName = 'Array B'; endpoints = @{ mgmt = 'b' }; tags = @{ site = 'dc1' } }
            )
            targetGroups = @([ordered]@{ kind = 'Pair'; key = 'pair-a'; displayName = 'Pair A'; members = @('array-a','array-b') })
            collectors = @([ordered]@{ techId = 'Test.Tech'; modulePath = 'test'; targetKeys = @('array-a','array-b') })
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:bundleRoot 'config/solution.plan.json') -Encoding UTF8
        [ordered]@{
            schemaVersion = 1
            collectedUtc = '2026-06-15T00:00:00Z'
            objects = @(
                [ordered]@{ techId = 'Test.Tech'; kind = 'Array'; key = 'array-a'; displayName = 'Array A' },
                [ordered]@{ techId = 'Test.Tech'; kind = 'Array'; key = 'array-b'; displayName = 'Array B' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:bundleRoot 'objectIndex.json') -Encoding UTF8
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'classifies scopes and aggregates selected target datasets with provenance' {
        $paths = @(
            'datasets/Test.Tech/core/array-a/systems.json',
            'datasets/Test.Tech/core/array-b/systems.json',
            'datasets/Test.Tech/relationships/pair-a/relationships.json'
        )
        foreach ($relativePath in $paths) {
            $fullPath = Join-Path $script:bundleRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
            $datasetKey = [IO.Path]::GetFileNameWithoutExtension($fullPath)
            $objectKey = Split-Path -Leaf (Split-Path -Parent $fullPath)
            [ordered]@{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ tech_id = 'Test.Tech' }
                source = @{ target_key = $objectKey }
                dataset = @{ key = $datasetKey; schema_path = "tech/Test.Tech/dataset/$datasetKey.schema.json" }
                item_count = 1
                items = @([ordered]@{ id = "$objectKey-$datasetKey" })
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fullPath -Encoding UTF8
        }
        [ordered]@{
            schemaVersion = 1
            bundleId = 'bundle-a'
            createdUtc = '2026-06-15T00:00:00Z'
            files = @($paths | ForEach-Object { [ordered]@{ path = $_; bytes = 1; sha256 = 'x' } })
            results = @()
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:bundleRoot 'manifest.json') -Encoding UTF8

        $catalog = New-AssemblerDatasetCatalog -BundleRoot $script:bundleRoot
        @($catalog.entries | Where-Object scope -eq 'target').Count | Should -Be 2
        @($catalog.entries | Where-Object scope -eq 'targetGroup').Count | Should -Be 1

        $templateCatalog = [ordered]@{
            entries = @([ordered]@{ id = 'test-entry'; techId = 'Test.Tech'; enabled = $true; priority = 10 })
        }
        $composition = New-AssemblerDefaultCompositionMap -DatasetCatalog $catalog -TemplateCatalog $templateCatalog -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')
        @($composition.objects).Count | Should -Be 3

        $mappingPath = Join-Path $script:tempRoot 'mapping.json'
        [ordered]@{
            schema = 'mapping.dataset-to-sdt'
            schemaVersion = 2
            techId = 'Test.Tech'
            compatibility = @{ contracts = @{ version = '2' } }
            mappings = @([ordered]@{ dataset = 'systems'; sdtTag = 'TEST.Systems'; required = $true; selectors = @('items') })
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $mappingPath -Encoding UTF8

        $compiledPath = New-AssemblerCompiledMapping -DatasetCatalog $catalog -CompositionMap $composition -MappingPath $mappingPath -EntryId 'test-entry' -OutputRoot $script:outputRoot
        $compiled = Get-Content -LiteralPath $compiledPath -Raw | ConvertFrom-Json -AsHashtable
        $compiled.mappings[0].dataset | Should -Be 'systems'
        [IO.Path]::IsPathRooted([string]$compiled.mappings[0].resolvedDataset) | Should -BeTrue
        $aggregated = Get-Content -LiteralPath ([string]$compiled.mappings[0].resolvedDataset) -Raw | ConvertFrom-Json -AsHashtable
        $aggregated.item_count | Should -Be 2
        @($aggregated.items._assembler.objectKey | Sort-Object) | Should -Be @('array-a','array-b')
        @($aggregated.items._assembler.tags.site | Sort-Object -Unique) | Should -Be @('dc1')
    }

    It 'rejects manifest-listed legacy collector paths' {
        $legacyPath = 'datasets/Test.Tech/collector-out/run/target_array-a/systems.json'
        $fullPath = Join-Path $script:bundleRoot $legacyPath
        New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
        '{}' | Set-Content -LiteralPath $fullPath -Encoding UTF8
        [ordered]@{
            schemaVersion = 1
            bundleId = 'bundle-a'
            createdUtc = '2026-06-15T00:00:00Z'
            files = @([ordered]@{ path = $legacyPath; bytes = 2; sha256 = 'x' })
            results = @()
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:bundleRoot 'manifest.json') -Encoding UTF8

        { New-AssemblerDatasetCatalog -BundleRoot $script:bundleRoot } | Should -Throw '*ASB-ASM-CATALOG-LEGACY-LAYOUT*'
    }

    It 'renders a canonical multi-target DE fixture through bundle orchestration' {
        $fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-de'
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')
        $LASTEXITCODE | Should -Be 0
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        Test-Path -LiteralPath $report.compositionMapPath -PathType Leaf | Should -BeTrue
        $rendered = Get-Content -LiteralPath $report.runs[0].outputPath -Raw -Encoding UTF8
        $rendered | Should -Match 'System Name: DE Array A'
        $compiledDataset = Get-Content -LiteralPath (Join-Path $script:outputRoot '.render-plan/datasets/Lenovo.DE/systems.json') -Raw | ConvertFrom-Json -AsHashtable
        $compiledDataset.item_count | Should -Be 2
    }
}
