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

    It 'catalogs canonical NetApp and Prism envelopes without treating evidence as datasets' {
        [ordered]@{
            schemaVersion = 2
            solutionId = 'collector-solution'
            targets = @(
                [ordered]@{ techId = 'NetApp.ONTAP'; kind = 'NetApp.ONTAP'; key = 'ontap-a'; displayName = 'ONTAP A' },
                [ordered]@{ techId = 'Nutanix.Prism'; kind = 'Nutanix.Prism'; key = 'prism-a'; displayName = 'Prism A' }
            )
            collectors = @(
                [ordered]@{ techId = 'NetApp.ONTAP'; modulePath = 'netapp'; targetKeys = @('ontap-a') },
                [ordered]@{ techId = 'Nutanix.Prism'; modulePath = 'prism'; targetKeys = @('prism-a') }
            )
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:bundleRoot 'config/solution.plan.json') -Encoding UTF8

        $datasets = @(
            [ordered]@{
                techId = 'NetApp.ONTAP'
                module = 'LNV.AsBuiltDoc.NetApp.ONTAP'
                entryPoint = 'Invoke-LnvAsBuiltDoc.NetApp.ONTAP'
                domain = 'core'
                objectKey = 'ontap-a'
                dataset = 'cluster'
            },
            [ordered]@{
                techId = 'Nutanix.Prism'
                module = 'LNV.AsBuiltDoc.Nutanix.Prism'
                entryPoint = 'Invoke-LnvAsBuiltDoc.Nutanix.Prism'
                domain = 'cluster'
                objectKey = 'prism-a'
                dataset = 'cluster'
            }
        )
        $manifestPaths = @()
        foreach ($entry in $datasets) {
            $relativePath = "datasets/$($entry.techId)/$($entry.domain)/$($entry.objectKey)/$($entry.dataset).json"
            $fullPath = Join-Path $script:bundleRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
            [ordered]@{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{
                    tech_id = $entry.techId
                    module = $entry.module
                    entry_point = $entry.entryPoint
                }
                source = @{
                    target_key = $entry.objectKey
                    file = $relativePath
                }
                dataset = $entry.dataset
                item_count = 1
                items = @([ordered]@{ name = $entry.objectKey })
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fullPath -Encoding UTF8
            $manifestPaths += $relativePath
        }

        $evidencePath = 'evidence/Nutanix.Prism/prism-a/PrismElement.v2/cluster.raw.json'
        $evidenceFile = Join-Path $script:bundleRoot $evidencePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $evidenceFile) -Force | Out-Null
        '{}' | Set-Content -LiteralPath $evidenceFile -Encoding UTF8
        $manifestPaths += $evidencePath

        [ordered]@{
            schemaVersion = 1
            bundleId = 'bundle-collectors'
            createdUtc = '2026-06-15T00:00:00Z'
            files = @($manifestPaths | ForEach-Object { [ordered]@{ path = $_; bytes = 1; sha256 = 'x' } })
            results = @()
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:bundleRoot 'manifest.json') -Encoding UTF8

        $catalog = New-AssemblerDatasetCatalog -BundleRoot $script:bundleRoot
        @($catalog.entries).Count | Should -Be 2
        @($catalog.entries.techId | Sort-Object) | Should -Be @('NetApp.ONTAP','Nutanix.Prism')
        @($catalog.entries.path | Where-Object { $_ -like 'evidence/*' }).Count | Should -Be 0
    }

    It 'filters identical logical dataset keys by scope and domain' {
        $paths = @(
            'datasets/Test.Tech/core/array-a/relationships.json',
            'datasets/Test.Tech/relationships/pair-a/relationships.json'
        )
        foreach ($relativePath in $paths) {
            $fullPath = Join-Path $script:bundleRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
            $objectKey = Split-Path -Leaf (Split-Path -Parent $fullPath)
            [ordered]@{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ tech_id = 'Test.Tech' }
                source = @{ target_key = $objectKey }
                dataset = @{ key = 'relationships'; schema_path = 'tech/Test.Tech/dataset/relationships.schema.json' }
                item_count = 1
                items = @([ordered]@{ id = $objectKey })
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fullPath -Encoding UTF8
        }
        [ordered]@{
            schemaVersion = 1
            bundleId = 'bundle-filter'
            createdUtc = '2026-06-15T00:00:00Z'
            files = @($paths | ForEach-Object { [ordered]@{ path = $_; bytes = 1; sha256 = 'x' } })
            results = @()
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:bundleRoot 'manifest.json') -Encoding UTF8

        $catalog = New-AssemblerDatasetCatalog -BundleRoot $script:bundleRoot
        $composition = New-AssemblerDefaultCompositionMap -DatasetCatalog $catalog -TemplateCatalog @{
            entries = @([ordered]@{ id = 'test-entry'; techId = 'Test.Tech'; enabled = $true })
        } -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')
        $mappingPath = Join-Path $script:tempRoot 'mapping-filter.json'
        [ordered]@{
            schema = 'mapping.dataset-to-sdt'
            schemaVersion = 2
            techId = 'Test.Tech'
            compatibility = @{ contracts = @{ version = '2' } }
            mappings = @(
                [ordered]@{ dataset = 'relationships'; scope = 'target'; domain = 'core'; sdtTag = 'TEST.TargetRelationships'; required = $true },
                [ordered]@{ dataset = 'relationships'; scope = 'targetGroup'; domain = 'relationships'; sdtTag = 'TEST.GroupRelationships'; required = $true }
            )
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $mappingPath -Encoding UTF8

        $compiledPath = New-AssemblerCompiledMapping -DatasetCatalog $catalog -CompositionMap $composition -MappingPath $mappingPath -EntryId 'filter-entry' -OutputRoot $script:outputRoot
        $compiled = Get-Content -LiteralPath $compiledPath -Raw | ConvertFrom-Json -AsHashtable
        $targetDataset = Get-Content -LiteralPath ([string]$compiled.mappings[0].resolvedDataset) -Raw | ConvertFrom-Json -AsHashtable
        $groupDataset = Get-Content -LiteralPath ([string]$compiled.mappings[1].resolvedDataset) -Raw | ConvertFrom-Json -AsHashtable
        @($targetDataset.items.id) | Should -Be @('array-a')
        @($groupDataset.items.id) | Should -Be @('pair-a')
    }

    It 'renders a canonical multi-target DE fixture through bundle orchestration' {
        $fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-de'
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')
        $json | Should -Not -BeNullOrEmpty
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        Test-Path -LiteralPath $report.compositionMapPath -PathType Leaf | Should -BeTrue
        $rendered = Get-Content -LiteralPath $report.runs[0].outputPath -Raw -Encoding UTF8
        $rendered | Should -Match 'System Name: DE Array A'
        $compiledDataset = Get-Content -LiteralPath (Join-Path $script:outputRoot '.render-plan/datasets/Lenovo.DE/systems.json') -Raw | ConvertFrom-Json -AsHashtable
        $compiledDataset.item_count | Should -Be 2
    }
}
