Describe 'Invoke-AssemblerBundleRender Nutanix Prism contract mapping' {
    It 'renders mapped Prism datasets and leaves evidence-only datasets unmapped' -Skip:(-not (Test-Path -LiteralPath 'C:\Github\LNV.AsBuiltDoc.Core\out\740aaaa8-b726-4a2c-8035-b9a1746d172a.lnvbundle.zip' -PathType Leaf)) {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleArchivePath = 'C:\Github\LNV.AsBuiltDoc.Core\out\740aaaa8-b726-4a2c-8035-b9a1746d172a.lnvbundle.zip'
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $prismMappingPath = Join-Path $repoRoot 'templates/skeletons/Nutanix.Prism/Prism-SDT-Collector.mapping.json'
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-prism-render-" + [guid]::NewGuid().ToString('N'))
        $bundleRoot = Join-Path $tempRoot 'bundle'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            Expand-Archive -LiteralPath $bundleArchivePath -DestinationPath $bundleRoot -Force

            function Write-PrismDatasetEnvelope {
                param(
                    [Parameter(Mandatory)][string] $TargetKey,
                    [Parameter(Mandatory)][string] $Dataset,
                    [Parameter(Mandatory)][object[]] $Items
                )

                $relativePath = "datasets/Nutanix.Prism/cluster/$TargetKey/$Dataset.json"
                $path = Join-Path $bundleRoot $relativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [ordered]@{
                    schema_version = 'lnv.collector.dataset.v1'
                    collector = [ordered]@{
                        vendor = 'LNV.AsBuiltDoc'
                        name = 'LNV.AsBuiltDoc.Nutanix.Prism'
                        version = '0.0.0-test'
                        tech_id = 'Nutanix.Prism'
                        module = 'LNV.AsBuiltDoc.Nutanix.Prism'
                        entry_point = 'Invoke-LnvAsBuiltDoc.Nutanix.Prism'
                    }
                    source = [ordered]@{
                        target_key = $TargetKey
                        file = $relativePath
                    }
                    dataset = $Dataset
                    collected_at_utc = '2026-06-22T00:00:00Z'
                    item_count = @($Items).Count
                    items = @($Items)
                } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8

                $manifestPath = Join-Path $bundleRoot 'manifest.json'
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                $files = @($manifest.files)
                if (($files | Where-Object { [string]$_.path -eq $relativePath }).Count -eq 0) {
                    $files += [ordered]@{
                        path = $relativePath
                        kind = 'dataset'
                        size = (Get-Item -LiteralPath $path).Length
                    }
                    $manifest.files = @($files | Sort-Object { [string]$_.path })
                    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
                }
            }

            foreach ($targetKey in @('pc01', 'pe-cluster-a')) {
                $targetName = if ($targetKey -eq 'pc01') { 'Prism Central 01' } else { 'Prism Element Cluster A' }
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'cluster_summary' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; clusterName = $targetName; status = 'Healthy'; version = 'test'; hostCount = 2; vmCount = 4; cvmCount = 2; networkCount = 3; storageContainerCount = 2; alertCount = 0 }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'host_inventory' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; hostName = 'ntnx-a-01'; serial = 'SERIAL01'; model = 'HX'; status = 'NORMAL'; maintenanceState = 'false'; hypervisor = 'AHV'; cpuCores = 32; memoryBytes = 274877906944; cvmIp = '10.0.0.11' },
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; hostName = 'ntnx-a-02'; serial = 'SERIAL02'; model = 'HX'; status = 'NORMAL'; maintenanceState = 'false'; hypervisor = 'AHV'; cpuCores = 32; memoryBytes = 274877906944; cvmIp = '10.0.0.12' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'host_network_interfaces' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; hostName = 'ntnx-a-01'; nicName = 'eth0'; macAddress = '00:11:22:33:44:55'; interfaceStatus = 'UP'; linkSpeedKbps = 10000000; mtuBytes = 9000; virtualSwitch = 'vs0'; switchInterface = 'Eth1/1'; switchManagementIp = '10.0.1.1' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'vm_inventory' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; vmName = 'app01'; powerState = 'ON'; hostName = 'ntnx-a-01'; cpuCount = 4; memoryBytes = 8589934592; ipAddresses = '10.10.10.20'; nicCount = 1; protectionType = 'PD'; protectionDomainName = 'PD-01' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'storage_container_inventory' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; containerName = 'default-container'; maxCapacityBytes = 10995116277760; replicationFactor = 2; compressionEnabled = $true; deduplicationEnabled = $false; shared = $true; internal = $false }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'storage_pool_inventory' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; storagePoolName = 'sp01'; capacityBytes = 21990232555520; diskCount = 8; markedForRemoval = $false }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'disk_inventory' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; hostName = 'ntnx-a-01'; diskName = 'disk-01'; serial = 'DISK01'; status = 'NORMAL'; sizeBytes = 1099511627776; storageTier = 'SSD' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'virtual_disk_inventory' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; vmName = 'app01'; virtualDiskName = 'scsi.0'; capacityBytes = 107374182400; containerName = 'default-container'; deviceBus = 'SCSI' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'volume_group_inventory' -Items @(
                    [ordered]@{ targetKey = $targetKey; targetName = $targetName; endpointKind = 'NutanixPrism'; volumeGroupName = 'vg01'; attachedTarget = 'app01'; usageType = 'USER'; sharingStatus = 'SHARED'; hidden = $false }
                )
            }

            $mapping = Get-Content -LiteralPath $prismMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            @($mapping.mappings).Count | Should -Be 32
            $documentMappings = @($mapping.mappings | Where-Object { [string]$_.scope -ne 'targetGroup' })
            $documentMappings.Count | Should -Be 31

            $catalogPath = Join-Path $tempRoot 'Prism-SDT-Collector.catalog.json'
            $runtimeMappingPath = Join-Path $tempRoot 'Prism-SDT-Collector.mapping.json'
            $templatePath = Join-Path $tempRoot 'Prism-SDT-Collector.template.txt'

            Copy-Item -LiteralPath $prismMappingPath -Destination $runtimeMappingPath
            $templateLines = [System.Collections.Generic.List[string]]::new()
            $templateLines.Add('Nutanix Prism SDT acceptance')
            $templateLines.Add('')
            foreach ($entry in $documentMappings) {
                $tag = [string]$entry.sdtTag
                $templateLines.Add("BEGIN:$tag")
                $templateLines.Add("<<SDT:$tag>>")
                $templateLines.Add("END:$tag")
                $templateLines.Add('')
            }
            Set-Content -LiteralPath $templatePath -Encoding UTF8 -Value $templateLines.ToArray()

            [ordered]@{
                schema = 'assembler.template-catalog'
                schemaVersion = 1
                displayName = 'Nutanix Prism acceptance catalog'
                entries = @(
                    [ordered]@{
                        id = 'nutanix-prism-acceptance'
                        techId = 'Nutanix.Prism'
                        displayName = 'Nutanix Prism Acceptance'
                        docType = 'acceptance'
                        mappingPath = 'Prism-SDT-Collector.mapping.json'
                        templatePath = 'Prism-SDT-Collector.template.txt'
                        outputFileName = 'Nutanix-Prism-Acceptance.txt'
                        enabled = $true
                        priority = 100
                    }
                )
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $catalogPath -Encoding UTF8

            $null = & $pwshPath -NoLogo -NoProfile -File (Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1') `
                -BundleRoot $bundleRoot `
                -CatalogPath $catalogPath `
                -OutputRoot $outputRoot `
                -ContractsRoot $contractsRoot `
                -TechId Nutanix.Prism `
                -OutputType text

            $LASTEXITCODE | Should -Be 0

            $bundleReportPath = Join-Path $outputRoot 'assembler-bundle-render-report.json'
            Test-Path -LiteralPath $bundleReportPath -PathType Leaf | Should -BeTrue
            $bundleReport = Get-Content -LiteralPath $bundleReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $bundleReport.status | Should -Be 'OK'
            @($bundleReport.issues).Count | Should -Be 0
            @($bundleReport.runs).Count | Should -Be 1
            $bundleReport.runs[0].status | Should -Be 'WARN'

            $renderReport = $bundleReport.runs[0].rendererOutput
            $renderReport.status | Should -Be 'PARTIAL'
            @($renderReport.issues).Count | Should -Be 1
            $renderReport.issues[0].code | Should -Be 'ASB-ASM-SDT-DATASET-MISSING'
            $renderReport.issues[0].severity | Should -Be 'WARN'
            $renderReport.issues[0].message | Should -Match "LNV\.Nutanix\.Prism\.Group\[GroupKey\]\.Tables\.Relationships"
            @($renderReport.matches).Count | Should -Be $documentMappings.Count

            $matchedTags = @($renderReport.matches | ForEach-Object { [string]$_.tag })
            foreach ($entry in $documentMappings) {
                $matchedTags | Should -Contain ([string]$entry.sdtTag)
            }

            $rendered = Get-Content -LiteralPath $bundleReport.runs[0].outputPath -Raw -Encoding UTF8
            $rendered | Should -Not -Match '<<SDT:'
            $rendered | Should -Match 'ntnx-a-01'
            $rendered | Should -Match 'eth0'
            $rendered | Should -Match 'default-container'
            foreach ($entry in $documentMappings) {
                $tag = [regex]::Escape([string]$entry.sdtTag)
                $sectionMatch = [regex]::Match($rendered, "(?s)BEGIN:$tag\s*(?<body>.*?)\s*END:$tag")
                $sectionMatch.Success | Should -BeTrue
                ([string]$sectionMatch.Groups['body'].Value).Trim().Length | Should -BeGreaterThan 0
            }

            $compiledMappingPath = Join-Path $outputRoot '.render-plan/mappings/nutanix-prism-acceptance.json'
            Test-Path -LiteralPath $compiledMappingPath -PathType Leaf | Should -BeTrue
            $compiledMapping = Get-Content -LiteralPath $compiledMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $compiledDatasets = @($compiledMapping.mappings | Where-Object { $_.ContainsKey('resolvedDataset') } | ForEach-Object { [string]$_.dataset } | Sort-Object -Unique)

            $evidenceOnlyDatasets = @(
                Get-ChildItem -LiteralPath (Join-Path $contractsRoot 'tech/Nutanix.Prism/dataset') -Filter '*.assembler.meta.json' -File |
                    ForEach-Object {
                        $metadata = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                        if ([string]$metadata.presentationKind -eq 'evidence' -or $metadata.documentFacing -eq $false) {
                            $_.BaseName -replace '\.assembler\.meta$', ''
                        }
                    } |
                    Sort-Object -Unique
            )
            $evidenceOnlyDatasets.Count | Should -BeGreaterThan 0

            foreach ($dataset in $evidenceOnlyDatasets) {
                $compiledDatasets | Should -Not -Contain $dataset
            }
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
