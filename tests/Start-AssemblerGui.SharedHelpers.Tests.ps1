Describe 'Start-AssemblerGui shared helper module' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:modulePath = Join-Path $script:repoRoot 'gui/internal/AssemblerGuiHelpers.psm1'
        Import-Module $script:modulePath -Force
    }

    It 'resolves default roots and catalog paths consistently' {
        $bundleRoot = Resolve-DefaultBundleRoot -RepoRoot $script:repoRoot
        $catalogPath = Resolve-DefaultCatalogPath -RepoRoot $script:repoRoot
        $contractsRoot = Resolve-DefaultContractsRoot -RepoRoot $script:repoRoot

        $stagingRoot = Join-Path $script:repoRoot 'bundle'
        $validChildBundles = @()
        if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
            $validChildBundles = @(Get-ChildItem -LiteralPath $stagingRoot -Directory | Where-Object {
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.yaml') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'objectIndex.json') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'config/solution.plan.json') -PathType Leaf)
                })
        }

        if ($validChildBundles.Count -gt 1) {
            if (-not [string]::IsNullOrWhiteSpace($bundleRoot)) {
                throw "Expected ambiguous bundle staging root to require operator selection, got '$bundleRoot'"
            }
        }
        elseif ([string]::IsNullOrWhiteSpace($bundleRoot) -or -not (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
            throw 'Expected bundle root to resolve to an existing container path when the repo has one valid candidate'
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

    It 'loads SupportRegion options from the Lenovo DE sidecar' {
        $catalogPath = Join-Path $script:repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'
        $sidecarPath = Resolve-SupportRegionSidecarPath -RepoRoot $script:repoRoot -CatalogPath $catalogPath
        if ([string]::IsNullOrWhiteSpace($sidecarPath) -or -not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
            throw 'Expected support-region sidecar to resolve for Lenovo.DE catalog.'
        }

        $options = @(Get-SupportRegionOptions -RepoRoot $script:repoRoot -CatalogPath $catalogPath)
        if (@($options | Where-Object { [string]$_.Id -eq 'AU' }).Count -ne 1) {
            throw 'Expected AU support region option.'
        }

        $resolved = Resolve-SupportRegionId -SupportRegion 'Australia' -Options $options
        if ($resolved -ne 'AU') {
            throw "Expected Australia label to resolve to AU, got '$resolved'."
        }
    }
}
