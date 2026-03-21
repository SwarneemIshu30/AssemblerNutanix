Describe 'Invoke-AssemblerSdtRender integration' {
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

    It 'applies selector chains sequentially and records the full selector chain in matches' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:DE_SYSTEM_NAME>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'DE_SYSTEM_NAME'
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
            $match = @($report.matches | Where-Object { $_.tag -eq 'DE_SYSTEM_NAME' }) | Select-Object -First 1
            if ($null -eq $match) { throw 'Expected DE_SYSTEM_NAME match entry in report' }
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
        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'
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

    It 'emits envelope ERROR for required mappings and warning for optional mappings' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'
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
        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-legacy-summary-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Collected=<<SDT:DE_COLLECTION_COLLECTED_UTC>>;Mode=<<SDT:DE_COLLECTION_MODE>>" -DatasetRelativePath 'datasets/run_summary.json' -Dataset @{
                collectedUtc = '2026-03-21T15:38:55.2459138+11:00'
                mode = 'Cli'
                controller = '10.240.59.179'
                port = 8443
                systemCount = 1
            } -Mappings @(
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'DE_COLLECTION_COLLECTED_UTC'
                    required = $true
                    selectors = @('collectedUtc')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'DE_COLLECTION_MODE'
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
        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-envelope-summary-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Controller=<<SDT:DE_COLLECTION_CONTROLLER>>;Port=<<SDT:DE_COLLECTION_PORT>>;SystemCount=<<SDT:DE_COLLECTION_SYSTEM_COUNT>>" -DatasetRelativePath 'datasets/run_summary.json' -Dataset @{
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
                    sdtTag = 'DE_COLLECTION_CONTROLLER'
                    required = $true
                    selectors = @('controller')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'DE_COLLECTION_PORT'
                    required = $true
                    selectors = @('port')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'DE_COLLECTION_SYSTEM_COUNT'
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
            $controllerMatch = @($report.matches | Where-Object { $_.tag -eq 'DE_COLLECTION_CONTROLLER' }) | Select-Object -First 1
            if ($null -eq $controllerMatch) {
                throw 'Expected DE_COLLECTION_CONTROLLER match entry in report'
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

    It 'keeps Lenovo.DE collector skeleton aligned with the current contract table set' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractMappingPath = Join-Path $repoRoot '.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'
        $collectorMappingPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $templatePath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.template.txt'

        $contractText = Get-Content -LiteralPath $contractMappingPath -Raw -Encoding UTF8
        $collectorMapping = Get-Content -LiteralPath $collectorMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $templateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

        $contractDatasets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($match in [regex]::Matches($contractText, '^- dataset: (?<dataset>[^\r\n]+)', [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
            [void]$contractDatasets.Add([string]$match.Groups['dataset'].Value)
        }

        $collectorDatasets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($collectorMapping.mappings)) {
            $datasetName = [System.IO.Path]::GetFileNameWithoutExtension([string]$entry.dataset)
            if (-not [string]::IsNullOrWhiteSpace($datasetName)) {
                [void]$collectorDatasets.Add($datasetName)
            }
        }

        foreach ($requiredDataset in @(
            'hosts',
            'host-groups',
            'hosts-to-host-groups',
            'host-groups-to-volumes',
            'hosts-to-volumes',
            'volume-mappings',
            'capabilities-normalized'
        )) {
            if (-not $contractDatasets.Contains($requiredDataset)) {
                throw "Expected Lenovo.DE contract mapping to include dataset '$requiredDataset'"
            }
            if (-not $collectorDatasets.Contains($requiredDataset)) {
                throw "Expected collector skeleton mapping to include dataset '$requiredDataset'"
            }
        }

        foreach ($requiredSection in @(
            'Tables.Hosts',
            'Tables.HostGroups',
            'Tables.HostsToHostGroups',
            'Tables.HostGroupsToVolumes',
            'Tables.HostsToVolumes',
            'Tables.VolumeMappings',
            'Tables.CapabilitiesSummary',
            'Tables.CapabilitiesKeyFeatures',
            'Tables.CapabilitiesLimits'
        )) {
            if ($templateText -notmatch [regex]::Escape($requiredSection)) {
                throw "Expected collector skeleton template to include section '$requiredSection'"
            }
        }
    }
}
