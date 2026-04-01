Describe 'Start-AssemblerGui shared helper module' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'gui/internal/AssemblerGuiHelpers.psm1'
    Import-Module $modulePath -Force

    It 'resolves default roots and catalog paths consistently' {
        $bundleRoot = Resolve-DefaultBundleRoot -RepoRoot $repoRoot
        $catalogPath = Resolve-DefaultCatalogPath -RepoRoot $repoRoot
        $contractsRoot = Resolve-DefaultContractsRoot -RepoRoot $repoRoot

        if ([string]::IsNullOrWhiteSpace($bundleRoot) -or -not (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
            throw 'Expected bundle root to resolve to an existing container path'
        }
        if ([string]::IsNullOrWhiteSpace($catalogPath) -or -not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
            throw 'Expected catalog path to resolve to an existing catalog file'
        }
        if ([string]::IsNullOrWhiteSpace($contractsRoot)) {
            throw 'Expected contracts root to resolve to a non-empty path'
        }
    }

    It 'formats findings output consistently for both GUI wrappers via shared functions' {
        $bundleReport = [ordered]@{
            status = 'error'
            runs = @(
                [ordered]@{
                    entryId = 'collector'
                    rendererOutput = [ordered]@{
                        matches = @(
                            [ordered]@{ tag = 'LNV.Tag.One'; valuePreview = 'value-1' }
                        )
                        issues = @(
                            [ordered]@{ code = 'ASB-ASM-SDT-DOCX-NO-POPULATION'; severity = 'ERROR'; message = 'nested render failure' },
                                    [ordered]@{ code = 'ASB-ASM-DOCPROP-DOCX-NO-POPULATION'; severity = 'ERROR'; message = 'docprop render failure' }
                        )
                    }
                    variants = @(
                        [ordered]@{
                            reportPath = '/tmp/out/collector.render-report.json'
                            rendererOutput = [ordered]@{
                                issues = @(
                                    [ordered]@{ code = 'ASB-ASM-SDT-DOCX-NO-POPULATION'; severity = 'ERROR'; message = 'nested render failure' },
                                    [ordered]@{ code = 'ASB-ASM-DOCPROP-DOCX-NO-POPULATION'; severity = 'ERROR'; message = 'docprop render failure' }
                                )
                            }
                        }
                    )
                }
            )
            issues = @(
                [ordered]@{
                    code = 'ASB-ASM-BUNDLE-ENTRY-FAILED'
                    severity = 'ERROR'
                    path = '/tmp/out/collector.render-report.json'
                    message = 'wrapper issue'
                }
            )
        } | ConvertTo-Json -Depth 20

        $summary = Format-RenderFindingsSummary -BundleResultJson $bundleReport
        $verbose = Format-VerboseFindingsOutput -BundleResultJson $bundleReport
        $debug = Format-DebugBundleOutput -BundleResultJson $bundleReport

        if ($summary -notmatch 'Derived bundle wrapper failures: 1') {
            throw "Expected derived wrapper classification in summary, got: $summary"
        }
        if ($summary -notmatch 'Issues by code: ASB-ASM-DOCPROP-DOCX-NO-POPULATION=1, ASB-ASM-SDT-DOCX-NO-POPULATION=1') {
            throw "Expected issue code summary with distinct no-population codes, got: $summary"
        }
        if ($verbose -notmatch 'Found <LNV.Tag.One> = value-1') {
            throw "Expected matched tags in verbose output, got: $verbose"
        }
        if ($debug -notmatch 'Raw JSON:') {
            throw "Expected raw JSON marker in debug output, got: $debug"
        }
    }
}
