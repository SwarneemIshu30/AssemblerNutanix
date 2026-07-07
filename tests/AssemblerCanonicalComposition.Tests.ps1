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

    It 'renders a canonical Lenovo XCC fixture with first-class projections and no raw JSON fallback' {
        $fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-xcc'
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.XCC/XCC-SDT-Collector.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts') -OutputType text
        $json | Should -Not -BeNullOrEmpty
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        @($report.runs[0].issues | Where-Object { $_ }).Count | Should -Be 0

        $rendered = Get-Content -LiteralPath $report.runs[0].outputPath -Raw -Encoding UTF8
        $rendered | Should -Match 'DIMM 2\s+32768\s+DDR4\s+Disabled'
        $rendered | Should -Match 'No FC adapters discovered'
        $rendered | Should -Match 'SE350 Embedded Switch-Board Evidence'
        $rendered | Should -Match '08:3A:88:0C:44:74'
        $rendered | Should -Match 'network-adapter-port'
        $rendered | Should -Match 'XCC Interface'
        $rendered | Should -Not -Match 'Manager Ethernet Interface'
        $rendered | Should -Not -Match '<<SDT:'
        $rendered | Should -Not -Match '"schema_version"'
        $rendered | Should -Not -Match '"items"'

        $hostEthernet = Get-Content -LiteralPath (Join-Path $script:outputRoot '.render-plan/datasets/Lenovo.XCC/host-ethernet-ports.json') -Raw | ConvertFrom-Json -AsHashtable
        $hostEthernet.item_count | Should -BeGreaterThan 0
        $nic2 = @($hostEthernet.items | Where-Object { $_.macAddress -eq '08:3A:88:0C:44:74' })[0]
        $nic2 | Should -Not -BeNullOrEmpty
        $nic2.physicalPortPath | Should -Be '/redfish/v1/Chassis/1/NetworkAdapters/ob-2/Ports/2'
        $nic2.networkPortPath | Should -Be '/redfish/v1/Chassis/1/NetworkAdapters/ob-2/NetworkPorts/2'

        $hostFc = Get-Content -LiteralPath (Join-Path $script:outputRoot '.render-plan/datasets/Lenovo.XCC/host-fc-ports.json') -Raw | ConvertFrom-Json -AsHashtable
        $hostFc.item_count | Should -Be 0
    }

    It 'renders the Lenovo XCC DOCX skeleton from the same contract mappings' {
        $fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-xcc'
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.XCC/XCC-SDT-Collector.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts') -OutputType docx -DocxMatchMode literal-token
        $json | Should -Not -BeNullOrEmpty
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        @($report.runs | Where-Object { $_.entryId -eq 'lenovo-xcc-collector-docx' }).Count | Should -Be 1

        $docxRun = @($report.runs | Where-Object { $_.entryId -eq 'lenovo-xcc-collector-docx' })[0]
        $docxRun.status | Should -Be 'OK'
        Test-Path -LiteralPath $docxRun.outputPath -PathType Leaf | Should -BeTrue

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$docxRun.outputPath)
        try {
            $entry = $zip.GetEntry('word/document.xml')
            $entry | Should -Not -BeNullOrEmpty
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                $documentXml = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $zip.Dispose()
        }

        { [xml]$null = $documentXml } | Should -Not -Throw
        $documentXml | Should -Match 'Disabled'
        $documentXml | Should -Match 'No FC adapters discovered'
        $documentXml | Should -Match 'SE350 Embedded Switch-Board Evidence'
        $documentXml | Should -Match '08:3A:88:0C:44:74'
        $documentXml | Should -Match 'network-adapter-port'
        $documentXml | Should -Match 'XCC Interface'
        $documentXml | Should -Not -Match 'Manager Ethernet Interface'
        $documentXml | Should -Not -Match '&lt;&lt;SDT:'
        $documentXml | Should -Not -Match '"schema_version"'
        $documentXml | Should -Not -Match '"items"'
    }

    It 'renders the Lenovo XCC end-document skeleton without diagnostic-only sections' {
        $fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-xcc'
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.XCC/XCC-SDT-Collector.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts') -OutputType text -EntryId lenovo-xcc-end-document
        $json | Should -Not -BeNullOrEmpty
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        @($report.runs[0].issues | Where-Object { $_ }).Count | Should -Be 0

        $rendered = Get-Content -LiteralPath $report.runs[0].outputPath -Raw -Encoding UTF8
        $rendered | Should -Match 'Lenovo XCC As-Built Summary'
        $rendered | Should -Match 'Vital Product Data'
        $rendered | Should -Match 'XCC-7D1X-J301DX1K'
        $vpdBlock = [regex]::Match($rendered, '(?s)Vital Product Data.*?Firmware Summary').Value
        $vpdBlock | Should -Match '\r?\nLab\r?\n\r?\nComponent\s+Model Type\s+S/N\s+Name\s+Description\s+Rack Location'
        $vpdBlock | Should -Not -Match 'Site\s+Component'
        $rendered | Should -Match 'Firmware Summary'
        $rendered | Should -Match 'Hardware Summary'
        $rendered | Should -Match 'Memory Exceptions'
        $rendered | Should -Match 'DIMM 2\s+32768\s+DDR4\s+Disabled'
        $rendered | Should -Match 'Management Ethernet Ports'
        $rendered | Should -Match 'Host Ethernet Ports'
        $rendered | Should -Match 'No FC adapters discovered'
        $rendered | Should -Not -Match 'Firmware:DEVICE'
        $rendered | Should -Not -Match 'Firmware:DISK'
        $rendered | Should -Not -Match 'Collection Status'
        $rendered | Should -Not -Match 'SE350 Embedded Switch-Board Evidence'
        $rendered | Should -Not -Match 'Appendix: Redfish Port Evidence'
        $rendered | Should -Not -Match '/redfish/v1/'
        $rendered | Should -Not -Match 'VirtualMedia'
        $rendered | Should -Not -Match 'NetworkDeviceFunctions'
        $rendered | Should -Not -Match 'network-adapter-port'
        $rendered | Should -Not -Match '<<SDT:'
        $rendered | Should -Not -Match '"schema_version"'
        $rendered | Should -Not -Match '"items"'
    }

    It 'renders six Lenovo XCC targets with site-grouped end-document VPD and concise sections' {
        $fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-xcc-six-targets'
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.XCC/XCC-SDT-Collector.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts') -OutputType text -EntryId lenovo-xcc-end-document
        $json | Should -Not -BeNullOrEmpty
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        @($report.runs[0].issues | Where-Object { $_ }).Count | Should -Be 0

        $rendered = Get-Content -LiteralPath $report.runs[0].outputPath -Raw -Encoding UTF8
        $vpdBlock = [regex]::Match($rendered, '(?s)Vital Product Data.*?Firmware Summary').Value
        $vpdBlock | Should -Match '(?s)HO Primary.*VXNODE01-XCC.*VXNODE02-XCC.*VXNODE03-XCC.*DR Secondary.*VXNODE04-XCC.*VXNODE05-XCC.*VXNODE06-XCC'
        $vpdBlock | Should -Match '\r?\nHO Primary\r?\n\r?\nComponent\s+Model Type\s+S/N\s+Name\s+Description\s+Rack Location'
        $vpdBlock | Should -Match '\r?\nDR Secondary\r?\n\r?\nComponent\s+Model Type\s+S/N\s+Name\s+Description\s+Rack Location'
        $vpdBlock | Should -Not -Match 'Site\s+Component'
        $rendered | Should -Match 'Disabled'
        $rendered | Should -Match 'Management Ethernet Ports'
        $rendered | Should -Match 'Host Ethernet Ports'
        $rendered | Should -Match 'No FC adapters discovered'
        $rendered | Should -Not -Match 'Collection Status'
        $rendered | Should -Not -Match 'SE350 Embedded Switch-Board Evidence'
        $rendered | Should -Not -Match 'VirtualMedia'
        $rendered | Should -Not -Match 'network-adapter-port'
        $rendered | Should -Not -Match '<<SDT:'

        $compiledVpd = Get-Content -LiteralPath (Join-Path $script:outputRoot '.render-plan/datasets/Lenovo.XCC/document-vital-product-data.json') -Raw | ConvertFrom-Json -AsHashtable
        $firstVpdItem = @($compiledVpd.items | Where-Object { [string]$_['targetKey'] -eq 'srv01-xcc' })[0]
        $firstVpdItem.Contains('site') | Should -BeFalse
        [string]$firstVpdItem['_assembler']['location']['site'] | Should -Be 'HO Primary'
        [string]$firstVpdItem['_assembler']['location']['rack'] | Should -Be 'R01-U10'
    }

    It 'renders XCC VPD under Unassigned Site when neither dataset nor plan carries site metadata' {
        $sourceFixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-xcc'
        $fixtureRoot = Join-Path $script:tempRoot 'canonical-xcc-no-site'
        Copy-Item -LiteralPath $sourceFixtureRoot -Destination $fixtureRoot -Recurse -Force

        $planPath = Join-Path $fixtureRoot 'config/solution.plan.json'
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
        foreach ($target in @($plan.targets)) {
            foreach ($propertyName in @('location','tags','params')) {
                if ($target.PSObject.Properties.Name -contains $propertyName) {
                    $target.PSObject.Properties.Remove($propertyName)
                }
            }
        }
        $plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $planPath -Encoding UTF8

        $vpdPath = Join-Path $fixtureRoot 'datasets/Lenovo.XCC/core/srv01-xcc/document-vital-product-data.json'
        $vpd = Get-Content -LiteralPath $vpdPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
        foreach ($item in @($vpd.items)) {
            foreach ($propertyName in @('site','siteSort','rack','rackLocation')) {
                if ($item.PSObject.Properties.Name -contains $propertyName) {
                    $item.PSObject.Properties.Remove($propertyName)
                }
            }
        }
        $vpd | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $vpdPath -Encoding UTF8

        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.XCC/XCC-SDT-Collector.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts') -OutputType text -EntryId lenovo-xcc-end-document
        $json | Should -Not -BeNullOrEmpty
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        @($report.runs[0].issues | Where-Object { $_ }).Count | Should -Be 0

        $rendered = Get-Content -LiteralPath $report.runs[0].outputPath -Raw -Encoding UTF8
        $vpdBlock = [regex]::Match($rendered, '(?s)Vital Product Data.*?Firmware Summary').Value
        $vpdBlock | Should -Match '\r?\nUnassigned Site\r?\n\r?\nComponent\s+Model Type\s+S/N\s+Name\s+Description\s+Rack Location'
        $vpdBlock | Should -Not -Match '\r?\nLab\r?\n'
    }

    It 'renders six-target Lenovo XCC grouped VPD rows as DOCX full-width section rows' {
        $fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/canonical-xcc-six-targets'
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.XCC/XCC-SDT-Collector.catalog.json'
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
        $json = & $scriptPath -BundleRoot $fixtureRoot -CatalogPath $catalogPath -OutputRoot $script:outputRoot -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts') -OutputType docx -EntryId lenovo-xcc-end-document-docx -DocxMatchMode literal-token
        $json | Should -Not -BeNullOrEmpty
        $report = $json | ConvertFrom-Json -AsHashtable
        $report.status | Should -Be 'OK'
        @($report.runs[0].issues | Where-Object { $_ }).Count | Should -Be 0
        Test-Path -LiteralPath $report.runs[0].outputPath -PathType Leaf | Should -BeTrue

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$report.runs[0].outputPath)
        try {
            $entry = $zip.GetEntry('word/document.xml')
            $entry | Should -Not -BeNullOrEmpty
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                $documentXml = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $zip.Dispose()
        }

        { [xml]$null = $documentXml } | Should -Not -Throw
        $vpdTableXml = [regex]::Match($documentXml, '(?s)<w:tbl>.*?HO Primary.*?DR Secondary.*?</w:tbl>').Value
        $vpdTableXml | Should -Not -BeNullOrEmpty
        $vpdTableXml | Should -Match '<w:gridSpan w:val="6" />.*?<w:shd [^>]*w:fill="E5E7EB"[^>]*/>.*?<w:b />.*?<w:t[^>]*>HO Primary</w:t>'
        $vpdTableXml | Should -Match '<w:gridSpan w:val="6" />.*?<w:shd [^>]*w:fill="E5E7EB"[^>]*/>.*?<w:b />.*?<w:t[^>]*>DR Secondary</w:t>'
        $vpdTableXml | Should -Match '(?s)HO Primary.*VXNODE01-XCC.*VXNODE02-XCC.*VXNODE03-XCC.*DR Secondary.*VXNODE04-XCC.*VXNODE05-XCC.*VXNODE06-XCC'
        $vpdTableXml | Should -Not -Match '<w:t>Site</w:t>'
        $documentXml | Should -Match 'No FC adapters discovered'
        $documentXml | Should -Not -Match '&lt;&lt;SDT:'
    }
}
