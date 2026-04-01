Set-StrictMode -Version Latest

function Resolve-DefaultBundleRoot {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $bundleStagingRoot = Join-Path $RepoRoot 'bundle'
    if (-not (Test-Path -LiteralPath $bundleStagingRoot -PathType Container)) {
        return $null
    }

    $directManifest = Join-Path $bundleStagingRoot 'manifest.json'
    $directObjectIndex = Join-Path $bundleStagingRoot 'objectIndex.json'
    $directSolutionPlan = Join-Path (Join-Path $bundleStagingRoot 'config') 'solution.plan.json'
    if ((Test-Path -LiteralPath $directManifest -PathType Leaf) -and (Test-Path -LiteralPath $directObjectIndex -PathType Leaf) -and (Test-Path -LiteralPath $directSolutionPlan -PathType Leaf)) {
        return $bundleStagingRoot
    }

    $bundleCandidates = @(
        Get-ChildItem -LiteralPath $bundleStagingRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'objectIndex.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'config/solution.plan.json') -PathType Leaf)
            } |
            Sort-Object -Property Name
    )

    if (@($bundleCandidates).Count -eq 1) {
        return [string]$bundleCandidates[0].FullName
    }

    return $null
}

function Resolve-DefaultCatalogPath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $preferredCatalogs = @(
        (Join-Path $RepoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'),
        (Join-Path $RepoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json')
    )

    foreach ($preferred in $preferredCatalogs) {
        if (Test-Path -LiteralPath $preferred -PathType Leaf) { return $preferred }
    }

    $firstCatalog = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'templates') -Recurse -Filter '*.catalog.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $firstCatalog) { return $firstCatalog.FullName }

    return $null
}

function Resolve-DefaultContractsRoot {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $candidate = Join-Path $RepoRoot '.deps/contracts'
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        return $candidate
    }

    return $candidate
}

function Format-MatchedTagsSummary {
    param([Parameter(Mandatory = $true)][string]$BundleResultJson)

    try {
        $bundleReport = $BundleResultJson | ConvertFrom-Json -AsHashtable
    }
    catch {
        return ''
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($run in @($bundleReport.runs)) {
        $entryId = [string]$run.entryId
        $matched = @()
        if ($run.ContainsKey('rendererOutput') -and $null -ne $run.rendererOutput -and $run.rendererOutput.ContainsKey('matches')) {
            $matched = @($run.rendererOutput.matches)
        }
        if (@($matched).Count -eq 0) { continue }

        $lines.Add("Matched fields for entry '$entryId':")
        foreach ($m in $matched) {
            $tag = [string]$m.tag
            $preview = [string]$m.valuePreview
            $lines.Add("  Found <$tag> = $preview")
        }
        $lines.Add('')
    }

    if ($lines.Count -eq 0) { return '' }
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Test-IsDerivedBundleWrapperIssue {
    param(
        [Parameter(Mandatory = $true)]$Issue,
        [Parameter(Mandatory = $false)]$BundleReport
    )

    if ($null -eq $Issue) { return $false }
    if ([string]$Issue.code -ne 'ASB-ASM-BUNDLE-ENTRY-FAILED') { return $false }
    if ($null -eq $BundleReport -or -not $BundleReport.ContainsKey('runs')) { return $false }

    $issuePath = [string]$Issue.path
    foreach ($run in @($BundleReport.runs)) {
        foreach ($variant in @($run.variants)) {
            if ([string]$variant.reportPath -ne $issuePath) { continue }
            if ($variant.ContainsKey('rendererOutput') -and $null -ne $variant.rendererOutput -and $variant.rendererOutput -is [System.Collections.IDictionary] -and $variant.rendererOutput.ContainsKey('issues') -and @($variant.rendererOutput.issues).Count -gt 0) {
                return $true
            }
        }
    }

    return $false
}

function Get-RootCauseIssueSummary {
    param([Parameter(Mandatory = $true)]$BundleReport)

    $issueCounts = @{}
    $issueCodeCounts = @{}
    $derivedWrapperCount = 0
    $firstIssueMessage = ''

    foreach ($run in @($BundleReport.runs)) {
        if ($run.ContainsKey('rendererOutput') -and $null -ne $run.rendererOutput) {
            if ($run.rendererOutput.ContainsKey('issues')) {
                foreach ($issue in @($run.rendererOutput.issues)) {
                    $severity = [string]$issue.severity
                    if ([string]::IsNullOrWhiteSpace($severity)) { $severity = 'UNKNOWN' }
                    if (-not $issueCounts.ContainsKey($severity)) { $issueCounts[$severity] = 0 }
                    $issueCounts[$severity]++

                    $code = [string]$issue.code
                    if ([string]::IsNullOrWhiteSpace($code)) { $code = 'UNKNOWN' }
                    if (-not $issueCodeCounts.ContainsKey($code)) { $issueCodeCounts[$code] = 0 }
                    $issueCodeCounts[$code]++

                    if ([string]::IsNullOrWhiteSpace($firstIssueMessage)) {
                        $firstIssueMessage = [string]$issue.message
                    }
                }
            }
        }
    }

    foreach ($issue in @($BundleReport.issues)) {
        if (Test-IsDerivedBundleWrapperIssue -Issue $issue -BundleReport $BundleReport) {
            $derivedWrapperCount++
            continue
        }

        $severity = [string]$issue.severity
        if ([string]::IsNullOrWhiteSpace($severity)) { $severity = 'UNKNOWN' }
        if (-not $issueCounts.ContainsKey($severity)) { $issueCounts[$severity] = 0 }
        $issueCounts[$severity]++

        $code = [string]$issue.code
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'UNKNOWN' }
        if (-not $issueCodeCounts.ContainsKey($code)) { $issueCodeCounts[$code] = 0 }
        $issueCodeCounts[$code]++

        if ([string]::IsNullOrWhiteSpace($firstIssueMessage)) {
            $firstIssueMessage = [string]$issue.message
        }
    }

    return [ordered]@{
        issueCounts = $issueCounts
        issueCodeCounts = $issueCodeCounts
        derivedWrapperCount = $derivedWrapperCount
        firstIssueMessage = $firstIssueMessage
    }
}

function Format-RenderFindingsSummary {
    param([Parameter(Mandatory = $true)][string]$BundleResultJson)

    try {
        $bundleReport = $BundleResultJson | ConvertFrom-Json -AsHashtable
    }
    catch {
        return 'Findings summary unavailable: unable to parse render output JSON.'
    }

    $runCount = @($bundleReport.runs).Count
    $totalMatches = 0
    $rootCauseSummary = Get-RootCauseIssueSummary -BundleReport $bundleReport
    $issueCounts = $rootCauseSummary.issueCounts
    $issueCodeCounts = $rootCauseSummary.issueCodeCounts

    foreach ($run in @($bundleReport.runs)) {
        if ($run.ContainsKey('rendererOutput') -and $null -ne $run.rendererOutput -and $run.rendererOutput.ContainsKey('matches')) {
            $totalMatches += @($run.rendererOutput.matches).Count
        }
    }

    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add('Findings summary:')
    $summaryLines.Add("  Overall status: $($bundleReport.status)")
    $summaryLines.Add("  Runs: $runCount")
    $summaryLines.Add("  Matched tags: $totalMatches")

    if ($issueCounts.Count -eq 0) {
        $summaryLines.Add('  Issues: none')
    }
    else {
        $issueSegments = @($issueCounts.Keys | Sort-Object | ForEach-Object { "$_=$($issueCounts[$_])" })
        $summaryLines.Add("  Issues by severity: $($issueSegments -join ', ')")

        if ($issueCodeCounts.Count -gt 0) {
            $codeSegments = @($issueCodeCounts.Keys | Sort-Object | ForEach-Object { "$_=$($issueCodeCounts[$_])" })
            $summaryLines.Add("  Issues by code: $($codeSegments -join ', ')")
        }

        if ($rootCauseSummary.derivedWrapperCount -gt 0) {
            $summaryLines.Add("  Derived bundle wrapper failures: $($rootCauseSummary.derivedWrapperCount) (see nested renderer report issues)")
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$rootCauseSummary.firstIssueMessage)) {
            $summaryLines.Add("  First issue: $([string]$rootCauseSummary.firstIssueMessage)")
        }
    }

    return ($summaryLines -join [Environment]::NewLine)
}

function Format-VerboseFindingsOutput {
    param([Parameter(Mandatory = $true)][string]$BundleResultJson)

    $summary = Format-RenderFindingsSummary -BundleResultJson $BundleResultJson
    $matchSummary = Format-MatchedTagsSummary -BundleResultJson $BundleResultJson
    if ([string]::IsNullOrWhiteSpace($matchSummary)) { return $summary }

    return @(
        $summary
        ''
        $matchSummary.TrimEnd()
    ) -join [Environment]::NewLine
}

function Format-DebugBundleOutput {
    param([Parameter(Mandatory = $true)][string]$BundleResultJson)

    $prettyJson = $BundleResultJson
    try {
        $prettyJson = ($BundleResultJson | ConvertFrom-Json | ConvertTo-Json -Depth 100)
    }
    catch {
        # Keep raw output when conversion fails.
    }

    $verbose = Format-VerboseFindingsOutput -BundleResultJson $BundleResultJson

    return @(
        $verbose
        ''
        'Raw JSON:'
        $prettyJson
    ) -join [Environment]::NewLine
}

Export-ModuleMember -Function @(
    'Resolve-DefaultBundleRoot',
    'Resolve-DefaultCatalogPath',
    'Resolve-DefaultContractsRoot',
    'Format-MatchedTagsSummary',
    'Test-IsDerivedBundleWrapperIssue',
    'Get-RootCauseIssueSummary',
    'Format-RenderFindingsSummary',
    'Format-VerboseFindingsOutput',
    'Format-DebugBundleOutput'
)
