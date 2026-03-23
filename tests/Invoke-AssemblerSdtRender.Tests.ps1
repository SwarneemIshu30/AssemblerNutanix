Describe 'Invoke-AssemblerSdtRender integration' {
    BeforeAll {
        $scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-AssemblerSdtRender.ps1'
        $scriptSource = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
        $functionBlock = [regex]::Match(
            $scriptSource,
            '(?s)function Read-JsonFile \{.*?^}\s*.*?function ConvertTo-PlainHashtable \{.*?^}\s*.*?function Test-ProjectionContractJsonArrayShape \{.*?^}\s*.*?function Read-ProjectionContractFile \{.*?^}',
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        ).Value

        if ([string]::IsNullOrWhiteSpace($functionBlock)) {
            throw 'Failed to load projection contract helper functions from script under test.'
        }

        Invoke-Expression $functionBlock
    }

    function New-TestRenderFixture {
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][object[]]$Mappings,
            [Parameter(Mandatory = $true)][string]$Template,
            [Parameter(Mandatory = $false)][hashtable]$Dataset,
            [Parameter(Mandatory = $false)][string]$DatasetRelativePath = 'datasets/systems.json'
        )

        $bundleRoot = Join-Path $Root 'bundle'
        $datasetsRoot = Join-Path $bundleRoot 'datasets'
        $null = New-Item -Path $datasetsRoot -ItemType Directory -Force

        $manifestPath = Join-Path $bundleRoot 'manifest.json'
        Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value (@{
            bundleId = 'bundle-test'
        } | ConvertTo-Json -Depth 5)

        $datasetPath = Join-Path $bundleRoot $DatasetRelativePath
        $datasetDir = Split-Path -Parent $datasetPath
        if (-not (Test-Path -LiteralPath $datasetDir -PathType Container)) {
            $null = New-Item -Path $datasetDir -ItemType Directory -Force
        }
        $datasetPayload = if ($PSBoundParameters.ContainsKey('Dataset')) {
            $Dataset
        }
        else {
            @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{ name = 'ArrayOne'; status = 'online' }
                )
            }
        }
        Set-Content -LiteralPath $datasetPath -Encoding UTF8 -Value ($datasetPayload | ConvertTo-Json -Depth 10)

        $mappingPath = Join-Path $Root 'mapping.json'
        Set-Content -LiteralPath $mappingPath -Encoding UTF8 -Value (@{
            schema = 'mapping.dataset-to-sdt'
            schemaVersion = 1
            techId = 'Lenovo.DE'
            displayName = 'test mapping'
            compatibility = @{ contracts = @{ version = 'v1' } }
            strictContracts = @{ enabled = $true; requireAllMappings = $true }
            mappings = $Mappings
        } | ConvertTo-Json -Depth 10)

        $templatePath = Join-Path $Root 'template.txt'
        Set-Content -LiteralPath $templatePath -Encoding UTF8 -Value $Template

        return @{
            bundleRoot = $bundleRoot
            mappingPath = $mappingPath
            templatePath = $templatePath
            outputPath = (Join-Path $Root 'rendered.txt')
            reportPath = (Join-Path $Root 'report.json')
        }
    }

    It 'keeps successful render reports schema-valid when matches are emitted' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-render-report-schema-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                    target = @{ sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName' }
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw 'Expected successful render exit code' }

            $report = $output | ConvertFrom-Json -AsHashtable
            $schemaIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-RENDERREPORT-INVALID' })
            if ($schemaIssues.Count -ne 0) {
                throw "Expected render report with matches to remain schema-valid, but found: $($schemaIssues[0].message)"
            }

            $match = @($report.matches | Where-Object { $_.tag -eq 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName' }) | Select-Object -First 1
            if ($null -eq $match) {
                throw 'Expected successful render report to include a match entry for the populated tag.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'assigns valid timestamps to skipped stages when execution stops during validation' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-skipped-stage-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @()

            Set-Content -LiteralPath $fixture.mappingPath -Encoding UTF8 -Value (@{
                schema = 'mapping.dataset-to-sdt'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'invalid mapping'
                strictContracts = @{ enabled = $true; requireAllMappings = $true }
            } | ConvertTo-Json -Depth 10)

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to invalid mapping schema' }

            $report = $output | ConvertFrom-Json -AsHashtable
            foreach ($stage in @($report.stages | Where-Object { $_.status -eq 'SKIPPED' })) {
                if ([string]::IsNullOrWhiteSpace([string]$stage.startedUtc)) {
                    throw "Expected skipped stage '$($stage.name)' to include startedUtc"
                }
                if ([string]::IsNullOrWhiteSpace([string]$stage.completedUtc)) {
                    throw "Expected skipped stage '$($stage.name)' to include completedUtc"
                }
            }

            if ((@($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-RENDERREPORT-INVALID' }).Count) -ne 0) {
                throw 'Expected skipped-stage timestamps to keep render report schema-valid'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'normalizes projection contracts with nested strings without raising Count exceptions' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-projection-normalization-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $projectionContractPath = Join-Path $tempRoot 'assembler.projections.v1.json'
            Set-Content -LiteralPath $projectionContractPath -Encoding UTF8 -Value (@{
                schema = 'assembler.projections'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'nested string projection contract'
                projections = @{
                    TEST_TAG = @{
                        filter = @(
                            @{
                                field = 'items.0.name'
                                equals = 'ArrayOne'
                            }
                        )
                        columns = @(
                            @{
                                name = 'summary'
                                value = @{
                                    text = 'alpha'
                                    nested = @{
                                        label = 'beta'
                                    }
                                }
                            }
                        )
                    }
                }
            } | ConvertTo-Json -Depth 10)

            try {
                $result = Read-ProjectionContractFile -Path $projectionContractPath
            }
            catch {
                if ($_.Exception.Message -match 'Count') {
                    throw "Unexpected Count exception while normalizing nested strings: $($_.Exception.Message)"
                }

                throw
            }

            if ([string]$result.projections.TEST_TAG.columns[0].value.text -ne 'alpha') {
                throw 'Expected nested string leaf value to be preserved during normalization.'
            }

            if ([string]$result.projections.TEST_TAG.columns[0].value.nested.label -ne 'beta') {
                throw 'Expected nested string leaf value to remain accessible after normalization.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'preserves one-item projection filter arrays through normalization and JSON reserialization' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-projection-array-shape-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $projectionContractPath = Join-Path $tempRoot 'assembler.projections.v1.json'
            Set-Content -LiteralPath $projectionContractPath -Encoding UTF8 -Value (@{
                schema = 'assembler.projections'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'single-item filter projection contract'
                projections = @{
                    'LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI' = @{
                        filter = @(
                            @{
                                field = 'transport'
                                equals = 'iscsi'
                            }
                        )
                        columns = @(
                            @{
                                name = 'Port'
                                value = 'name'
                            }
                        )
                    }
                }
            } | ConvertTo-Json -Depth 10)

            $result = Read-ProjectionContractFile -Path $projectionContractPath
            if (-not ($result.projections['LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI'].filter -is [System.Collections.IList])) {
                throw 'Expected single-item filter to remain an array after loading projection contract.'
            }

            if (@($result.projections['LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI'].filter).Count -ne 1) {
                throw 'Expected exactly one filter entry after loading projection contract.'
            }

            $projectionContractJson = $result | ConvertTo-Json -Depth 10
            $jsonShape = Test-ProjectionContractJsonArrayShape -JsonText $projectionContractJson
            if (-not $jsonShape.isValid) {
                throw "Expected projection contract JSON to preserve array shape, but got: $($jsonShape.message)"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails validation when the projection contract is schema-invalid' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-invalid-projection-contract-test-" + [guid]::NewGuid().ToString())
        $tempContractsRoot = Join-Path $tempRoot 'contracts'
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            Copy-Item -LiteralPath $contractsRoot -Destination $tempContractsRoot -Recurse -Force
            $projectionContractPath = Join-Path $tempContractsRoot 'tech/Lenovo.DE/assembler.projections.v1.json'
            Set-Content -LiteralPath $projectionContractPath -Encoding UTF8 -Value (@{
                schema = 'assembler.projections'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'invalid projection contract'
                projections = @(
                    @{
                        sdtTag = 'BROKEN'
                        columns = @(
                            @{ name = 'OnlyName' }
                        )
                    }
                )
            } | ConvertTo-Json -Depth 10)

            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName'
                    required = $true
                    selectors = @('items', '0', 'name')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $tempContractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to invalid projection schema' }

            $report = $output | ConvertFrom-Json -AsHashtable
            $issue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-PROJECTIONS-INVALID' }) | Select-Object -First 1
            if ($null -eq $issue) {
                throw 'Expected projection schema validation issue in report'
            }
            if ([string]$issue.path -ne $projectionContractPath) {
                throw "Expected projection schema issue path '$projectionContractPath', got '$($issue.path)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'applies selector chains sequentially and records the full selector chain in matches' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName'
                    required = $true
                    selectors = @('items', '0', 'name')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'System=ArrayOne') { throw "Expected selector chain to resolve value, got '$rendered'" }

            $report = $output | ConvertFrom-Json -AsHashtable
            $match = @($report.matches | Where-Object { $_.tag -eq 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName' }) | Select-Object -First 1
            if ($null -eq $match) { throw 'Expected LNV.Lenovo.DE.System[ArrayName].Summary.SystemName match entry in report' }
            if ($match.selector -ne 'items -> 0 -> name') {
                throw "Expected full selector chain in report match selector, got '$($match.selector)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits selector no-match ERROR for required mappings and warning for optional mappings' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Req=<<SDT:REQ_NAME>>;Opt=<<SDT:OPT_NAME>>" -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'REQ_NAME'
                    required = $true
                    selectors = @('items', '0', 'missing')
                },
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'OPT_NAME'
                    required = $false
                    selectors = @('items', '0', 'alsoMissing')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to required selector failure' }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ERROR') { throw "Expected report.status ERROR, got '$($report.status)'" }

            $selectorIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-SELECTOR-NOMATCH' })
            $requiredIssue = @($selectorIssues | Where-Object { $_.severity -eq 'ERROR' -and $_.message -match "tag 'REQ_NAME'" }) | Select-Object -First 1
            if ($null -eq $requiredIssue) { throw 'Expected required selector failure to emit ERROR issue' }

            $optionalIssue = @($selectorIssues | Where-Object { $_.severity -eq 'WARN' -and $_.message -match "tag 'OPT_NAME'" }) | Select-Object -First 1
            if ($null -eq $optionalIssue) { throw 'Expected optional selector failure to emit WARN issue' }

            if ((@($report.matches | Where-Object { $_.tag -eq 'OPT_NAME' }).Count) -ne 0) {
                throw 'Expected optional failed selector mapping to be skipped from matches'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'treats empty array selector values as successful resolutions for Lenovo.DE datasets' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-empty-array-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template @'
NTP0=<<SDT:NTP0>>
DHCP0=<<SDT:DHCP0>>
DNS0=<<SDT:DNS0>>
NTP1=<<SDT:NTP1>>
DHCP1=<<SDT:DHCP1>>
DNS1=<<SDT:DNS1>>
'@ -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 2
                items = @(
                    @{
                        ntpServers = @()
                        dhcpAcquiredServers = @()
                        dnsServers = @()
                    },
                    @{
                        ntpServers = @()
                        dhcpAcquiredServers = @()
                        dnsServers = @()
                    }
                )
            } -Mappings @(
                @{ dataset = 'datasets/systems.json'; sdtTag = 'NTP0'; required = $true; selectors = @('items', '0', 'ntpServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DHCP0'; required = $true; selectors = @('items', '0', 'dhcpAcquiredServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DNS0'; required = $true; selectors = @('items', '0', 'dnsServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'NTP1'; required = $true; selectors = @('items', '1', 'ntpServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DHCP1'; required = $true; selectors = @('items', '1', 'dhcpAcquiredServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DNS1'; required = $true; selectors = @('items', '1', 'dnsServers') }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') { throw "Expected report.status OK, got '$($report.status)'" }

            $selectorIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-SELECTOR-NOMATCH' })
            if ($selectorIssues.Count -ne 0) {
                throw "Expected no selector no-match issues for empty arrays, got $($selectorIssues.Count)"
            }

            foreach ($tag in @('NTP0', 'DHCP0', 'DNS0', 'NTP1', 'DHCP1', 'DNS1')) {
                $match = @($report.matches | Where-Object { $_.tag -eq $tag }) | Select-Object -First 1
                if ($null -eq $match) { throw "Expected match entry for tag '$tag'" }
            }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            foreach ($expectedLine in @('NTP0=[]', 'DHCP0=[]', 'DNS0=[]', 'NTP1=[]', 'DHCP1=[]', 'DNS1=[]')) {
                if ($rendered -notmatch [regex]::Escape($expectedLine)) {
                    throw "Expected rendered output to contain '$expectedLine', got '$rendered'"
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits envelope ERROR for required mappings and warning for optional mappings' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Req=<<SDT:REQ_NAME>>;Opt=<<SDT:OPT_NAME>>" -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 2
                items = @(
                    @{ name = 'ArrayOne'; status = 'online' }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'REQ_NAME'
                    required = $true
                    selectors = @('items', '0', 'name')
                },
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'OPT_NAME'
                    required = $false
                    selectors = @('items', '0', 'name')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to required envelope validation failure' }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ERROR') { throw "Expected report.status ERROR, got '$($report.status)'" }

            $envelopeIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DATASET-ENVELOPE' })
            $requiredIssue = @($envelopeIssues | Where-Object { $_.severity -eq 'ERROR' -and $_.message -match "tag 'REQ_NAME'" }) | Select-Object -First 1
            if ($null -eq $requiredIssue) { throw 'Expected required mapping envelope failure to emit ERROR issue' }

            $optionalIssue = @($envelopeIssues | Where-Object { $_.severity -eq 'WARN' -and $_.message -match "tag 'OPT_NAME'" }) | Select-Object -First 1
            if ($null -eq $optionalIssue) { throw 'Expected optional mapping envelope failure to emit WARN issue' }

            if ((@($report.matches | Where-Object { $_.tag -eq 'OPT_NAME' }).Count) -ne 0) {
                throw 'Expected optional envelope-invalid mapping to be skipped from matches'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'consumes legacy Lenovo.DE run_summary payloads without failing envelope validation' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-legacy-summary-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Collected=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectedUTC>>;Mode=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionMode>>" -DatasetRelativePath 'datasets/run_summary.json' -Dataset @{
                collectedUtc = '2026-03-21T15:38:55.2459138+11:00'
                mode = 'Cli'
                controller = '10.240.59.179'
                port = 8443
                systemCount = 1
            } -Mappings @(
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectedUTC'
                    required = $true
                    selectors = @('collectedUtc')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionMode'
                    required = $true
                    selectors = @('mode')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Collected=2026-03-21T15:38:55.2459138\+11:00;Mode=Cli') {
                throw "Expected legacy summary values to render successfully, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $compatIssue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DATASET-COMPAT' }) | Select-Object -First 1
            if ($null -eq $compatIssue) {
                throw 'Expected legacy summary compatibility warning in report'
            }
            if ($compatIssue.severity -ne 'WARN') {
                throw "Expected compatibility warning severity WARN, got '$($compatIssue.severity)'"
            }

            if ((@($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DATASET-ENVELOPE' }).Count) -ne 0) {
                throw 'Expected legacy summary compatibility to suppress envelope validation errors'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'extracts Lenovo.DE summary values from enveloped run_summary output using existing selectors' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-envelope-summary-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Controller=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController>>;Port=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionPort>>;SystemCount=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.SystemCountReturned>>" -DatasetRelativePath 'datasets/run_summary.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'LNV.AsBuiltDoc.Lenovo.DE'; version = '1.0.0' }
                source = @{ kind = 'Lenovo.DE'; endpoint = 'local'; file = 'run_summary.json' }
                dataset = @{ key = 'run_summary'; schema_path = 'tech/Lenovo.DE/dataset/run_summary.schema.json' }
                item_count = 1
                items = @(
                    @{
                        collectedUtc = '2026-03-21T15:38:55.2459138+11:00'
                        mode = 'Cli'
                        controller = '10.240.59.179'
                        port = 8443
                        systemCount = 1
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController'
                    required = $true
                    selectors = @('controller')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionPort'
                    required = $true
                    selectors = @('port')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.SystemCountReturned'
                    required = $true
                    selectors = @('systemCount')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            foreach ($expectedValue in @(
                'Controller=10.240.59.179',
                'Port=8443',
                'SystemCount=1'
            )) {
                if ($rendered -notmatch [regex]::Escape($expectedValue)) {
                    throw "Expected rendered output to contain '$expectedValue', got '$rendered'"
                }
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $controllerMatch = @($report.matches | Where-Object { $_.tag -eq 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController' }) | Select-Object -First 1
            if ($null -eq $controllerMatch) {
                throw 'Expected LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController match entry in report'
            }
            if ($controllerMatch.selector -ne 'controller') {
                throw "Expected existing selector 'controller' to remain in report, got '$($controllerMatch.selector)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'renders an empty string when FC host-port projection filters out all rows' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-empty-fc-hostports-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "FC=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC>>" -DatasetRelativePath 'datasets/host-ports.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'host-ports'
                item_count = 1
                items = @(
                    @{
                        controllerLabel = 'A'
                        controllerSlot = '1'
                        portLabel = '1'
                        channel = '1'
                        linkStatus = 'up'
                        transport = 'iscsi'
                        ipv4Address = '192.0.2.10'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/host-ports.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -ne 'FC=') {
                throw "Expected empty FC table rendering after projection filter removes all rows, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders Lenovo.DE capabilities projection when filtering leaves a single row' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-single-capability-row-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Caps=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary>>" -DatasetRelativePath 'datasets/capabilities-normalized.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'capabilities-normalized'
                item_count = 2
                items = @(
                    @{
                        displayName = 'Snapshot Copies'
                        category = 'Data Protection'
                        state = 'Enabled'
                        compliance = 'Compliant'
                        entitlement = 'Included'
                        includeInMainBody = $true
                        includeInAppendix = $true
                        sortOrder = 10
                    },
                    @{
                        displayName = 'Hidden Feature'
                        category = 'Testing'
                        state = 'Disabled'
                        compliance = 'Unknown'
                        entitlement = 'None'
                        includeInMainBody = $false
                        includeInAppendix = $false
                        sortOrder = 20
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/capabilities-normalized.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Feature\s+Category\s+State\s+Compliance\s+Entitlement') {
                throw "Expected capabilities projection table header, got '$rendered'"
            }
            if ($rendered -notmatch 'Snapshot Copies\s+Data Protection\s+Enabled\s+Compliant\s+Included') {
                throw "Expected filtered projected capability row, got '$rendered'"
            }
            if ($rendered -match 'Hidden Feature') {
                throw "Expected projection filter to remove hidden capability row, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders an empty string when capabilities projection filters out all rows' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-empty-capabilities-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Caps=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary>>" -DatasetRelativePath 'datasets/capabilities-normalized.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'capabilities-normalized'
                item_count = 1
                items = @(
                    @{
                        displayName = 'Hidden Feature'
                        category = 'Testing'
                        state = 'Disabled'
                        compliance = 'Unknown'
                        entitlement = 'None'
                        includeInMainBody = $false
                        includeInAppendix = $false
                        sortOrder = 10
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/capabilities-normalized.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -ne 'Caps=') {
                throw "Expected empty capabilities table rendering after projection filter removes all rows, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'uses Lenovo.DE system inventory projection so system table tags render reader-facing tabular columns' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-system-inventory-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Inventory>>" -DatasetRelativePath 'datasets/systems.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{
                        name = 'DE4800-A'
                        model = 'DE4800F'
                        status = 'optimal'
                        fwVersion = '11.20'
                        appVersion = '11.20'
                        ip2 = '192.0.2.10'
                        controllers = 2
                        trayCount = 4
                        driveCount = 96
                        hiddenRef = 'internal-only'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Inventory'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'SystemName\s+Model\s+Status\s+FirmwareVersion\s+ApplicationVersion\s+ManagementIP\s+ControllerCount\s+TrayCount\s+DriveCount') {
                throw "Expected projected system inventory table header, got '$rendered'"
            }
            if ($rendered -match 'hiddenRef|\{"name":') {
                throw "Expected reader-facing system projection output instead of raw JSON, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders Lenovo.DE system inventory projection with display columns and selected values from systems fixture' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-system-inventory-focused-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Inventory=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Inventory>>" -DatasetRelativePath 'datasets/systems.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{
                        name = 'Array-Prime'
                        model = 'DE6000F'
                        status = 'optimal'
                        fwVersion = '11.90'
                        appVersion = '11.90.1'
                        ip2 = '198.51.100.24'
                        controllers = 2
                        trayCount = 3
                        driveCount = 48
                        hiddenRef = 'internal-only'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Inventory'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'SystemName\s+Model\s+Status\s+FirmwareVersion\s+ApplicationVersion\s+ManagementIP\s+ControllerCount\s+TrayCount\s+DriveCount') {
                throw "Expected readable projected system inventory header, got '$rendered'"
            }
            if ($rendered -notmatch 'Array-Prime\s+DE6000F\s+optimal\s+11\.90\s+11\.90\.1\s+198\.51\.100\.24\s+2\s+3\s+48') {
                throw "Expected projected system inventory values, got '$rendered'"
            }
            if ($rendered -match 'hiddenRef|fwVersion|appVersion|\{"name":|^\s*Inventory=\s*\{' ) {
                throw "Expected projected system inventory output instead of raw JSON keys/braces, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses Lenovo.DE tray projection so tray table tags render reader-facing tabular columns' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-tray-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Trays=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>" -DatasetRelativePath 'datasets/trays.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'trays'
                item_count = 1
                items = @(
                    @{
                        trayId = 99
                        trayType = 'de224c'
                        trayRole = 'controller-tray'
                        serialNumber = 'SN-TRAY-99'
                        partNumber = 'PN-12345'
                        numDriveSlots = 24
                        numControllerSlots = 2
                        status = 'optimal'
                        manufacturer = 'Lenovo'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/trays.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Trays'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'TrayId\s+TrayType\s+TrayRole\s+SerialNumber\s+PartNumber\s+DriveSlots\s+ControllerSlots\s+Status') {
                throw "Expected projected tray table header, got '$rendered'"
            }
            if ($rendered -match 'manufacturer|\{"trayId":') {
                throw "Expected reader-facing tray projection output instead of raw JSON, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders Lenovo.DE tray projection with display columns and excludes internal tray fields' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-tray-focused-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Trays=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>" -DatasetRelativePath 'datasets/trays.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'trays'
                item_count = 1
                items = @(
                    @{
                        trayId = 7
                        trayType = 'DE212C'
                        trayRole = 'expansion-tray'
                        serialNumber = 'TRAY-0007'
                        partNumber = '01KP999'
                        numDriveSlots = 12
                        numControllerSlots = 0
                        status = 'optimal'
                        manufacturer = 'Lenovo'
                        esmFirmware = '8.20'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/trays.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Trays'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'TrayId\s+TrayType\s+TrayRole\s+SerialNumber\s+PartNumber\s+DriveSlots\s+ControllerSlots\s+Status') {
                throw "Expected readable projected tray header, got '$rendered'"
            }
            if ($rendered -notmatch '7\s+DE212C\s+expansion-tray\s+TRAY-0007\s+01KP999\s+12\s+0\s+optimal') {
                throw "Expected projected tray values, got '$rendered'"
            }
            if ($rendered -match 'manufacturer|esmFirmware|numDriveSlots|numControllerSlots|\{"trayId":|^\s*Trays=\s*\{' ) {
                throw "Expected projected tray output instead of raw/internal fields, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses Lenovo.DE projection aliases so reader-facing drive inventory tags render projected tabular columns' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-drive-projection-alias-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Drive=<<SDT:LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory>>" -DatasetRelativePath 'datasets/drives.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'drives'
                item_count = 1
                items = @(
                    @{
                        slot = 1
                        driveMediaType = 'ssd'
                        rawCapacityBytes = 2000398934016
                        usableCapacityBytes = 1800398934016
                        firmwareVersion = 'LE00'
                        status = 'optimal'
                        serialNumber = 'SN123'
                        hiddenRef = 'internal-only'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/drives.json'
                    sdtTag = 'LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Slot\s+Media Type\s+Raw\s+Usable\s+Firmware\s+Status\s+SerialNumber') {
                throw "Expected projected drive inventory table header, got '$rendered'"
            }
            if ($rendered -match 'rawCapacityBytes|usableCapacityBytes|hiddenRef') {
                throw "Expected reader-facing drive projection to hide raw/internal columns, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'keeps Lenovo.DE collector skeleton aligned with the current document contract coverage' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractMappingPath = Join-Path $repoRoot '.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'
        $collectorMappingPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $templatePath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.template.txt'

        $contractText = Get-Content -LiteralPath $contractMappingPath -Raw -Encoding UTF8
        $collectorMapping = Get-Content -LiteralPath $collectorMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $templateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
        $templateLines = $templateText -split "`r?`n"

        $contractByDataset = @{}
        foreach ($match in [regex]::Matches($contractText, '- dataset: (?<dataset>[^\r\n]+)\r?\n\s+sdtTag: (?<sdtTag>[^\r\n]+)', [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
            $datasetName = [string]$match.Groups['dataset'].Value
            $sdtTag = [string]$match.Groups['sdtTag'].Value
            if (-not $contractByDataset.ContainsKey($datasetName)) {
                $contractByDataset[$datasetName] = [System.Collections.Generic.List[string]]::new()
            }
            $contractByDataset[$datasetName].Add($sdtTag)
        }

        $collectorByDataset = @{}
        foreach ($entry in @($collectorMapping.mappings)) {
            $datasetName = [System.IO.Path]::GetFileNameWithoutExtension([string]$entry.dataset)
            if ([string]::IsNullOrWhiteSpace($datasetName)) {
                continue
            }
            if (-not $collectorByDataset.ContainsKey($datasetName)) {
                $collectorByDataset[$datasetName] = [System.Collections.Generic.List[string]]::new()
            }
            $collectorByDataset[$datasetName].Add([string]$entry.sdtTag)
        }

        $templatePlaceholders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($match in [regex]::Matches($templateText, '<<SDT:(?<tag>[^>]+)>>')) {
            [void]$templatePlaceholders.Add([string]$match.Groups['tag'].Value)
        }

        $normalizedTemplateHeadings = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $templateLines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if ($trimmed.StartsWith('<<SDT:')) { continue }
            if ($trimmed.StartsWith('[')) { continue }
            if ($trimmed.StartsWith('- ')) { continue }
            if ($trimmed -match '^[=:.-]{3,}$') { continue }
            if ($trimmed -match ' : ') { continue }
            [void]$normalizedTemplateHeadings.Add($trimmed)
        }

        $requiredCoverage = @(
            @{ Heading = 'Controller Topology'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.Controllers'); ContractDatasets = @('system-controllers') },
            @{ Heading = 'Management Interfaces'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces'); ContractDatasets = @('management-interfaces') },
            @{ Heading = 'DNS Configuration'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.DNS'); ContractDatasets = @('system-dns') },
            @{ Heading = 'Time Configuration'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.Time'); ContractDatasets = @('system-time') },
            @{ Heading = 'Tray / Shelf Inventory'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.Trays'); ContractDatasets = @('trays') },
            @{ Heading = 'Drive Inventory'; TemplateTags = @('LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory'); ContractDatasets = @('drives') },
            @{ Heading = 'Storage Containers / Pools / Volume Groups'; TemplateTags = @('LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory'); ContractDatasets = @('storage-containers') },
            @{ Heading = 'Volumes'; TemplateTags = @('LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory'); ContractDatasets = @('volumes') },
            @{ Heading = 'Volume Mapping Summary'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.VolumeMappings'); ContractDatasets = @('volume-mappings') },
            @{ Heading = 'Host Definitions'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.Hosts'); ContractDatasets = @('hosts') },
            @{ Heading = 'Host Groups'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.HostGroups'); ContractDatasets = @('host-groups') },
            @{ Heading = 'Host to Host Group Relationships'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.HostsToHostGroups'); ContractDatasets = @('hosts-to-host-groups') },
            @{ Heading = 'Host Group to Volume Presentation'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.HostGroupsToVolumes'); ContractDatasets = @('host-groups-to-volumes') },
            @{ Heading = 'Direct Host to Volume Presentation'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.HostsToVolumes'); ContractDatasets = @('hosts-to-volumes') },
            @{ Heading = 'Host Port Configuration - iSCSI'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI'); ContractDatasets = @('host-ports') },
            @{ Heading = 'Host Port Configuration - Fibre Channel'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC'); ContractDatasets = @('host-ports') },
            @{ Heading = 'Transport Summary'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.Transport'); ContractDatasets = @('transport') },
            @{ Heading = 'Alerts & AutoSupport'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport'); ContractDatasets = @('system-asup') },
            @{ Heading = 'Capabilities Summary'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary'); ContractDatasets = @('capabilities-normalized') },
            @{ Heading = 'Key Features'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesKeyFeatures'); ContractDatasets = @('capabilities-normalized') },
            @{ Heading = 'Feature Limits / Consumption'; TemplateTags = @('LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesLimits'); ContractDatasets = @('capabilities-normalized') }
        )

        foreach ($coverage in $requiredCoverage) {
            if (-not $normalizedTemplateHeadings.Contains($coverage.Heading)) {
                throw "Expected Lenovo.DE TXT skeleton to include document heading '$($coverage.Heading)'"
            }

            foreach ($templateTag in $coverage.TemplateTags) {
                if (-not $templatePlaceholders.Contains($templateTag)) {
                    throw "Expected Lenovo.DE TXT skeleton to include SDT placeholder '$templateTag' for heading '$($coverage.Heading)'"
                }

                $collectorMatches = @($collectorMapping.mappings | Where-Object { $_.sdtTag -eq $templateTag })
                if ($collectorMatches.Count -eq 0) {
                    throw "Expected collector skeleton mapping to include SDT tag '$templateTag' used by heading '$($coverage.Heading)'"
                }
            }

            foreach ($datasetName in $coverage.ContractDatasets) {
                if (-not $contractByDataset.ContainsKey($datasetName)) {
                    throw "Expected Lenovo.DE contract mapping to include dataset '$datasetName' for heading '$($coverage.Heading)'"
                }

                if (-not $collectorByDataset.ContainsKey($datasetName)) {
                    throw "Expected collector skeleton mapping to include dataset '$datasetName' for heading '$($coverage.Heading)'"
                }
            }
        }

        $contractAliasExpectations = @(
            @{ Dataset = 'system-asup'; ExpectedCollectorTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport'; ContractTagPattern = '^LNV\.Lenovo\.DE\.System\[<SystemId>\]\.Tables\.ASUP$' },
            @{ Dataset = 'storage-containers'; ExpectedCollectorTag = 'LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory'; ContractTagPattern = '^LNV\.Lenovo\.DE\.System\[<SystemId>\]\.Tables\.StorageContainers$' },
            @{ Dataset = 'volumes'; ExpectedCollectorTag = 'LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory'; ContractTagPattern = '^LNV\.Lenovo\.DE\.System\[<SystemId>\]\.Tables\.Volumes$' }
        )

        foreach ($expectation in $contractAliasExpectations) {
            $contractTags = @($contractByDataset[$expectation.Dataset])
            if ((@($contractTags | Where-Object { $_ -match $expectation.ContractTagPattern }).Count) -eq 0) {
                throw "Expected Lenovo.DE contract mapping dataset '$($expectation.Dataset)' to advertise the current contract tag pattern '$($expectation.ContractTagPattern)'"
            }

            if (-not $templatePlaceholders.Contains($expectation.ExpectedCollectorTag)) {
                throw "Expected Lenovo.DE TXT skeleton to expose reader-facing placeholder '$($expectation.ExpectedCollectorTag)' for dataset '$($expectation.Dataset)'"
            }

            if (-not @($collectorMapping.mappings | Where-Object { $_.sdtTag -eq $expectation.ExpectedCollectorTag })) {
                throw "Expected collector skeleton mapping to expose reader-facing tag '$($expectation.ExpectedCollectorTag)' for dataset '$($expectation.Dataset)'"
            }
        }
    }

    It 'emits a render issue and placeholder when table render mode has no projection definition' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-table-missing-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'Table=<<SDT:MISSING_TABLE>>' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{ name = 'row1'; status = 'online' }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'MISSING_TABLE'
                    required = $true
                    renderHint = @{ renderMode = 'table'; missingProjectionPolicy = 'placeholder' }
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            if ($LASTEXITCODE -ne 0) { throw "Expected exit code 0, got $LASTEXITCODE" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch [regex]::Escape('Table=[table data omitted: projection required]')) {
                throw "Expected placeholder output for missing table projection, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $issue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-TABLE-PROJECTION-MISSING' }) | Select-Object -First 1
            if ($null -eq $issue) {
                throw 'Expected missing table projection issue in report'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'allows raw JSON only for explicitly declared json evidence render mode' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-json-evidence-render-mode-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'Evidence=<<SDT:RAW_EVIDENCE>>' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{ name = 'ArrayOne'; nested = @{ state = 'ok' } }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'RAW_EVIDENCE'
                    required = $true
                    selectors = @('items', '0')
                    renderHint = @{ renderMode = 'json-evidence' }
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            if ($LASTEXITCODE -ne 0) { throw "Expected exit code 0, got $LASTEXITCODE" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Evidence=\{"name":"ArrayOne","nested":\{"state":"ok"\}\}') {
                throw "Expected explicit json evidence render mode to preserve JSON, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ((@($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-STRUCTURED-VALUE-RENDERMODE-REQUIRED' }).Count) -ne 0) {
                throw 'Expected no structured-value render mode warning for explicit json evidence rendering'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses dataset presentation metadata to default selectors and preferred projections' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-dataset-presentation-metadata-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'Ports=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI>>' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'host-ports'
                item_count = 1
                items = @(
                    @{
                        systemId = 'sys-01'
                        transport = 'iscsi'
                        controllerRef = 'A'
                        controllerLabel = 'A'
                        controllerSlot = 1
                        portLabel = 'P1'
                        interfaceRef = 'if-01'
                        linkStatus = 'up'
                        channel = 1
                        ipv4Address = '10.0.0.10'
                        ipv4SubnetMask = '255.255.255.0'
                        ipv4Gateway = '10.0.0.1'
                        tcpPort = 3260
                        iqn = 'iqn.1993-08.org.debian:01:test'
                    }
                )
            } -DatasetRelativePath 'datasets/host-ports.json' -Mappings @(
                @{
                    dataset = 'datasets/host-ports.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI'
                    required = $true
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            if ($LASTEXITCODE -ne 0) { throw "Expected exit code 0, got $LASTEXITCODE" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Controller' -or $rendered -notmatch '10\.0\.0\.10' -or $rendered -notmatch 'iqn\.1993-08\.org\.debian:01:test') {
                throw "Expected dataset presentation metadata to drive items-selector table rendering, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $match = @($report.matches | Where-Object { $_.tag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI' }) | Select-Object -First 1
            if ($null -eq $match) {
                throw 'Expected match entry for metadata-driven host port rendering'
            }
            if ([string]$match.selector -ne 'items') {
                throw "Expected selector chain 'items' from dataset presentation metadata, got '$($match.selector)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

}
