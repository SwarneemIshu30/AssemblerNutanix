Describe 'Invoke-LnvAssemblerRender wrapper' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-LnvAssemblerRender.ps1'

        function New-MinimalWrapperInput {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("lnv-wrapper-test-" + [guid]::NewGuid().ToString('n'))
            $bundleRoot = Join-Path $root 'bundle'
            $configRoot = Join-Path $bundleRoot 'config'
            $outRoot = Join-Path $root 'out'
            New-Item -Path $configRoot -ItemType Directory -Force | Out-Null
            New-Item -Path $outRoot -ItemType Directory -Force | Out-Null

            Set-Content -LiteralPath (Join-Path $bundleRoot 'manifest.json') -Value '{"schemaVersion":"direct-v1","bundleId":"test"}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bundleRoot 'objectIndex.json') -Value '{"objects":[]}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $configRoot 'solution.plan.json') -Value '{"solutionId":"test","targets":[],"collectors":[]}' -Encoding UTF8

            $catalogPath = Join-Path $root 'catalog.json'
            Set-Content -LiteralPath $catalogPath -Value '{}' -Encoding UTF8

            [pscustomobject]@{
                Root = $root
                BundleRoot = $bundleRoot
                CatalogPath = $catalogPath
                OutputRoot = $outRoot
                ProgressPath = Join-Path $outRoot 'progress.jsonl'
                ReportPath = Join-Path $outRoot 'render-report.json'
                CancelSignalPath = Join-Path $outRoot '.assembler-render.cancel'
            }
        }

        function Invoke-Wrapper {
            param([Parameter(Mandatory = $true)]$InputRoot)

            $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $script:scriptPath `
                -BundleRoot $InputRoot.BundleRoot `
                -CatalogPath $InputRoot.CatalogPath `
                -OutputRoot $InputRoot.OutputRoot `
                -ProgressPath $InputRoot.ProgressPath `
                -ReportPath $InputRoot.ReportPath `
                -CancelSignalPath $InputRoot.CancelSignalPath 2>&1

            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = ($output -join [Environment]::NewLine)
            }
        }
    }

    It 'returns exit code 2 and writes a wrapper report for input validation failure' {
        $inputRoot = New-MinimalWrapperInput
        Remove-Item -LiteralPath $inputRoot.BundleRoot -Recurse -Force

        $result = Invoke-Wrapper -InputRoot $inputRoot
        if ([int]$result.ExitCode -ne 2) {
            throw "Expected exit code 2, got $($result.ExitCode): $($result.Output)"
        }
        if (-not (Test-Path -LiteralPath $inputRoot.ReportPath -PathType Leaf)) {
            throw 'Expected wrapper report to be written on input failure.'
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.status -ne 'ERROR') {
            throw "Expected ERROR wrapper status, got $($report.status)"
        }
        if ([string]$report.issues[0].code -ne 'ASB-ASM-WRAPPER-INPUT-FAILED') {
            throw "Expected input failure issue code, got $($report.issues[0].code)"
        }
    }

    It 'emits progress JSONL and returns exit code 130 when cancelled before backend render' {
        $inputRoot = New-MinimalWrapperInput
        Set-Content -LiteralPath $inputRoot.CancelSignalPath -Value 'cancel' -Encoding UTF8

        $result = Invoke-Wrapper -InputRoot $inputRoot
        if ([int]$result.ExitCode -ne 130) {
            throw "Expected exit code 130, got $($result.ExitCode): $($result.Output)"
        }
        $events = @(Get-Content -LiteralPath $inputRoot.ProgressPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        if (@($events).Count -eq 0) {
            throw 'Expected progress events.'
        }
        foreach ($key in @('timestampUtc','stage','level','status','percent','message','currentItem')) {
            if (-not $events[0].ContainsKey($key)) {
                throw "Expected progress event key '$key'."
            }
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.status -ne 'CANCELLED') {
            throw "Expected CANCELLED wrapper status, got $($report.status)"
        }
    }

    It 'propagates backend failure as exit code 1 without changing backend report naming' {
        $inputRoot = New-MinimalWrapperInput

        $result = Invoke-Wrapper -InputRoot $inputRoot
        if ([int]$result.ExitCode -ne 1) {
            throw "Expected exit code 1, got $($result.ExitCode): $($result.Output)"
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.backend.scriptPath -notmatch 'Invoke-AssemblerBundleRender\.ps1$') {
            throw "Expected backend script path to point at Invoke-AssemblerBundleRender.ps1, got $($report.backend.scriptPath)"
        }
        if (Test-Path -LiteralPath (Join-Path $inputRoot.OutputRoot 'render-report.json') -PathType Leaf) {
            return
        }
        throw 'Expected wrapper render-report.json to be present.'
    }
}
