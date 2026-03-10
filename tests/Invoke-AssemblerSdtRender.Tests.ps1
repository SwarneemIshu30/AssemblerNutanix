Describe 'Invoke-AssemblerSdtRender integration' {
    function New-TestRenderFixture {
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][object[]]$Mappings,
            [Parameter(Mandatory = $true)][string]$Template
        )

        $bundleRoot = Join-Path $Root 'bundle'
        $datasetsRoot = Join-Path $bundleRoot 'datasets'
        $null = New-Item -Path $datasetsRoot -ItemType Directory -Force

        $manifestPath = Join-Path $bundleRoot 'manifest.json'
        Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value (@{
            bundleId = 'bundle-test'
        } | ConvertTo-Json -Depth 5)

        $datasetPath = Join-Path $datasetsRoot 'systems.json'
        Set-Content -LiteralPath $datasetPath -Encoding UTF8 -Value (@{
            items = @(
                @{ name = 'ArrayOne'; status = 'online' }
            )
        } | ConvertTo-Json -Depth 10)

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
}
