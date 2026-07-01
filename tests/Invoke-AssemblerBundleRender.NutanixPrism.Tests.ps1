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
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'health_checks' -Items @(
                    [ordered]@{ name = 'Disk health'; enabled = $true; check_type = 'cluster'; scope = 'cluster'; impact_types = 'availability'; classifications = 'resiliency'; exception_count = 0; message = 'Healthy' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'alerts_configuration' -Items @(
                    [ordered]@{ isEnabled = $true; isEmailDigestEnabled = $true; hasDefaultNutanixEmail = $false; alertEmailDigestSendTime = '08:00'; enable = $true; enable_email_digest = $true; enable_default_nutanix_email = $false }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'smtp_config' -Items @(
                    [ordered]@{ server_address = 'smtp.example.local'; port = 25; secure_mode = 'STARTTLS'; from_email_address = 'prism@example.local'; email_status = 'configured'; password = 'SECRET-SHOULD-NOT-RENDER' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'snmp' -Items @(
                    [ordered]@{ enabled = $true; snmp_users = @('monitor'); snmp_traps = @('trap-a'); snmp_transports = @('udp') }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'authconfig' -Items @(
                    [ordered]@{ auth_type_list = @('LOCAL', 'LDAP'); directory_list = @('corp.example.local') }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'ssl_certificates' -Items @(
                    [ordered]@{ parentId = $targetKey; parentDataset = 'cluster'; privateKeyAlgorithm = 'RSA'; publicCertificate = '-----BEGIN CERTIFICATE----- SHOULD-NOT-RENDER'; nativeUuid = "$targetKey-cert" }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'snapshots' -Items @(
                    [ordered]@{ snapshot_name = 'snap-app01'; vm_uuid = 'vm-uuid-01'; created_time = '2026-06-23T00:00:00Z'; deleted = $false; group_uuid = 'group-01' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'pd_replications' -Items @(
                    [ordered]@{ name = 'replication-a'; protection_domain_name = 'PD-01'; remote_site_name = 'remote-a'; status = 'enabled'; schedule = 'hourly' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'remote_sites' -Items @(
                    [ordered]@{ name = 'remote-a'; url = 'https://remote.example.local'; status = 'connected'; cluster_name = 'remote-cluster'; capabilities = 'replication' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'categories' -Items @(
                    [ordered]@{ key = 'Environment'; value = 'Production'; type = 'SYSTEM'; description = 'Environment category' }
                )
                Write-PrismDatasetEnvelope -TargetKey $targetKey -Dataset 'policies' -Items @(
                    [ordered]@{ name = 'Protection Policy A'; type = 'protection'; status = 'active'; nativeUuid = 'policy-01' }
                )
            }

            $mapping = Get-Content -LiteralPath $prismMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            @($mapping.mappings).Count | Should -Be 73
            $documentMappings = @($mapping.mappings | Where-Object { [string]$_.scope -eq 'target' })
            $documentMappings.Count | Should -Be 42

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
            @('OK', 'WARN') | Should -Contain $bundleReport.runs[0].status

            $renderReport = $bundleReport.runs[0].rendererOutput
            @('OK', 'PARTIAL') | Should -Contain $renderReport.status
            foreach ($issue in @($renderReport.issues)) {
                $issue.severity | Should -Be 'WARN'
                $issue.code | Should -Be 'ASB-ASM-SDT-DATASET-MISSING'
            }
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
            $rendered | Should -Match 'smtp.example.local'
            $rendered | Should -Not -Match 'SECRET-SHOULD-NOT-RENDER'
            $rendered | Should -Not -Match 'BEGIN CERTIFICATE'
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
                $compiledEntries = @($compiledMapping.mappings | Where-Object { [string]$_.dataset -eq $dataset })
                if ($compiledEntries.Count -eq 0) {
                    $compiledDatasets | Should -Not -Contain $dataset
                    continue
                }

                foreach ($compiledEntry in $compiledEntries) {
                    [string]$compiledEntry.sdtTag | Should -Match '\.Audit\.'
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'renders estate-first Prism group datasets without duplicating PC and PE virtual machines' -Skip:(-not (Test-Path -LiteralPath 'C:\Github\LNV.AsBuiltDoc.Core\out\36f0b361-de62-4dfd-bfee-0dc39541de8c.lnvbundle.zip' -PathType Leaf)) {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleArchivePath = 'C:\Github\LNV.AsBuiltDoc.Core\out\36f0b361-de62-4dfd-bfee-0dc39541de8c.lnvbundle.zip'
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Nutanix.Prism/Prism-AsBuilt.catalog.json'
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-prism-estate-" + [guid]::NewGuid().ToString('N'))
        $bundleRoot = Join-Path $tempRoot 'bundle'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            Expand-Archive -LiteralPath $bundleArchivePath -DestinationPath $bundleRoot -Force

            function Write-PrismGroupDatasetEnvelope {
                param(
                    [Parameter(Mandatory)][string] $GroupKey,
                    [Parameter(Mandatory)][string] $Dataset,
                    [Parameter(Mandatory)][object[]] $Items
                )

                $relativePath = "datasets/Nutanix.Prism/group/$GroupKey/$Dataset.json"
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
                        group_key = $GroupKey
                        file = $relativePath
                    }
                    dataset = $Dataset
                    collected_at_utc = '2026-06-23T00:00:00Z'
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

            function New-PrismEstateItem {
                param(
                    [Parameter(Mandatory)][hashtable] $Base,
                    [Parameter(Mandatory)][hashtable] $Values
                )

                $item = [ordered]@{}
                foreach ($key in $Base.Keys) {
                    $item[$key] = $Base[$key]
                }
                foreach ($key in $Values.Keys) {
                    $item[$key] = $Values[$key]
                }
                return $item
            }

            if (-not (Test-Path -LiteralPath (Join-Path $bundleRoot 'datasets/Nutanix.Prism/group/site-a/estate_vm_inventory.json') -PathType Leaf)) {
                $estateBase = @{
                    groupKey = 'site-a'
                    clusterName = 'Prism Element Cluster A'
                    managementPlaneTarget = 'pc01'
                    clusterTarget = 'pe-cluster-a'
                    observedFrom = 'PrismCentral, PrismElement'
                    sourcePreference = 'PrismElement'
                    correlationStatus = 'correlated'
                }
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_cluster_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ cluster = 'Prism Element Cluster A'; status = 'Healthy'; version = 'test'; hostCount = 2; vmCount = 37; storageContainerCount = 2 })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_host_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ hostName = 'ntnx-a-01'; serial = 'SERIAL01'; model = 'HX'; status = 'NORMAL'; hypervisor = 'AHV'; cpuCores = 32; memoryBytes = 274877906944 })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_host_network_interfaces' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ hostName = 'ntnx-a-01'; nicName = 'eth0'; macAddress = '00:11:22:33:44:55'; interfaceStatus = 'UP'; linkSpeedKbps = 10000000; mtuBytes = 9000; virtualSwitch = 'vs0'; switchInterface = 'Eth1/1'; switchVendor = 'Lenovo'; switchManagementIp = '10.0.1.1' })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_vm_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ vmName = 'Cohesity_test'; powerState = 'on'; hostName = 'ntnx-a-01'; cpuCount = 4; memoryBytes = 8589934592; ipAddresses = '10.10.10.20'; nicCount = 1; protectionType = 'unprotected' })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_network_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ networkName = 'prod-net'; networkType = 'VLAN'; vlanId = 1616; virtualSwitch = 'vs0'; mtuBytes = 9000; ipamEnabled = $true; dhcpEnabled = $false; subnet = '10.10.10.0/24' })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_vm_network_interfaces' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ vmName = 'Cohesity_test'; nicName = 'eth0'; macAddress = 'AA:BB:CC:DD:EE:FF'; networkName = 'prod-net'; networkUuid = 'net-uuid-01'; ipAddresses = '10.10.10.20'; connected = $true })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_storage_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ itemType = 'Container'; name = 'default-container'; capacityBytes = 10995116277760; status = ''; detail = 'RF=2' }),
                    (New-PrismEstateItem -Base $estateBase -Values @{ itemType = 'Storage Pool'; name = 'sp01'; capacityBytes = 21990232555520; status = ''; detail = 'Disks=8' }),
                    (New-PrismEstateItem -Base $estateBase -Values @{ itemType = 'Disk'; name = 'disk-01'; capacityBytes = 1099511627776; status = 'NORMAL'; detail = 'Host: ntnx-a-01' }),
                    (New-PrismEstateItem -Base $estateBase -Values @{ itemType = 'Virtual Disk'; name = 'scsi.0'; capacityBytes = 107374182400; status = ''; detail = 'VM: Cohesity_test' }),
                    (New-PrismEstateItem -Base $estateBase -Values @{ itemType = 'Volume Group'; name = 'vg01'; capacityBytes = $null; status = 'SHARED'; detail = 'Target: Cohesity_test' })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_protection_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ protectionName = 'Cohesity_test'; protectionType = 'VM'; status = 'unprotected'; scope = 'Prism Element Cluster A' })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_resiliency_summary' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ faultToleranceDomains = 4; faultToleranceStatus = 'OK'; underReplicatedBytes = 0; nonFaultTolerantEntries = 0; healthCheckCount = 935; enabledHealthChecks = 900; disabledHealthChecks = 35; healthExceptions = 0 })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_operations_config' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ alertingEnabled = $true; emailDigestEnabled = $true; defaultNutanixEmailEnabled = $false; smtpServer = 'smtp.example.local'; smtpPort = 25; smtpSecureMode = 'STARTTLS'; snmpEnabled = $true; snmpUsers = 1; snmpTraps = 1; authTypes = 'LOCAL, LDAP'; directoryCount = 1; sslCertificateCount = 2 })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_protection_detail' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ protectionDomainCount = 1; snapshotCount = 1; remoteSiteCount = 1; replicationCount = 1; drSnapshotCount = 0; unprotectedVmCount = 1; nfsWhitelistCount = 0 })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_governance_summary' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ categoryCount = 71; policyCount = 1; templateCount = 2; imageCount = 3; licenseCount = 1; licenseEdition = 'Ultimate'; licenseState = 'Compliant' })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_image_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ imageName = 'ubuntu-2204-cloud'; imageType = 'DISK_IMAGE'; status = 'ACTIVE'; sizeBytes = 5368709120; createdAt = '2026-06-20T00:00:00Z'; updatedAt = '2026-06-21T00:00:00Z'; source = 'library' })
                )
                Write-PrismGroupDatasetEnvelope -GroupKey site-a -Dataset 'estate_template_inventory' -Items @(
                    (New-PrismEstateItem -Base $estateBase -Values @{ templateName = 'win2022-standard'; templateType = 'VM_TEMPLATE'; status = 'ACTIVE'; sizeBytes = 42949672960; createdAt = '2026-06-18T00:00:00Z'; updatedAt = '2026-06-22T00:00:00Z'; owner = 'admin' })
                )
            }

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
            $bundleReport.runs[0].status | Should -Be 'OK'

            $renderReport = $bundleReport.runs[0].rendererOutput
            $renderReport.status | Should -Be 'OK'
            @($renderReport.issues).Count | Should -Be 0

            $matchedTags = @($renderReport.matches | ForEach-Object { [string]$_.tag })
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.ClusterInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.HostInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.HostNetworkInterfaces'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.VMInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.NetworkInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.StorageContainers'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.StoragePools'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.ProtectionInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.ResiliencySummary'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.OperationsConfig'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.ProtectionDetail'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.GovernanceSummary'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.ImageInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].AsBuilt.TemplateInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].Audit.HostNetworkInterfaces'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].Audit.VMInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].Audit.VMNetworkInterfaces'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].Audit.NetworkInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].Audit.StorageInventory'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].Audit.GovernanceSummary'
            $matchedTags | Should -Contain 'LNV.Nutanix.Prism.Group[GroupKey].Tables.Relationships'

            $rendered = Get-Content -LiteralPath $bundleReport.runs[0].outputPath -Raw -Encoding UTF8
            $mainHostNetworkingSection = [regex]::Match($rendered, '(?s)Host Networking\s*(?<body>.*?)\s*Virtual Machines')
            $mainHostNetworkingSection.Success | Should -BeTrue
            $mainHostNetworkingSection.Groups['body'].Value | Should -Match 'ntnx-a-01'
            $mainHostNetworkingSection.Groups['body'].Value | Should -Match 'eth0'
            $mainHostNetworkingSection.Groups['body'].Value | Should -Match 'vs0'
            $mainHostNetworkingSection.Groups['body'].Value | Should -Match '10.0.1.1'
            $mainHostNetworkingSection.Groups['body'].Value | Should -Not -Match 'PrismCentral, PrismElement'
            $mainHostNetworkingSection.Groups['body'].Value | Should -Not -Match 'pe-cluster-a'
            $mainVmSection = [regex]::Match($rendered, '(?s)Virtual Machines\s*(?<body>.*?)\s*Storage')
            $mainVmSection.Success | Should -BeTrue
            @([regex]::Matches($mainVmSection.Groups['body'].Value, 'Cohesity_test')).Count | Should -Be 1
            $mainVmSection.Groups['body'].Value | Should -Not -Match 'PrismCentral, PrismElement'
            $mainVmSection.Groups['body'].Value | Should -Not -Match 'pe-cluster-a'
            $networkSection = [regex]::Match($rendered, '(?s)Network Inventory\s*(?<body>.*?)\s*Storage Containers')
            $networkSection.Success | Should -BeTrue
            $networkSection.Groups['body'].Value | Should -Match 'prod-net'
            $networkSection.Groups['body'].Value | Should -Match '1616'
            $networkSection.Groups['body'].Value | Should -Match '10.10.10.0/24'
            $networkSection.Groups['body'].Value | Should -Not -Match 'PrismCentral, PrismElement'
            $auditHostNetworkingSection = [regex]::Match($rendered, '(?s)Operational Appendix - Estate Source Audit - Host Networking\s*(?<body>.*?)\s*Operational Appendix - Estate Source Audit - Virtual Machines')
            $auditHostNetworkingSection.Success | Should -BeTrue
            $auditHostNetworkingSection.Groups['body'].Value | Should -Match 'PrismCentral, PrismElement'
            $auditHostNetworkingSection.Groups['body'].Value | Should -Match 'pe-cluster-a'
            $auditVmSection = [regex]::Match($rendered, '(?s)Operational Appendix - Estate Source Audit - Virtual Machines\s*(?<body>.*?)\s*Operational Appendix - Estate Source Audit - Storage')
            $auditVmSection.Success | Should -BeTrue
            $auditVmSection.Groups['body'].Value | Should -Match 'PrismCentral, PrismElement'
            $auditVmSection.Groups['body'].Value | Should -Match 'pe-cluster-a'
            $auditVmNicSection = [regex]::Match($rendered, '(?s)Operational Appendix - Estate VM Network Interfaces\s*(?<body>.*?)\s*Operational Appendix - Estate Source Audit - Network Inventory')
            $auditVmNicSection.Success | Should -BeTrue
            $auditVmNicSection.Groups['body'].Value | Should -Match 'AA:BB:CC:DD:EE:FF'
            $auditVmNicSection.Groups['body'].Value | Should -Match 'prod-net'
            $storageContainersSection = [regex]::Match($rendered, '(?s)Storage Containers\s*(?<body>.*?)\s*Storage Pools')
            $storageContainersSection.Success | Should -BeTrue
            $storageContainersSection.Groups['body'].Value | Should -Match 'default-container'
            $storageContainersSection.Groups['body'].Value | Should -Not -Match 'disk-01'
            $resiliencySection = [regex]::Match($rendered, '(?s)Resiliency and Health\s*(?<body>.*?)\s*Operations Configuration')
            $resiliencySection.Success | Should -BeTrue
            $resiliencySection.Groups['body'].Value | Should -Match '935'
            $resiliencySection.Groups['body'].Value | Should -Not -Match 'Disk health'
            $operationsSection = [regex]::Match($rendered, '(?s)Operations Configuration\s*(?<body>.*?)\s*Governance Summary')
            $operationsSection.Success | Should -BeTrue
            $operationsSection.Groups['body'].Value | Should -Match 'smtp.example.local'
            $operationsSection.Groups['body'].Value | Should -Not -Match 'SECRET-SHOULD-NOT-RENDER'
            $operationsSection.Groups['body'].Value | Should -Not -Match 'BEGIN CERTIFICATE'
            $governanceSection = [regex]::Match($rendered, '(?s)Governance Summary\s*(?<body>.*?)\r?\nImages\r?\n')
            $governanceSection.Success | Should -BeTrue
            $governanceSection.Groups['body'].Value | Should -Match '71'
            $governanceSection.Groups['body'].Value | Should -Match 'Ultimate'
            $governanceSection.Groups['body'].Value | Should -Match 'Compliant'
            $governanceSection.Groups['body'].Value | Should -Not -Match 'Environment'
            $imageSection = [regex]::Match($rendered, '(?s)\r?\nImages\r?\n(?<body>.*?)\r?\nTemplates\r?\n')
            $imageSection.Success | Should -BeTrue
            $imageSection.Groups['body'].Value | Should -Match 'ubuntu-2204-cloud'
            $imageSection.Groups['body'].Value | Should -Match 'DISK_IMAGE'
            $templateSection = [regex]::Match($rendered, '(?s)\r?\nTemplates\r?\n(?<body>.*?)\r?\nOperational Appendix - Alerts')
            $templateSection.Success | Should -BeTrue
            $templateSection.Groups['body'].Value | Should -Match 'win2022-standard'
            $templateSection.Groups['body'].Value | Should -Match 'VM_TEMPLATE'
            $rendered | Should -Match 'Operational Appendix - Target VM Inventory'
            $rendered | Should -Match 'Operational Appendix - Target Health Checks'
            $rendered | Should -Match 'Operational Appendix - Target Categories'
            $rendered | Should -Match 'Operational Appendix - Target Policies'
            $rendered | Should -Match 'Operational Appendix - Target Group Relationships'
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
