Describe 'Invoke-AssemblerBundleRender orchestration' {
    It 'runs renderer per catalog entry for selected tech' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleRoot = Join-Path $repoRoot 'sample/66694360-25ba-40de-8fbd-07ebce431c53'
        $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-bundle-render-test-" + [guid]::NewGuid().ToString())
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -TechId 'Lenovo.DE'
            if ($LASTEXITCODE -ne 0) {
                throw "Expected exit code 0, got $LASTEXITCODE"
            }

            $report = $json | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }

            $bundleReportPath = Join-Path $outputRoot 'assembler-bundle-render-report.json'
            if (-not (Test-Path -LiteralPath $bundleReportPath -PathType Leaf)) {
                throw 'Expected bundle render report file'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
