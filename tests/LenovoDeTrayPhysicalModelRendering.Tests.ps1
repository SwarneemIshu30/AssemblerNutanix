Describe 'Lenovo.DE tray physical model rendering' {
    BeforeAll {
        function Invoke-TestLenovoDeTrayRender {
    param(
        [Parameter(Mandatory = $true)][hashtable]$TrayRow
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-de-tray-model-render-test-" + [guid]::NewGuid().ToString('N'))
    $bundleRoot = Join-Path $tempRoot 'bundle'
    $datasetRoot = Join-Path $bundleRoot 'datasets'
    $null = New-Item -ItemType Directory -Path $datasetRoot -Force

    @{ bundleId = 'tray-model-render-test' } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $bundleRoot 'manifest.json') -Encoding UTF8

    @{
        schema_version = 'lnv.collector.dataset.v1'
        collector = @{ module = 'test.module'; version = '1.0.0' }
        source = @{ kind = 'integration-test'; endpoint = 'local' }
        dataset = 'trays'
        item_count = 1
        items = @($TrayRow)
    } |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $datasetRoot 'trays.json') -Encoding UTF8

    $mappingPath = Join-Path $tempRoot 'mapping.json'
    @{
        schema = 'mapping.dataset-to-sdt'
        schemaVersion = 1
        techId = 'Lenovo.DE'
        displayName = 'tray model render test'
        compatibility = @{ contracts = @{ version = 'v1' } }
        strictContracts = @{ enabled = $true; requireAllMappings = $true }
        mappings = @(
            @{
                dataset = 'datasets/trays.json'
                sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Trays'
                target = @{ sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Trays' }
                required = $true
                selectors = @('items')
            }
        )
    } |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $mappingPath -Encoding UTF8

    $templatePath = Join-Path $tempRoot 'template.txt'
    'Trays=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>' |
        Set-Content -LiteralPath $templatePath -Encoding UTF8

    $outputPath = Join-Path $tempRoot 'out.txt'
    $reportPath = Join-Path $tempRoot 'report.json'
    $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
    $contractsRoot = Join-Path $repoRoot '.deps/contracts'

    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        throw 'pwsh is required to execute scripts in this test'
    }

    $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $bundleRoot -MappingPath $mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot

    return [pscustomobject]@{
        TempRoot = $tempRoot
        ExitCode = $LASTEXITCODE
        ProcessOutput = $output
        Rendered = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 } else { '' }
        Report = if (Test-Path -LiteralPath $reportPath -PathType Leaf) { Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    }
        }
    }

    It 'renders resolved physical model and full part number for a known MT prefix' {
        $result = Invoke-TestLenovoDeTrayRender -TrayRow @{
            trayId = 99
            trayType = 'de224c'
            trayRole = 'controller-tray'
            controllerModelName = 'DE4200'
            serialNumber = 'J7024YT4'
            partNumber = '7DCQCTO1WW     '
            numDriveSlots = 24
            numControllerSlots = 2
            status = 'optimal'
        }

        try {
            $result.ExitCode | Should -Be 0
            $result.Rendered | Should -Match 'Model\s+TrayType\s+TrayRole\s+SerialNumber\s+PartNumber\s+DriveSlots\s+ControllerSlots\s+Status'
            $result.Rendered | Should -Match 'DE4200H 2U24'
            $result.Rendered | Should -Match '7DCQCTO1WW'
            @($result.Report.issues | Where-Object { $_.code -eq 'ASB-ASM-DE-MODEL-LOOKUP-MISS' }).Count | Should -Be 0
        }
        finally {
            if (Test-Path -LiteralPath $result.TempRoot -PathType Container) {
                Remove-Item -LiteralPath $result.TempRoot -Recurse -Force
            }
        }
    }

    It 'warns and falls back without raw JSON for an unknown MT prefix' {
        $result = Invoke-TestLenovoDeTrayRender -TrayRow @{
            trayId = 1
            trayType = 'de224c'
            trayRole = 'controller-tray'
            controllerModelName = 'DE9999'
            serialNumber = 'UNKNOWN'
            partNumber = 'ZZZZCTO1WW'
            numDriveSlots = 24
            numControllerSlots = 2
            status = 'optimal'
        }

        try {
            $result.ExitCode | Should -Be 0
            $result.Rendered | Should -Match 'DE9999'
            $result.Rendered | Should -Not -Match '\{"trayId":'
            $issue = @($result.Report.issues | Where-Object { $_.code -eq 'ASB-ASM-DE-MODEL-LOOKUP-MISS' }) | Select-Object -First 1
            $issue | Should -Not -BeNullOrEmpty
            $issue.severity | Should -Be 'WARN'
        }
        finally {
            if (Test-Path -LiteralPath $result.TempRoot -PathType Container) {
                Remove-Item -LiteralPath $result.TempRoot -Recurse -Force
            }
        }
    }
}
