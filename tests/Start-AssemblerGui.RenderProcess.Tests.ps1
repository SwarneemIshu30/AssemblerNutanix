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
}
