Set-StrictMode -Version Latest

function Add-ArgumentValue {
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

function Test-DictionaryHasKey {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ($Map -is [hashtable]) { return $Map.ContainsKey($Key) }
    return $Map.Contains($Key)
}

function New-AssemblerGuiRenderInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$BundleRoot,
        [Parameter(Mandatory = $false)][string]$BundleArchivePath,
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $false)][string[]]$TechId,
        [Parameter(Mandatory = $false)][string[]]$EntryId,
        [Parameter(Mandatory = $false)][string[]]$OutputType,
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
        [Parameter(Mandatory = $false)][bool]$AnnotateResolvedTags = $false,
        [Parameter(Mandatory = $false)][bool]$EnableDiagramRendering = $false,
        [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
        [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
    )

    $wrapperScript = Join-Path $RepoRoot 'scripts/Invoke-LnvAssemblerRender.ps1'
    $progressPath = Join-Path $OutputRoot 'progress.jsonl'
    $reportPath = Join-Path $OutputRoot 'render-report.json'
    $cancelSignalPath = Join-Path $OutputRoot '.assembler-render.cancel'

    $bundleRootProvided = -not [string]::IsNullOrWhiteSpace($BundleRoot)
    $archiveProvided = -not [string]::IsNullOrWhiteSpace($BundleArchivePath)
    if ($bundleRootProvided -and $archiveProvided) {
        throw 'BundleRoot and BundleArchivePath are mutually exclusive.'
    }
    if (-not $bundleRootProvided -and -not $archiveProvided) {
        throw 'Either BundleRoot or BundleArchivePath is required.'
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)) {
        [void]$arguments.Add($argument)
    }

    if ($archiveProvided) {
        Add-ArgumentValue -Arguments $arguments -Name '-BundleArchivePath' -Value $BundleArchivePath
    }
    else {
        Add-ArgumentValue -Arguments $arguments -Name '-BundleRoot' -Value $BundleRoot
    }
    Add-ArgumentValue -Arguments $arguments -Name '-CatalogPath' -Value $CatalogPath
    Add-ArgumentValue -Arguments $arguments -Name '-OutputRoot' -Value $OutputRoot
    Add-ArgumentValue -Arguments $arguments -Name '-ContractsRoot' -Value $ContractsRoot
    Add-ArgumentValue -Arguments $arguments -Name '-TechId' -Value $TechId
    Add-ArgumentValue -Arguments $arguments -Name '-EntryId' -Value $EntryId
    Add-ArgumentValue -Arguments $arguments -Name '-OutputType' -Value $OutputType
    Add-ArgumentValue -Arguments $arguments -Name '-CompositionMapPath' -Value $CompositionMapPath
    Add-ArgumentValue -Arguments $arguments -Name '-DocTitle' -Value $DocTitle
    Add-ArgumentValue -Arguments $arguments -Name '-DocCustomer' -Value $DocCustomer
    Add-ArgumentValue -Arguments $arguments -Name '-DocCustomerAbbr' -Value $DocCustomerAbbr
    Add-ArgumentValue -Arguments $arguments -Name '-DocLocation' -Value $DocLocation
    Add-ArgumentValue -Arguments $arguments -Name '-DocSubsidiary' -Value $DocSubsidiary
    Add-ArgumentValue -Arguments $arguments -Name '-DocEnvironment' -Value $DocEnvironment
    Add-ArgumentValue -Arguments $arguments -Name '-DocDocumentReference' -Value $DocDocumentReference
    Add-ArgumentValue -Arguments $arguments -Name '-DocVersion' -Value $DocVersion
    Add-ArgumentValue -Arguments $arguments -Name '-DocConfigSnapDate' -Value $DocConfigSnapDate
    Add-ArgumentValue -Arguments $arguments -Name '-DocReferenceId' -Value $DocReferenceId
    Add-ArgumentValue -Arguments $arguments -Name '-DocClassification' -Value $DocClassification
    Add-ArgumentValue -Arguments $arguments -Name '-DocSupportRegion' -Value $DocSupportRegion
    Add-ArgumentValue -Arguments $arguments -Name '-DocSupportTier' -Value $DocSupportTier
    if ($AnnotateResolvedTags) { [void]$arguments.Add('-AnnotateResolvedTags') }
    if ($EnableDiagramRendering) { [void]$arguments.Add('-EnableDiagramRendering') }
    Add-ArgumentValue -Arguments $arguments -Name '-DocxMatchMode' -Value $DocxMatchMode
    Add-ArgumentValue -Arguments $arguments -Name '-UnresolvedTokenPolicy' -Value $UnresolvedTokenPolicy
    Add-ArgumentValue -Arguments $arguments -Name '-ProgressPath' -Value $progressPath
    Add-ArgumentValue -Arguments $arguments -Name '-ReportPath' -Value $reportPath
    Add-ArgumentValue -Arguments $arguments -Name '-CancelSignalPath' -Value $cancelSignalPath

    [pscustomobject]@{
        WrapperScript = $wrapperScript
        Arguments = @($arguments)
        ProgressPath = $progressPath
        ReportPath = $reportPath
        CancelSignalPath = $cancelSignalPath
        WorkingDirectory = $RepoRoot
    }
}

function Start-AssemblerGuiRenderProcess {
    param(
        [Parameter(Mandatory = $true)]$Invocation,
        [Parameter(Mandatory = $false)][string]$PwshPath
    )

    if ([string]::IsNullOrWhiteSpace($PwshPath)) {
        $PwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    }
    if ([string]::IsNullOrWhiteSpace([string]$PwshPath)) {
        throw 'pwsh.exe was not found on PATH.'
    }

    $outputParent = Split-Path -Path ([string]$Invocation.ReportPath) -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputParent) -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        New-Item -Path $outputParent -ItemType Directory -Force | Out-Null
    }
    if (Test-Path -LiteralPath ([string]$Invocation.ProgressPath) -PathType Leaf) {
        Remove-Item -LiteralPath ([string]$Invocation.ProgressPath) -Force
    }
    if (Test-Path -LiteralPath ([string]$Invocation.CancelSignalPath) -PathType Leaf) {
        Remove-Item -LiteralPath ([string]$Invocation.CancelSignalPath) -Force
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PwshPath
    foreach ($argument in @($Invocation.Arguments)) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $startInfo.WorkingDirectory = [string]$Invocation.WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    [pscustomobject]@{
        Process = $process
        Invocation = $Invocation
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
        LastProgressCount = 0
    }
}

function Read-AssemblerGuiProgressEvents {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $events = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $events.Add(($line | ConvertFrom-Json -AsHashtable))
        }
        catch {
            $events.Add([ordered]@{
                timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
                stage = 'Failed'
                level = 'Warn'
                status = 'Failed'
                percent = 0
                message = "Invalid progress JSONL line: $($_.Exception.Message)"
                currentItem = ''
            })
        }
    }

    return @($events)
}

function Request-AssemblerGuiRenderCancel {
    param([Parameter(Mandatory = $true)]$RenderState)

    $cancelPath = [string]$RenderState.Invocation.CancelSignalPath
    $parent = Split-Path -Path $cancelPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    Set-Content -LiteralPath $cancelPath -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
}

function Stop-AssemblerGuiRenderProcess {
    param([Parameter(Mandatory = $true)]$RenderState)

    Request-AssemblerGuiRenderCancel -RenderState $RenderState
    $process = $RenderState.Process
    if ($null -ne $process -and -not $process.HasExited) {
        try {
            $process.Kill($true)
        }
        catch {
            $process.Kill()
        }
    }
}

function Get-AssemblerGuiWrapperReport {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
}

function Get-AssemblerGuiBackendReportJson {
    param(
        [Parameter(Mandatory = $false)]$WrapperReport,
        [Parameter(Mandatory = $false)][string]$FallbackJson
    )

    if ($null -ne $WrapperReport -and (Test-DictionaryHasKey -Map $WrapperReport -Key 'backend')) {
        $backend = $WrapperReport.backend
        if ($backend -is [System.Collections.IDictionary]) {
            if ((Test-DictionaryHasKey -Map $backend -Key 'reportPath') -and -not [string]::IsNullOrWhiteSpace([string]$backend.reportPath) -and (Test-Path -LiteralPath ([string]$backend.reportPath) -PathType Leaf)) {
                return (Get-Content -LiteralPath ([string]$backend.reportPath) -Raw -Encoding UTF8)
            }
            if ((Test-DictionaryHasKey -Map $backend -Key 'stdout') -and -not [string]::IsNullOrWhiteSpace([string]$backend.stdout)) {
                return [string]$backend.stdout
            }
            if ((Test-DictionaryHasKey -Map $backend -Key 'report') -and $null -ne $backend.report) {
                return ($backend.report | ConvertTo-Json -Depth 20)
            }
        }
    }

    return $FallbackJson
}

Export-ModuleMember -Function @(
    'New-AssemblerGuiRenderInvocation',
    'Start-AssemblerGuiRenderProcess',
    'Read-AssemblerGuiProgressEvents',
    'Request-AssemblerGuiRenderCancel',
    'Stop-AssemblerGuiRenderProcess',
    'Get-AssemblerGuiWrapperReport',
    'Get-AssemblerGuiBackendReportJson'
)
