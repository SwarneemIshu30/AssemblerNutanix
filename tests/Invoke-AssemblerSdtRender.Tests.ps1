Describe 'Invoke-AssemblerSdtRender integration' {
    It 'renders dummy DE template with sample bundle values' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sampleBundle = Join-Path $repoRoot 'sample/66694360-25ba-40de-8fbd-07ebce431c53'
        if (-not (Test-Path -LiteralPath $sampleBundle -PathType Container)) {
            throw "Expected sample bundle at '$sampleBundle'"
        }

        $contractsRoot = Join-Path $repoRoot 'export/repo-ready/contracts'
        if (-not (Test-Path -LiteralPath $contractsRoot -PathType Container)) {
            throw "Expected contracts root at '$contractsRoot'"
        }

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $skeletonRoot = Join-Path $tempRoot 'skeleton'
            $newSkeletonScript = Join-Path $repoRoot 'scripts/New-AssemblerSkeleton.ps1'
            $null = & $pwshPath -NoLogo -NoProfile -File $newSkeletonScript -DestinationRoot $skeletonRoot

            $mappingPath = Join-Path $skeletonRoot 'DE-SDT-Dummy.mapping.json'
            $templatePath = Join-Path $skeletonRoot 'DE-SDT-Dummy.template.txt'
            $outputPath = Join-Path $tempRoot 'rendered.txt'
            $reportPath = Join-Path $tempRoot 'render-report.json'

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $sampleBundle -MappingPath $mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                throw "Expected exit code 0 for valid render run, got $exitCode"
            }

            if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
                throw "Expected rendered output file at '$outputPath'"
            }

            $rendered = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
            if ($rendered -match '<<SDT:') {
                throw 'Expected SDT placeholder tags to be replaced in rendered output'
            }
            if ($rendered -notmatch 'DE4200_Rack4') {
                throw 'Expected rendered output to include resolved system name'
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status to be OK, got '$($report.status)'"
            }

            $contractStage = @($report.stages | Where-Object { $_.name -eq 'ValidateContract' }) | Select-Object -First 1
            if ($null -eq $contractStage) {
                throw 'Expected ValidateContract stage in report'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
