#!/usr/bin/env pwsh
<#
.SYNOPSIS
Canonical CLI/GUI render wrapper for the assembler runtime.

.DESCRIPTION
Supervises the existing Invoke-AssemblerBundleRender.ps1 backend without changing
assembler rendering semantics. The wrapper emits progress.jsonl, writes a
wrapper-level render-report.json, and returns stable process exit codes for CLI
and WPF callers.
#>
param(
    [Parameter(Mandatory = $false)][string]$BundleRoot,
    [Parameter(Mandatory = $false)][string]$BundleArchivePath,
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $false)][string]$ContractsRoot,
    [Parameter(Mandatory = $false)][string[]]$TechId,
    [Parameter(Mandatory = $false)][string[]]$EntryId,
    [Parameter(Mandatory = $false)][ValidateSet('docx','text')][string[]]$OutputType,
    [Parameter(Mandatory = $false)][string]$CompositionMapPath,
    [Parameter(Mandatory = $false)][string]$DocTitle,
    [Parameter(Mandatory = $false)][string]$DocCustomer,
    [Parameter(Mandatory = $false)][string]$DocCustomerAbbr,
    [Parameter(Mandatory = $false)][string]$DocLocation,
    [Parameter(Mandatory = $false)][string]$DocSubsidiary,
    [Parameter(Mandatory = $false)][string]$DocEnvironment,
    [Parameter(Mandatory = $false)][string]$DocDocumentReference,
    [Parameter(Mandatory = $false)][string]$DocVersion,
    [Parameter(Mandatory = $false)][string]$DocConfigSnapDate,
    [Parameter(Mandatory = $false)][string]$DocReferenceId,
    [Parameter(Mandatory = $false)][string]$DocClassification,
    [Parameter(Mandatory = $false)][string]$DocSupportRegion,
    [Parameter(Mandatory = $false)][string]$DocSupportTier,
    [Parameter(Mandatory = $false)][switch]$AnnotateResolvedTags,
    [Parameter(Mandatory = $false)][switch]$EnableDiagramRendering,
    [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
    [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain',
    [Parameter(Mandatory = $false)][string]$ProgressPath,
    [Parameter(Mandatory = $false)][string]$ReportPath,
    [Parameter(Mandatory = $false)][string]$CancelSignalPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerProgress.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerBundleArchive.psm1') -Force

function Get-UtcTimestamp { (Get-Date).ToUniversalTime().ToString('o') }

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Add-IfValue {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IList]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)]$Value
    )

    if ($null -eq $Value) { return }
    if ($Value -is [array]) {
        $items = @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($items.Count -eq 0) { return }
        [void]$Arguments.Add($Name)
        foreach ($item in $items) { [void]$Arguments.Add([string]$item) }
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return }
    [void]$Arguments.Add($Name)
    [void]$Arguments.Add([string]$Value)
}

function New-WrapperIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$Path
    )

    [ordered]@{
        code = $Code
        severity = $Severity
        message = $Message
        path = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
    }
}

$startedUtc = Get-UtcTimestamp
$exitCode = 1
$status = 'ERROR'
$backendExitCode = $null
$backendStdout = ''
$backendStderr = ''
$backendArguments = @()
$backendReport = $null
$backendReportPath = $null
$archiveImport = $null
$resolvedBundleRoot = $null
$wrapperFailureIssueCode = $null
$issues = [System.Collections.Generic.List[hashtable]]::new()
$progressEvents = @()
$resolvedOutputRoot = $OutputRoot

try {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        throw 'OutputRoot is required.'
    }
    Ensure-Directory -Path $OutputRoot
    $resolvedOutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

    if ([string]::IsNullOrWhiteSpace($ProgressPath)) {
        $ProgressPath = Join-Path $resolvedOutputRoot 'progress.jsonl'
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $ReportPath = Join-Path $resolvedOutputRoot 'render-report.json'
    }

    Set-Content -LiteralPath $ProgressPath -Value $null -Encoding UTF8

    $bundleRootProvided = -not [string]::IsNullOrWhiteSpace($BundleRoot)
    $archiveProvided = -not [string]::IsNullOrWhiteSpace($BundleArchivePath)
    if ($bundleRootProvided -and $archiveProvided) {
        $exitCode = 2
        throw 'BundleRoot and BundleArchivePath are mutually exclusive.'
    }
    if (-not $bundleRootProvided -and -not $archiveProvided) {
        $exitCode = 2
        throw 'Either BundleRoot or BundleArchivePath is required.'
    }

    if ($archiveProvided) {
        Write-AssemblerProgressEvent -Path $ProgressPath -Stage ImportBundleArchive -Level Info -Status Running -Percent 2 -Message 'Importing bundle archive.' -CurrentItem $BundleArchivePath | Out-Null
        $archiveResult = Import-AssemblerBundleArchive -ArchivePath $BundleArchivePath -RepoRoot (Split-Path -Parent $PSScriptRoot)
        $archiveImport = [ordered]@{
            sourceArchivePath = $archiveResult.SourceArchivePath
            archiveSha256 = $archiveResult.ArchiveSha256
            extractedBundleRoot = $archiveResult.ExtractedBundleRoot
            bundleId = $archiveResult.BundleId
            bundleHash = $archiveResult.BundleHash
            status = $archiveResult.Status
            errors = @($archiveResult.Errors)
        }
        if (-not $archiveResult.IsValid) {
            $exitCode = 2
            $wrapperFailureIssueCode = 'ASB-ASM-WRAPPER-ARCHIVE-IMPORT-FAILED'
            Write-AssemblerProgressEvent -Path $ProgressPath -Stage ImportBundleArchive -Level Error -Status Failed -Percent 5 -Message "Bundle archive import failed: $(@($archiveResult.Errors) -join '; ')" -CurrentItem $BundleArchivePath | Out-Null
            throw "Bundle archive import failed: $(@($archiveResult.Errors) -join '; ')"
        }
        $resolvedBundleRoot = [string]$archiveResult.ExtractedBundleRoot
        Write-AssemblerProgressEvent -Path $ProgressPath -Stage ImportBundleArchive -Level Info -Status Complete -Percent 6 -Message 'Bundle archive imported and verified.' -CurrentItem $resolvedBundleRoot | Out-Null
    }

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage LoadPlan -Level Info -Status Running -Percent 8 -Message 'Resolving solution plan path.' -CurrentItem $(if ($archiveProvided) { $resolvedBundleRoot } else { $BundleRoot }) | Out-Null

    if (-not $archiveProvided -and ([string]::IsNullOrWhiteSpace($BundleRoot) -or -not (Test-Path -LiteralPath $BundleRoot -PathType Container))) {
        $exitCode = 2
        throw "BundleRoot not found: $BundleRoot"
    }
    if (-not $archiveProvided) {
        $resolvedBundleRoot = (Resolve-Path -LiteralPath $BundleRoot).Path
    }
    $solutionPlanPath = Join-Path (Join-Path $resolvedBundleRoot 'config') 'solution.plan.json'
    if (-not (Test-Path -LiteralPath $solutionPlanPath -PathType Leaf)) {
        $exitCode = 2
        throw "solution.plan.json not found: $solutionPlanPath"
    }
    Write-AssemblerProgressEvent -Path $ProgressPath -Stage LoadPlan -Level Info -Status Complete -Percent 10 -Message 'Resolved solution plan.' -CurrentItem $solutionPlanPath | Out-Null

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage ValidatePlan -Level Info -Status Running -Percent 12 -Message 'Validating required plan artifact readability.' -CurrentItem $solutionPlanPath | Out-Null
    $null = Get-Content -LiteralPath $solutionPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-AssemblerProgressEvent -Path $ProgressPath -Stage ValidatePlan -Level Info -Status Complete -Percent 15 -Message 'Plan artifact is readable JSON.' -CurrentItem $solutionPlanPath | Out-Null

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage LoadBundle -Level Info -Status Running -Percent 18 -Message 'Resolving bundle manifest and object index.' -CurrentItem $resolvedBundleRoot | Out-Null
    foreach ($requiredBundleFile in @('manifest.json', 'objectIndex.json')) {
        $candidate = Join-Path $resolvedBundleRoot $requiredBundleFile
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $exitCode = 2
            throw "Required bundle file not found: $candidate"
        }
    }
    Write-AssemblerProgressEvent -Path $ProgressPath -Stage LoadBundle -Level Info -Status Complete -Percent 25 -Message 'Bundle artifacts resolved.' -CurrentItem $resolvedBundleRoot | Out-Null

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage ValidateBundle -Level Info -Status Running -Percent 28 -Message 'Validating bundle JSON readability.' -CurrentItem $resolvedBundleRoot | Out-Null
    $null = Get-Content -LiteralPath (Join-Path $resolvedBundleRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $null = Get-Content -LiteralPath (Join-Path $resolvedBundleRoot 'objectIndex.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-AssemblerProgressEvent -Path $ProgressPath -Stage ValidateBundle -Level Info -Status Complete -Percent 35 -Message 'Bundle JSON artifacts are readable.' -CurrentItem $resolvedBundleRoot | Out-Null

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage LoadTemplate -Level Info -Status Running -Percent 38 -Message 'Resolving render catalog.' -CurrentItem $CatalogPath | Out-Null
    if ([string]::IsNullOrWhiteSpace($CatalogPath) -or -not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        $exitCode = 2
        throw "CatalogPath not found: $CatalogPath"
    }
    $resolvedCatalogPath = (Resolve-Path -LiteralPath $CatalogPath).Path
    $null = Get-Content -LiteralPath $resolvedCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-AssemblerProgressEvent -Path $ProgressPath -Stage LoadTemplate -Level Info -Status Complete -Percent 45 -Message 'Render catalog is readable.' -CurrentItem $resolvedCatalogPath | Out-Null

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage ResolveMappings -Level Info -Status Complete -Percent 50 -Message 'Mapping resolution remains delegated to bundle renderer.' -CurrentItem $resolvedCatalogPath | Out-Null
    Write-AssemblerProgressEvent -Path $ProgressPath -Stage ValidateSdtTargets -Level Info -Status Complete -Percent 55 -Message 'SDT target validation remains delegated to bundle renderer.' -CurrentItem $resolvedCatalogPath | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($CancelSignalPath) -and (Test-Path -LiteralPath $CancelSignalPath -PathType Leaf)) {
        $exitCode = 130
        throw 'Render cancelled before backend execution.'
    }

    $invokeBundleRenderScript = Join-Path $PSScriptRoot 'Invoke-AssemblerBundleRender.ps1'
    if (-not (Test-Path -LiteralPath $invokeBundleRenderScript -PathType Leaf)) {
        $exitCode = 2
        throw "Backend render script not found: $invokeBundleRenderScript"
    }

    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace([string]$pwshPath)) {
        $exitCode = 2
        throw 'pwsh is required to execute backend render.'
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $invokeBundleRenderScript)) {
        [void]$arguments.Add($arg)
    }
    Add-IfValue -Arguments $arguments -Name '-BundleRoot' -Value $resolvedBundleRoot
    Add-IfValue -Arguments $arguments -Name '-CatalogPath' -Value $resolvedCatalogPath
    Add-IfValue -Arguments $arguments -Name '-OutputRoot' -Value $resolvedOutputRoot
    Add-IfValue -Arguments $arguments -Name '-ContractsRoot' -Value $ContractsRoot
    Add-IfValue -Arguments $arguments -Name '-TechId' -Value $TechId
    Add-IfValue -Arguments $arguments -Name '-EntryId' -Value $EntryId
    Add-IfValue -Arguments $arguments -Name '-OutputType' -Value $OutputType
    Add-IfValue -Arguments $arguments -Name '-CompositionMapPath' -Value $CompositionMapPath
    Add-IfValue -Arguments $arguments -Name '-DocTitle' -Value $DocTitle
    Add-IfValue -Arguments $arguments -Name '-DocCustomer' -Value $DocCustomer
    Add-IfValue -Arguments $arguments -Name '-DocCustomerAbbr' -Value $DocCustomerAbbr
    Add-IfValue -Arguments $arguments -Name '-DocLocation' -Value $DocLocation
    Add-IfValue -Arguments $arguments -Name '-DocSubsidiary' -Value $DocSubsidiary
    Add-IfValue -Arguments $arguments -Name '-DocEnvironment' -Value $DocEnvironment
    Add-IfValue -Arguments $arguments -Name '-DocDocumentReference' -Value $DocDocumentReference
    Add-IfValue -Arguments $arguments -Name '-DocVersion' -Value $DocVersion
    Add-IfValue -Arguments $arguments -Name '-DocConfigSnapDate' -Value $DocConfigSnapDate
    Add-IfValue -Arguments $arguments -Name '-DocReferenceId' -Value $DocReferenceId
    Add-IfValue -Arguments $arguments -Name '-DocClassification' -Value $DocClassification
    Add-IfValue -Arguments $arguments -Name '-DocSupportRegion' -Value $DocSupportRegion
    Add-IfValue -Arguments $arguments -Name '-DocSupportTier' -Value $DocSupportTier
    if ($AnnotateResolvedTags) { [void]$arguments.Add('-AnnotateResolvedTags') }
    if ($EnableDiagramRendering) { [void]$arguments.Add('-EnableDiagramRendering') }
    Add-IfValue -Arguments $arguments -Name '-DocxMatchMode' -Value $DocxMatchMode
    Add-IfValue -Arguments $arguments -Name '-UnresolvedTokenPolicy' -Value $UnresolvedTokenPolicy
    $backendArguments = @($arguments)

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage RenderDocument -Level Info -Status Running -Percent 60 -Message 'Starting backend bundle render.' -CurrentItem $invokeBundleRenderScript | Out-Null

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = (Split-Path -Parent $PSScriptRoot)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    while (-not $process.WaitForExit(250)) {
        if (-not [string]::IsNullOrWhiteSpace($CancelSignalPath) -and (Test-Path -LiteralPath $CancelSignalPath -PathType Leaf)) {
            Write-AssemblerProgressEvent -Path $ProgressPath -Stage Cancelled -Level Warn -Status Running -Percent 95 -Message 'Cancel signal received; terminating backend render.' -CurrentItem $CancelSignalPath | Out-Null
            try {
                $process.Kill($true)
            }
            catch {
                $process.Kill()
            }
            $process.WaitForExit()
            $exitCode = 130
            throw 'Render cancelled.'
        }
    }

    $process.WaitForExit()
    $backendExitCode = [int]$process.ExitCode
    $backendStdout = $stdoutTask.GetAwaiter().GetResult().Trim()
    $backendStderr = $stderrTask.GetAwaiter().GetResult().Trim()

    if (-not [string]::IsNullOrWhiteSpace($backendStdout)) {
        try {
            $backendReport = $backendStdout | ConvertFrom-Json -AsHashtable
        }
        catch {
            $issues.Add((New-WrapperIssue -Code 'ASB-ASM-WRAPPER-BACKEND-STDOUT-INVALIDJSON' -Severity 'WARN' -Message $_.Exception.Message -Path $null))
        }
    }

    $candidateBackendReportPath = Join-Path $resolvedOutputRoot 'assembler-bundle-render-report.json'
    if (Test-Path -LiteralPath $candidateBackendReportPath -PathType Leaf) {
        $backendReportPath = (Resolve-Path -LiteralPath $candidateBackendReportPath).Path
    }

    if ($backendExitCode -ne 0) {
        $exitCode = 1
        throw "Backend render exited with code $backendExitCode."
    }

    $status = if ($null -ne $backendReport -and $backendReport.ContainsKey('status')) {
        switch ([string]$backendReport.status) {
            'ERROR' { 'ERROR' }
            'PARTIAL' { 'PARTIAL' }
            default { 'OK' }
        }
    }
    else {
        'OK'
    }

    if ($status -eq 'ERROR') {
        $exitCode = 1
    }
    else {
        $exitCode = 0
    }

    Write-AssemblerProgressEvent -Path $ProgressPath -Stage RenderDocument -Level Info -Status Complete -Percent 90 -Message "Backend bundle render completed with status $status." -CurrentItem $backendReportPath | Out-Null
    Write-AssemblerProgressEvent -Path $ProgressPath -Stage WriteReports -Level Info -Status Running -Percent 96 -Message 'Writing wrapper render report.' -CurrentItem $ReportPath | Out-Null
}
catch {
    if ($exitCode -eq 0) { $exitCode = 1 }
    if ($exitCode -eq 130) {
        $status = 'CANCELLED'
        if (-not [string]::IsNullOrWhiteSpace($ProgressPath)) {
            Write-AssemblerProgressEvent -Path $ProgressPath -Stage Cancelled -Level Warn -Status Failed -Percent 100 -Message $_.Exception.Message -CurrentItem $CancelSignalPath | Out-Null
        }
        $issues.Add((New-WrapperIssue -Code 'ASB-ASM-WRAPPER-CANCELLED' -Severity 'WARN' -Message $_.Exception.Message -Path $CancelSignalPath))
    }
    else {
        $status = 'ERROR'
        if (-not [string]::IsNullOrWhiteSpace($ProgressPath)) {
            Write-AssemblerProgressEvent -Path $ProgressPath -Stage Failed -Level Error -Status Failed -Percent 100 -Message $_.Exception.Message -CurrentItem '' | Out-Null
        }
        $issueCode = if (-not [string]::IsNullOrWhiteSpace($wrapperFailureIssueCode)) {
            $wrapperFailureIssueCode
        }
        elseif ($exitCode -eq 2) {
            'ASB-ASM-WRAPPER-INPUT-FAILED'
        }
        else {
            'ASB-ASM-WRAPPER-RENDER-FAILED'
        }
        $issues.Add((New-WrapperIssue -Code $issueCode -Severity 'ERROR' -Message $_.Exception.Message -Path $null))
    }
}
finally {
    if ([string]::IsNullOrWhiteSpace($ProgressPath)) {
        $ProgressPath = Join-Path $resolvedOutputRoot 'progress.jsonl'
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $ReportPath = Join-Path $resolvedOutputRoot 'render-report.json'
    }

    try {
        $progressEvents = @(Read-AssemblerProgressEvents -Path $ProgressPath)
    }
    catch {
        $progressEvents = @()
    }

    $report = [ordered]@{
        schemaVersion = 1
        status = $status
        exitCode = $exitCode
        startedUtc = $startedUtc
        completedUtc = Get-UtcTimestamp
        bundleRoot = $BundleRoot
        bundleArchivePath = if ([string]::IsNullOrWhiteSpace($BundleArchivePath)) { $null } else { $BundleArchivePath }
        effectiveBundleRoot = $resolvedBundleRoot
        catalogPath = $CatalogPath
        outputRoot = $OutputRoot
        progressPath = $ProgressPath
        reportPath = $ReportPath
        cancelSignalPath = if ([string]::IsNullOrWhiteSpace($CancelSignalPath)) { $null } else { $CancelSignalPath }
        backend = [ordered]@{
            scriptPath = Join-Path $PSScriptRoot 'Invoke-AssemblerBundleRender.ps1'
            arguments = @($backendArguments)
            exitCode = $backendExitCode
            reportPath = $backendReportPath
            stdout = $backendStdout
            stderr = $backendStderr
        }
        filters = [ordered]@{
            techId = @($TechId)
            entryId = @($EntryId)
            outputType = @($OutputType)
            compositionMapPath = $CompositionMapPath
        }
        progress = @($progressEvents)
        issues = @($issues)
    }

    if ($null -ne $backendReport) {
        $report.backend['report'] = $backendReport
    }
    if ($null -ne $archiveImport) {
        $report['archiveImport'] = $archiveImport
    }

    $reportParent = Split-Path -Path $ReportPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($reportParent) -and -not (Test-Path -LiteralPath $reportParent -PathType Container)) {
        New-Item -Path $reportParent -ItemType Directory -Force | Out-Null
    }

    $reportJson = $report | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $ReportPath -Value $reportJson -Encoding UTF8

    if ($status -eq 'OK' -or $status -eq 'PARTIAL') {
        Write-AssemblerProgressEvent -Path $ProgressPath -Stage WriteReports -Level Info -Status Complete -Percent 98 -Message 'Wrapper render report written.' -CurrentItem $ReportPath | Out-Null
        Write-AssemblerProgressEvent -Path $ProgressPath -Stage Complete -Level Info -Status Complete -Percent 100 -Message "Render wrapper completed with status $status." -CurrentItem $ReportPath | Out-Null
        $progressEvents = @(Read-AssemblerProgressEvents -Path $ProgressPath)
        $report.progress = @($progressEvents)
        $reportJson = $report | ConvertTo-Json -Depth 20
        Set-Content -LiteralPath $ReportPath -Value $reportJson -Encoding UTF8
    }

    $reportJson
}

exit $exitCode
