Describe 'Assembler GUI render process module' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $modulePath = Join-Path $script:repoRoot 'gui/internal/AssemblerGuiRenderProcess.psm1'
        Import-Module $modulePath -Force
    }

    It 'builds a wrapper invocation with safe argument list and sidecar paths' {
        $invocation = New-AssemblerGuiRenderInvocation `
            -RepoRoot $script:repoRoot `
            -BundleRoot 'C:\bundle root' `
            -CatalogPath 'C:\catalogs\collector.catalog.json' `
            -OutputRoot 'C:\out root' `
            -ContractsRoot 'C:\contracts' `
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
        if ([string]$invocation.ProgressPath -ne 'C:\out root\progress.jsonl') {
            throw "Unexpected progress path: $($invocation.ProgressPath)"
        }
        if ([string]$invocation.ReportPath -ne 'C:\out root\render-report.json') {
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
        $invocation = New-AssemblerGuiRenderInvocation `
            -RepoRoot $script:repoRoot `
            -BundleArchivePath 'C:\captures\capture.lnvbundle.zip' `
            -CatalogPath 'C:\catalogs\collector.catalog.json' `
            -OutputRoot 'C:\out root' `
            -ContractsRoot 'C:\contracts'

        if (@($invocation.Arguments) -notcontains '-BundleArchivePath') {
            throw 'Expected invocation to pass -BundleArchivePath.'
        }
        if (@($invocation.Arguments) -contains '-BundleRoot') {
            throw 'Archive invocation should not pass -BundleRoot.'
        }
        if (@($invocation.Arguments) -notcontains 'C:\captures\capture.lnvbundle.zip') {
            throw 'Expected invocation to include archive path.'
        }
    }

    It 'keeps folder selections passed as BundleRoot without BundleArchivePath' {
        $invocation = New-AssemblerGuiRenderInvocation `
            -RepoRoot $script:repoRoot `
            -BundleRoot 'C:\bundle root' `
            -CatalogPath 'C:\catalogs\collector.catalog.json' `
            -OutputRoot 'C:\out root' `
            -ContractsRoot 'C:\contracts'

        if (@($invocation.Arguments) -notcontains '-BundleRoot') {
            throw 'Expected invocation to pass -BundleRoot.'
        }
        if (@($invocation.Arguments) -contains '-BundleArchivePath') {
            throw 'Folder invocation should not pass -BundleArchivePath.'
        }
        if (@($invocation.Arguments) -notcontains 'C:\bundle root') {
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
