Describe 'Assembler GUI render process module' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $modulePath = Join-Path $script:repoRoot 'gui/internal/AssemblerGuiRenderProcess.psm1'
        Import-Module $modulePath -Force
    }

    It 'builds a wrapper invocation with safe argument list and sidecar paths' {
        $bundleRoot = Join-Path $TestDrive 'bundle root'
        $catalogPath = Join-Path (Join-Path $TestDrive 'catalogs') 'collector.catalog.json'
        $outputRoot = Join-Path $TestDrive 'out root'
        $contractsRoot = Join-Path $TestDrive 'contracts'

        $invocation = New-AssemblerGuiRenderInvocation `
            -RepoRoot $script:repoRoot `
            -BundleRoot $bundleRoot `
            -CatalogPath $catalogPath `
            -OutputRoot $outputRoot `
            -ContractsRoot $contractsRoot `
            -TechId @('Lenovo.DE') `
            -EntryId @('collector') `
            -OutputType @('docx') `
            -DocTitle 'Title With Spaces' `
            -DocSupportRegion 'AU' `
            -EnableDiagramRendering $true `
            -DocxMatchMode both `
            -UnresolvedTokenPolicy retain

        if (@($invocation.Arguments) -notcontains '-File') {
            throw 'Expected invocation to use -File.'
        }
        if (@($invocation.Arguments) -notcontains (Join-Path $script:repoRoot 'scripts/Invoke-LnvAssemblerRender.ps1')) {
            throw 'Expected invocation to point at Invoke-LnvAssemblerRender.ps1.'
        }
        if (@($invocation.Arguments) -notcontains '-ProgressPath') {
            throw 'Expected invocation to pass progress path.'
        }
        if ([string]$invocation.ProgressPath -ne (Join-Path $outputRoot 'progress.jsonl')) {
            throw "Unexpected progress path: $($invocation.ProgressPath)"
        }
        if ([string]$invocation.ReportPath -ne (Join-Path $outputRoot 'render-report.json')) {
            throw "Unexpected report path: $($invocation.ReportPath)"
        }
        if (@($invocation.Arguments) -notcontains '-DocSupportRegion' -or @($invocation.Arguments) -notcontains 'AU') {
            throw 'Expected invocation to pass DocSupportRegion.'
        }
        if (@($invocation.Arguments) -notcontains '-EnableDiagramRendering') {
            throw 'Expected invocation to pass EnableDiagramRendering when selected.'
        }
    }

    It 'passes archive selections as BundleArchivePath without BundleRoot' {
        $archivePath = Join-Path (Join-Path $TestDrive 'captures') 'capture.lnvbundle.zip'
        $catalogPath = Join-Path (Join-Path $TestDrive 'catalogs') 'collector.catalog.json'
        $outputRoot = Join-Path $TestDrive 'out root'
        $contractsRoot = Join-Path $TestDrive 'contracts'

        $invocation = New-AssemblerGuiRenderInvocation `
            -RepoRoot $script:repoRoot `
            -BundleArchivePath $archivePath `
            -CatalogPath $catalogPath `
            -OutputRoot $outputRoot `
            -ContractsRoot $contractsRoot

        if (@($invocation.Arguments) -notcontains '-BundleArchivePath') {
            throw 'Expected invocation to pass -BundleArchivePath.'
        }
        if (@($invocation.Arguments) -contains '-BundleRoot') {
            throw 'Archive invocation should not pass -BundleRoot.'
        }
        if (@($invocation.Arguments) -notcontains $archivePath) {
            throw 'Expected invocation to include archive path.'
        }
    }

    It 'keeps folder selections passed as BundleRoot without BundleArchivePath' {
        $bundleRoot = Join-Path $TestDrive 'bundle root'
        $catalogPath = Join-Path (Join-Path $TestDrive 'catalogs') 'collector.catalog.json'
        $outputRoot = Join-Path $TestDrive 'out root'
        $contractsRoot = Join-Path $TestDrive 'contracts'

        $invocation = New-AssemblerGuiRenderInvocation `
            -RepoRoot $script:repoRoot `
            -BundleRoot $bundleRoot `
            -CatalogPath $catalogPath `
            -OutputRoot $outputRoot `
            -ContractsRoot $contractsRoot

        if (@($invocation.Arguments) -notcontains '-BundleRoot') {
            throw 'Expected invocation to pass -BundleRoot.'
        }
        if (@($invocation.Arguments) -contains '-BundleArchivePath') {
            throw 'Folder invocation should not pass -BundleArchivePath.'
        }
        if (@($invocation.Arguments) -notcontains $bundleRoot) {
            throw 'Expected invocation to include folder bundle path.'
        }
    }

    It 'reads progress JSONL events' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lnv-progress-test-" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        $progressPath = Join-Path $tempRoot 'progress.jsonl'
        Set-Content -LiteralPath $progressPath -Value @(
            '{"timestampUtc":"2026-01-01T00:00:00Z","stage":"LoadPlan","level":"Info","status":"Running","percent":1,"message":"loading","currentItem":"plan"}'
            '{"timestampUtc":"2026-01-01T00:00:01Z","stage":"Complete","level":"Info","status":"Complete","percent":100,"message":"done","currentItem":"report"}'
        ) -Encoding UTF8

        $events = @(Read-AssemblerGuiProgressEvents -Path $progressPath)
        if ($events.Count -ne 2) {
            throw "Expected 2 progress events, got $($events.Count)"
        }
        if ([string]$events[1].stage -ne 'Complete') {
            throw "Expected Complete event, got $($events[1].stage)"
        }
    }

    It 'clears stale progress before starting a new render process' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lnv-render-start-test-" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        $progressPath = Join-Path $tempRoot 'progress.jsonl'
        $reportPath = Join-Path $tempRoot 'render-report.json'
        $cancelSignalPath = Join-Path $tempRoot '.assembler-render.cancel'
        Set-Content -LiteralPath $progressPath -Value '{"stage":"Failed","percent":100,"message":"stale failure"}' -Encoding UTF8

        $invocation = [pscustomobject]@{
            Arguments = @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 200')
            ProgressPath = $progressPath
            ReportPath = $reportPath
            CancelSignalPath = $cancelSignalPath
            WorkingDirectory = $script:repoRoot
        }

        $state = Start-AssemblerGuiRenderProcess -Invocation $invocation
        try {
            if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
                throw 'Expected stale progress file to be removed before process start.'
            }
        }
        finally {
            if ($null -ne $state -and $null -ne $state.Process -and -not $state.Process.HasExited) {
                $state.Process.Kill()
                $state.Process.WaitForExit()
            }
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
