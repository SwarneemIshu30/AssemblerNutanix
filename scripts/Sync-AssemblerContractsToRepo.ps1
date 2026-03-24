#!/usr/bin/env pwsh
<#
.SYNOPSIS
Sync Assembler contracts into deterministic local ingest path (`.deps/contracts`).

.DESCRIPTION
Supports two modes only:
1) Published release pack sync (default): resolve latest release asset and download/extract zip
2) Local copy (when `-ExportContractsPath` is explicitly supplied): `<source>` -> `.deps/contracts`

Output behavior:
- Normal mode emits concise milestone messages for each major stage (validation, source resolution,
  cleanup, copy/download, extraction, layout normalization, snapshot generation, mapping generation,
  and final report).
- Verbose mode (`-Verbose`) includes additional diagnostic details such as resolved paths/URIs,
  item counts, and per-stage durations to support operator troubleshooting.
#>

[CmdletBinding()]
param(
    [string]$ExportContractsPath,

    [string]$ContractsVersion,

    [string]$ContractsPackUrl,

    [string]$ReleaseBaseUrl = 'https://github.com/LNV-AsBuiltDoc/LNV.AsBuiltDoc.Contracts/releases/download',

    [string]$PackNamePattern = 'asbuiltdoc-contracts-v{0}.zip',

    [ValidateRange(1, 600)]
    [int]$DownloadTimeoutSec = 120,

    [ValidateRange(1, 10)]
    [int]$DownloadRetryCount = 3,

    [string]$DepsContractsPath = (Join-Path $PSScriptRoot '..\.deps\contracts'),

    [string]$SkeletonMappingOutputPath = (Join-Path $PSScriptRoot '..\templates\skeletons\Lenovo.DE\DE-SDT-Collector.mapping.json'),

    [switch]$Clean,

    [switch]$KeepTempArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LatestContractsPack {
    param([Parameter(Mandatory = $true)][string]$ReleaseBaseUrl)

    $apiBase = ($ReleaseBaseUrl -replace '/releases/download$', '')
    $latestUri = "$apiBase/releases/latest"
    $latest = Invoke-RestMethod -Uri $latestUri -Headers @{ 'User-Agent' = 'LNV.AsBuiltDoc.Assembler/Sync-AssemblerContractsToRepo' }

    $asset = @($latest.assets | Where-Object { $_.name -match '^asbuiltdoc-contracts-v.+\.zip$' } | Select-Object -First 1)
    if (@($asset).Count -eq 0) {
        throw "Unable to locate contracts zip asset in latest release '$($latest.tag_name)'."
    }

    [ordered]@{
        version = ([string]$latest.tag_name).TrimStart('v')
        tag = [string]$latest.tag_name
        packName = [string]$asset[0].name
        packUrl = [string]$asset[0].browser_download_url
        releaseUrl = [string]$latest.html_url
    }
}

function Invoke-ContractsPackDownload {
    param(
        [Parameter(Mandatory = $true)][string]$PackUrl,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [Parameter(Mandatory = $true)][int]$RetryCount
    )

    $requestHeaders = @{ 'User-Agent' = 'LNV.AsBuiltDoc.Assembler/Sync-AssemblerContractsToRepo' }
    $lastError = $null

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Write-Verbose ("Download attempt {0}/{1}: {2}" -f $attempt, $RetryCount, $PackUrl)
            Invoke-WebRequest -Uri $PackUrl -OutFile $DestinationPath -UseBasicParsing -Headers $requestHeaders -TimeoutSec $TimeoutSec

            if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
                throw "Downloaded file was not created at '$DestinationPath'."
            }

            $downloadedFile = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
            if ($downloadedFile.Length -le 0) {
                throw "Downloaded file is empty at '$DestinationPath'."
            }

            $extension = [IO.Path]::GetExtension($DestinationPath)
            if ($extension -ne '.zip') {
                throw "Downloaded file extension '$extension' is not supported; expected '.zip'."
            }

            $signatureBytes = [System.IO.File]::ReadAllBytes($DestinationPath)
            if ($signatureBytes.Length -lt 4) {
                throw "Downloaded file is too small to be a valid zip archive."
            }

            $hasZipSignature = (
                ($signatureBytes[0] -eq 0x50 -and $signatureBytes[1] -eq 0x4B -and $signatureBytes[2] -eq 0x03 -and $signatureBytes[3] -eq 0x04) -or
                ($signatureBytes[0] -eq 0x50 -and $signatureBytes[1] -eq 0x4B -and $signatureBytes[2] -eq 0x05 -and $signatureBytes[3] -eq 0x06) -or
                ($signatureBytes[0] -eq 0x50 -and $signatureBytes[1] -eq 0x4B -and $signatureBytes[2] -eq 0x07 -and $signatureBytes[3] -eq 0x08)
            )

            if (-not $hasZipSignature) {
                throw "Downloaded file signature does not match a zip archive (expected PK header)."
            }

            return [ordered]@{
                path = $DestinationPath
                bytes = $downloadedFile.Length
                attempts = $attempt
            }
        }
        catch {
            $lastError = $_
            $isTransient = $false

            if ($null -ne $_.Exception) {
                if ($_.Exception -is [System.TimeoutException]) {
                    $isTransient = $true
                }
                elseif ($_.Exception -is [System.Net.WebException]) {
                    $isTransient = $true
                }
                elseif ($_.Exception.PSObject.Properties.Match('Response').Count -gt 0) {
                    try {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                        if ($statusCode -eq 429 -or $statusCode -ge 500) {
                            $isTransient = $true
                        }
                    }
                    catch {
                        $isTransient = $true
                    }
                }
            }

            if ((-not $isTransient) -or $attempt -ge $RetryCount) {
                break
            }

            $delaySeconds = [Math]::Pow(2, $attempt - 1)
            Write-Verbose ("Transient download failure on attempt {0}/{1}. Retrying in {2} second(s). Error: {3}" -f $attempt, $RetryCount, $delaySeconds, $_.Exception.Message)
            Start-Sleep -Seconds $delaySeconds
        }
    }

    $errorMessage = if ($null -ne $lastError -and $null -ne $lastError.Exception -and -not [string]::IsNullOrWhiteSpace($lastError.Exception.Message)) {
        $lastError.Exception.Message
    }
    else {
        'Unknown download failure.'
    }

    throw "[download] Failed to download contracts pack from '$PackUrl' after $RetryCount attempt(s). Last error: $errorMessage. Hints: verify URL correctness, check proxy configuration, validate authentication/access to the release asset."
}

function Write-SyncStep {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message,
        [hashtable]$Details
    )

    Write-Information ("[{0}] {1}" -f $Stage, $Message) -InformationAction Continue

    if ($VerbosePreference -eq 'SilentlyContinue' -or $null -eq $Details -or $Details.Count -eq 0) {
        return
    }

    foreach ($key in @($Details.Keys | Sort-Object)) {
        $value = $Details[$key]
        if ($null -eq $value) { continue }
        Write-Verbose ("{0}: {1}" -f $key, $value)
    }
}

function New-SyncProgressContext {
    [ordered]@{
        Activity = 'Syncing Assembler contracts'
        Id = 1
        Enabled = ($ProgressPreference -ne 'SilentlyContinue')
        Stages = [ordered]@{
            'Validate params' = [ordered]@{ Start = 0; End = 10 }
            'Resolve source' = [ordered]@{ Start = 10; End = 20 }
            'Download/copy' = [ordered]@{ Start = 20; End = 60 }
            'Extract/normalize' = [ordered]@{ Start = 60; End = 80 }
            'Snapshot + mapping' = [ordered]@{ Start = 80; End = 95 }
            'Finalize' = [ordered]@{ Start = 95; End = 100 }
        }
    }
}

function Get-SyncStagePercent {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ProgressContext,
        [Parameter(Mandatory = $true)][string]$StageName,
        [double]$Position = 0
    )

    if (-not $ProgressContext.Stages.Contains($StageName)) {
        return 0
    }

    $stage = $ProgressContext.Stages[$StageName]
    $clamped = [Math]::Max(0, [Math]::Min(1, $Position))
    $start = [double]$stage.Start
    $span = [double]$stage.End - $start
    return [Math]::Round($start + ($span * $clamped), 0)
}

function Update-SyncProgress {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ProgressContext,
        [Parameter(Mandatory = $true)][string]$StageName,
        [Parameter(Mandatory = $true)][string]$Status,
        [double]$Position = 0
    )

    if (-not $ProgressContext.Enabled) {
        return
    }

    Write-Progress -Id $ProgressContext.Id -Activity $ProgressContext.Activity -Status $Status -PercentComplete (Get-SyncStagePercent -ProgressContext $ProgressContext -StageName $StageName -Position $Position)
}

function Complete-SyncProgress {
    param([Parameter(Mandatory = $true)][hashtable]$ProgressContext)

    if (-not $ProgressContext.Enabled) {
        return
    }

    Write-Progress -Id $ProgressContext.Id -Activity $ProgressContext.Activity -Completed
}

function Initialize-LnvRootLayout {
    param([Parameter(Mandatory = $true)][string]$Root)

    $standardsRoot = Join-Path $Root 'standards'
    $techRoot = Join-Path $Root 'tech'

    if (Test-Path -LiteralPath $standardsRoot -PathType Container) {
        return
    }

    $children = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    if (@($children).Count -eq 1) {
        $inner = $children[0].FullName
        $innerStandardsRoot = Join-Path $inner 'standards'

        if (Test-Path -LiteralPath $innerStandardsRoot -PathType Container) {
            Copy-Item -Recurse -Force -LiteralPath (Join-Path $inner '*') -Destination $Root
            Remove-Item -Recurse -Force -LiteralPath $inner
        }
    }

    if (-not (Test-Path -LiteralPath $standardsRoot -PathType Container)) {
        throw "Contracts layout invalid at '$Root'. Expected 'standards/' at root (and optionally 'tech/')."
    }

    if (-not (Test-Path -LiteralPath $techRoot -PathType Container)) {
        Write-Verbose "Contracts root '$Root' has no 'tech/' folder; continuing with standards-only layout."
    }
}

function Write-Snapshot {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][hashtable]$Snapshot
    )

    $snapshotPath = Join-Path $DestinationPath 'contracts.snapshot.json'
    $Snapshot | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $snapshotPath
    return $snapshotPath
}

function Get-LenovoCollectorSdtTagFromContract {
    param([Parameter(Mandatory = $true)][hashtable]$MappingEntry)

    $contractTag = if ($MappingEntry.ContainsKey('sdtTag')) { [string]$MappingEntry.sdtTag } else { '' }
    if ([string]::IsNullOrWhiteSpace($contractTag)) {
        return ''
    }

    $normalized = $contractTag.Replace('[<SystemId>]', '[ArrayName]')
    $aliases = @{
        'LNV.Lenovo.DE.System[ArrayName].Tables.Drives' = 'LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory'
        'LNV.Lenovo.DE.System[ArrayName].Tables.StorageContainers' = 'LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory'
        'LNV.Lenovo.DE.System[ArrayName].Tables.Volumes' = 'LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory'
        'LNV.Lenovo.DE.System[ArrayName].Tables.ASUP' = 'LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport'
    }

    if ($aliases.ContainsKey($normalized)) {
        return [string]$aliases[$normalized]
    }

    return $normalized
}

function Get-LenovoCollectorDatasetPathFromContract {
    param([Parameter(Mandatory = $true)][string]$DatasetName)

    if ([string]::IsNullOrWhiteSpace($DatasetName)) {
        return ''
    }

    if ($DatasetName -eq 'systems') {
        return "datasets/Lenovo.DE/__TARGET__/$DatasetName.json"
    }

    return "datasets/Lenovo.DE/__TARGET__/__SYSTEM__/$DatasetName.json"
}

function Sync-LenovoCollectorSkeletonMappingFromContract {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $contractMappingPath = Join-Path $ContractsRoot 'tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'
    if (-not (Test-Path -LiteralPath $contractMappingPath -PathType Leaf)) {
        throw "Required Lenovo.DE mapping contract not found at '$contractMappingPath'."
    }

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "ConvertFrom-Yaml is required to sync Lenovo.DE skeleton mapping from '$contractMappingPath'."
    }

    $contract = Get-Content -LiteralPath $contractMappingPath -Raw -Encoding UTF8 | ConvertFrom-Yaml
    if ($null -eq $contract -or [string]$contract.schema -ne 'mapping.dataset-to-sdt' -or [string]$contract.techId -ne 'Lenovo.DE') {
        throw "Lenovo.DE mapping contract '$contractMappingPath' is not in expected mapping.dataset-to-sdt format."
    }

    $generatedMappings = [System.Collections.Generic.List[hashtable]]::new()
    $processedCount = 0
    $generatedCount = 0
    $skipReasonCounters = [ordered]@{
        missingDataset = 0
        missingTag = 0
        unsupportedShape = 0
    }

    foreach ($entry in @($contract.mappings)) {
        $processedCount++
        $mappingIndex = $processedCount - 1
        $sourceDataset = ''
        $sourceTag = ''
        $sourceKey = "<missing-dataset>|<missing-tag>"

        try {
            if ($null -eq $entry) {
                $skipReasonCounters.missingDataset++
                $skipReasonCounters.missingTag++
                Write-Verbose ("[lenovo-mapping-sync] skip mapping[{0}] sourceKey={1} reason=missing dataset+tag (null entry)" -f $mappingIndex, $sourceKey)
                continue
            }

            $entryTable = if ($entry -is [System.Collections.IDictionary]) {
                $entry
            }
            else {
                $converted = [ordered]@{}
                foreach ($property in @($entry.PSObject.Properties)) {
                    $converted[[string]$property.Name] = $property.Value
                }
                $converted
            }

            $sourceDataset = if ($entryTable.ContainsKey('dataset')) { [string]$entryTable.dataset } else { '' }
            $sourceTag = if ($entryTable.ContainsKey('sdtTag')) { [string]$entryTable.sdtTag } else { '' }
            $sourceDatasetKey = if ([string]::IsNullOrWhiteSpace($sourceDataset)) { '<missing-dataset>' } else { $sourceDataset }
            $sourceTagKey = if ([string]::IsNullOrWhiteSpace($sourceTag)) { '<missing-tag>' } else { $sourceTag }
            $sourceKey = "$sourceDatasetKey|$sourceTagKey"
            Write-Verbose ("[lenovo-mapping-sync] processing mapping[{0}] sourceKey={1}" -f $mappingIndex, $sourceKey)

            $datasetName = $sourceDataset
            $resolvedTag = Get-LenovoCollectorSdtTagFromContract -MappingEntry $entryTable

            if ([string]::IsNullOrWhiteSpace($datasetName)) {
                $skipReasonCounters.missingDataset++
                Write-Verbose ("[lenovo-mapping-sync] skip mapping[{0}] sourceKey={1} reason=missing dataset" -f $mappingIndex, $sourceKey)
                continue
            }

            if ([string]::IsNullOrWhiteSpace($resolvedTag)) {
                $skipReasonCounters.missingTag++
                Write-Verbose ("[lenovo-mapping-sync] skip mapping[{0}] sourceKey={1} reason=missing tag" -f $mappingIndex, $sourceKey)
                continue
            }

            $mappingEntry = [ordered]@{
                dataset = (Get-LenovoCollectorDatasetPathFromContract -DatasetName $datasetName)
                sdtTag = $resolvedTag
                required = [bool]$entryTable.required
            }

            $renderHintSource = $null
            if ($entryTable.ContainsKey('renderHint')) {
                if ($entryTable.renderHint -is [System.Collections.IDictionary]) {
                    $renderHintSource = $entryTable.renderHint
                }
                elseif ($null -ne $entryTable.renderHint -and $entryTable.renderHint.PSObject) {
                    $renderHintSource = [ordered]@{}
                    foreach ($property in @($entryTable.renderHint.PSObject.Properties)) {
                        $renderHintSource[[string]$property.Name] = $property.Value
                    }
                }
            }

            if ($null -ne $renderHintSource -and $renderHintSource.ContainsKey('renderAs')) {
                $renderAs = [string]$renderHintSource.renderAs
                if (-not [string]::IsNullOrWhiteSpace($renderAs) -and $renderAs -ne 'table') {
                    $skipReasonCounters.unsupportedShape++
                    Write-Verbose ("[lenovo-mapping-sync] skip mapping[{0}] sourceKey={1} reason=unsupported shape renderAs={2}" -f $mappingIndex, $sourceKey, $renderAs)
                    continue
                }
            }

            $renderHint = [ordered]@{}
            if ($null -ne $renderHintSource) {
                foreach ($renderHintKey in @('renderAs', 'projectionRef', 'view')) {
                    if ($renderHintSource.ContainsKey($renderHintKey) -and -not [string]::IsNullOrWhiteSpace([string]$renderHintSource[$renderHintKey])) {
                        $renderHint[$renderHintKey] = [string]$renderHintSource[$renderHintKey]
                    }
                }
            }

            if ($renderHint.Count -gt 0) {
                $mappingEntry.renderHint = $renderHint
                $mappingEntry.selectors = @('items')
            }

            $generatedMappings.Add($mappingEntry)
            $generatedCount++
        }
        catch {
            $message = if ($null -ne $_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                $_.Exception.Message
            }
            else {
                [string]$_
            }
            throw "Lenovo.DE mapping generation failed for contract '$contractMappingPath' at mapping[$mappingIndex] key '$sourceKey': $message"
        }
    }

    $skippedCount = $processedCount - $generatedCount
    Write-Verbose ("[lenovo-mapping-sync] totals: processed={0}; skipped={1}; generated={2}" -f $processedCount, $skippedCount, $generatedCount)
    Write-Verbose ("[lenovo-mapping-sync] skip reasons: missingDataset={0}; missingTag={1}; unsupportedShape={2}" -f $skipReasonCounters.missingDataset, $skipReasonCounters.missingTag, $skipReasonCounters.unsupportedShape)

    $outputDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $generatedMapping = [ordered]@{
        schema = 'mapping.dataset-to-sdt'
        schemaVersion = 1
        techId = 'Lenovo.DE'
        displayName = 'Lenovo DE collector blueprint mapping'
        compatibility = [ordered]@{
            contracts = [ordered]@{
                version = 'v1'
            }
        }
        strictContracts = [ordered]@{
            enabled = $true
            requireAllMappings = $true
        }
        generatedFromContract = [ordered]@{
            path = 'tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'
        }
        mappings = @($generatedMappings)
    }

    $generatedMapping | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    return $OutputPath
}

$stage = 'initialization'
$exitCode = 0
$result = $null
$errorPayload = $null
$tmpZip = $null
$tempArtifacts = [System.Collections.Generic.List[string]]::new()
$progressStarted = $false
$progressContext = $null
$syncStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$stepTimer = [System.Diagnostics.Stopwatch]::new()

try {
    $progressStarted = $true
    $progressContext = New-SyncProgressContext
    Update-SyncProgress -ProgressContext $progressContext -StageName 'Validate params' -Status 'Starting validation' -Position 0

    $stage = 'argument-validation'
    $stepTimer.Restart()
    if ($ContractsVersion -and $ContractsPackUrl) {
        throw "Specify either -ContractsVersion or -ContractsPackUrl, not both."
    }

    $useLocalCopy = $PSBoundParameters.ContainsKey('ExportContractsPath')

    if ($useLocalCopy -and ($ContractsVersion -or $ContractsPackUrl)) {
        throw "Specify either -ExportContractsPath for a local copy or a published-pack option, not both."
    }
    $stepTimer.Stop()
    Update-SyncProgress -ProgressContext $progressContext -StageName 'Validate params' -Status 'Validated parameters' -Position 1
    Write-SyncStep -Stage 'input validation' -Message 'Validated parameter combinations and operating mode.' -Details ([ordered]@{
            useLocalCopy = $useLocalCopy
            contractsVersion = $ContractsVersion
            contractsPackUrl = $ContractsPackUrl
            durationMs = $stepTimer.ElapsedMilliseconds
        })

    $stage = 'prepare-destination'
    $stepTimer.Restart()
    Update-SyncProgress -ProgressContext $progressContext -StageName 'Resolve source' -Status 'Preparing destination root' -Position 0
    $cleanupPerformed = $false
    if ($Clean -and (Test-Path -LiteralPath $DepsContractsPath -PathType Container)) {
        Remove-Item -Recurse -Force -LiteralPath $DepsContractsPath
        $cleanupPerformed = $true
    }
    New-Item -ItemType Directory -Force -Path $DepsContractsPath | Out-Null
    $stepTimer.Stop()
    Write-SyncStep -Stage 'cleanup' -Message 'Prepared destination contracts root.' -Details ([ordered]@{
            destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
            cleanRequested = [bool]$Clean
            removedExistingDestination = $cleanupPerformed
            durationMs = $stepTimer.ElapsedMilliseconds
        })

    if ($useLocalCopy) {
        $stage = 'local-copy'
        $stepTimer.Restart()
        $sourceRoot = (Resolve-Path -LiteralPath $ExportContractsPath -ErrorAction Stop).Path
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Resolve source' -Status 'Resolved local source' -Position 1
        Write-SyncStep -Stage 'source resolution' -Message 'Resolved local export source path.' -Details ([ordered]@{
                sourceRoot = $sourceRoot
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Download/copy' -Status 'Copying local export' -Position 0.5
        Copy-Item -Recurse -Force -Path (Join-Path $sourceRoot '*') -Destination $DepsContractsPath
        $localCopyCount = @((Get-ChildItem -LiteralPath $DepsContractsPath -Recurse -File -ErrorAction SilentlyContinue)).Count
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Download/copy' -Status 'Copied local export' -Position 1
        Write-SyncStep -Stage 'copy/download' -Message 'Copied local contracts export into destination.' -Details ([ordered]@{
                sourceRoot = $sourceRoot
                destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
                copiedFileCount = $localCopyCount
                durationMs = $stepTimer.ElapsedMilliseconds
            })
        Write-SyncStep -Stage 'extraction' -Message 'No extraction required for local copy mode.' -Details ([ordered]@{
                mode = 'LocalExport'
            })

        $stage = 'archive-layout-validation'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Extract/normalize' -Status 'Validating layout' -Position 0.25
        Initialize-LnvRootLayout -Root $DepsContractsPath
        $layoutTechRoot = Join-Path $DepsContractsPath 'tech'
        $layoutStandardsRoot = Join-Path $DepsContractsPath 'standards'
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Extract/normalize' -Status 'Layout normalized' -Position 1
        Write-SyncStep -Stage 'layout normalization' -Message 'Validated and normalized contracts root layout.' -Details ([ordered]@{
                root = (Resolve-Path -LiteralPath $DepsContractsPath).Path
                standardsPath = $layoutStandardsRoot
                techPath = $layoutTechRoot
                hasTechFolder = (Test-Path -LiteralPath $layoutTechRoot -PathType Container)
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $stage = 'snapshot-write'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Snapshot + mapping' -Status 'Writing snapshot metadata' -Position 0.2
        $snapshotPath = Write-Snapshot -DestinationPath $DepsContractsPath -Snapshot ([ordered]@{
                schemaVersion = 1
                syncedUtc = (Get-Date).ToUniversalTime().ToString('o')
                source = 'local-export-copy'
                exportContractsPath = $sourceRoot
            })
        $stepTimer.Stop()
        Write-SyncStep -Stage 'snapshot generation' -Message 'Wrote contracts snapshot metadata.' -Details ([ordered]@{
                snapshotPath = $snapshotPath
                source = 'local-export-copy'
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $stage = 'mapping-generation'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Snapshot + mapping' -Status 'Generating skeleton mapping' -Position 0.8
        $skeletonMappingPath = Sync-LenovoCollectorSkeletonMappingFromContract -ContractsRoot $DepsContractsPath -OutputPath $SkeletonMappingOutputPath
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Snapshot + mapping' -Status 'Snapshot and mapping complete' -Position 1
        Write-SyncStep -Stage 'mapping generation' -Message 'Generated skeleton mapping from Lenovo.DE contract.' -Details ([ordered]@{
                contractsRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
                outputPath = (Resolve-Path -LiteralPath $skeletonMappingPath).Path
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $result = [ordered]@{
            status = 'ok'
            mode = 'LocalExport'
            sourceRoot = $sourceRoot
            destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
            snapshotPath = $snapshotPath
            skeletonMappingPath = (Resolve-Path -LiteralPath $skeletonMappingPath).Path
        }
    }
    else {
        $resolvedVersion = $ContractsVersion
        $resolvedTag = if ($ContractsVersion) { "v$ContractsVersion" } else { $null }
        $releasePageUrl = $null

        $stage = 'resolve-pack-url'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Resolve source' -Status 'Resolving package source' -Position 0.5
        $packUrl = if ($ContractsPackUrl) {
            $ContractsPackUrl
        }
        elseif ($ContractsVersion) {
            $zipName = [string]::Format($PackNamePattern, $ContractsVersion)
            "$ReleaseBaseUrl/v$ContractsVersion/$zipName"
        }
        else {
            $latest = Resolve-LatestContractsPack -ReleaseBaseUrl $ReleaseBaseUrl
            $resolvedVersion = $latest.version
            $resolvedTag = $latest.tag
            $releasePageUrl = $latest.releaseUrl
            Write-Information "Resolved latest contracts release: tag=$($latest.tag), asset=$($latest.packName)" -InformationAction Continue
            $latest.packUrl
        }
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Resolve source' -Status 'Resolved package source' -Position 1
        Write-SyncStep -Stage 'source resolution' -Message 'Resolved published contracts package source.' -Details ([ordered]@{
                contractsVersion = $resolvedVersion
                contractsTag = $resolvedTag
                packUrl = $packUrl
                releaseUrl = $releasePageUrl
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $zipLeaf = [IO.Path]::GetFileName(($packUrl -split '\?')[0])
        if ([string]::IsNullOrWhiteSpace($zipLeaf)) {
            $zipLeaf = 'asbuiltdoc-contracts.zip'
        }

        $tmpBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $zipLeafBase = [IO.Path]::GetFileNameWithoutExtension($zipLeaf)
        $zipLeafExtension = [IO.Path]::GetExtension($zipLeaf)
        $zipLeafWithGuid = '{0}-{1}{2}' -f $zipLeafBase, ([guid]::NewGuid().ToString('N')), $zipLeafExtension
        $tmpZip = Join-Path $tmpBase $zipLeafWithGuid
        $tempArtifacts.Add($tmpZip) | Out-Null

        $stage = 'download'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Download/copy' -Status 'Downloading contracts pack' -Position 0.5
        Write-Information "Downloading contracts pack: $packUrl" -InformationAction Continue
        $downloadResult = Invoke-ContractsPackDownload -PackUrl $packUrl -DestinationPath $tmpZip -TimeoutSec $DownloadTimeoutSec -RetryCount $DownloadRetryCount
        $downloadBytes = [long]$downloadResult.bytes
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Download/copy' -Status 'Downloaded contracts pack' -Position 1
        Write-SyncStep -Stage 'copy/download' -Message 'Downloaded contracts package.' -Details ([ordered]@{
                packUrl = $packUrl
                localPackPath = $tmpZip
                bytes = $downloadBytes
                attempts = $downloadResult.attempts
                timeoutSec = $DownloadTimeoutSec
                retryCount = $DownloadRetryCount
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $stage = 'archive-layout-validation'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Extract/normalize' -Status 'Extracting contracts pack' -Position 0.25
        Write-Information "Extracting contracts pack to $DepsContractsPath" -InformationAction Continue
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $DepsContractsPath -Force
        $stepTimer.Stop()
        Write-SyncStep -Stage 'extraction' -Message 'Extracted downloaded contracts package.' -Details ([ordered]@{
                archivePath = $tmpZip
                destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $stepTimer.Restart()
        Initialize-LnvRootLayout -Root $DepsContractsPath
        $layoutTechRoot = Join-Path $DepsContractsPath 'tech'
        $layoutStandardsRoot = Join-Path $DepsContractsPath 'standards'
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Extract/normalize' -Status 'Layout normalized' -Position 1
        Write-SyncStep -Stage 'layout normalization' -Message 'Validated and normalized contracts root layout.' -Details ([ordered]@{
                root = (Resolve-Path -LiteralPath $DepsContractsPath).Path
                standardsPath = $layoutStandardsRoot
                techPath = $layoutTechRoot
                hasTechFolder = (Test-Path -LiteralPath $layoutTechRoot -PathType Container)
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $stage = 'snapshot-write'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Snapshot + mapping' -Status 'Writing snapshot metadata' -Position 0.2
        $snapshotPath = Write-Snapshot -DestinationPath $DepsContractsPath -Snapshot ([ordered]@{
                schemaVersion = 1
                syncedUtc = (Get-Date).ToUniversalTime().ToString('o')
                source = 'published-pack'
                version = $resolvedVersion
                tag = $resolvedTag
                packUrl = $packUrl
                releaseUrl = $releasePageUrl
                packPath = $tmpZip
            })
        $stepTimer.Stop()
        Write-SyncStep -Stage 'snapshot generation' -Message 'Wrote contracts snapshot metadata.' -Details ([ordered]@{
                snapshotPath = $snapshotPath
                source = 'published-pack'
                version = $resolvedVersion
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $stage = 'mapping-generation'
        $stepTimer.Restart()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Snapshot + mapping' -Status 'Generating skeleton mapping' -Position 0.8
        $skeletonMappingPath = Sync-LenovoCollectorSkeletonMappingFromContract -ContractsRoot $DepsContractsPath -OutputPath $SkeletonMappingOutputPath
        $stepTimer.Stop()
        Update-SyncProgress -ProgressContext $progressContext -StageName 'Snapshot + mapping' -Status 'Snapshot and mapping complete' -Position 1
        Write-SyncStep -Stage 'mapping generation' -Message 'Generated skeleton mapping from Lenovo.DE contract.' -Details ([ordered]@{
                contractsRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
                outputPath = (Resolve-Path -LiteralPath $skeletonMappingPath).Path
                durationMs = $stepTimer.ElapsedMilliseconds
            })

        $result = [ordered]@{
            status = 'ok'
            mode = if ($ContractsPackUrl) { 'PackUrl' } elseif ($ContractsVersion) { 'PackVersion' } else { 'PackLatest' }
            version = $resolvedVersion
            tag = $resolvedTag
            packUrl = $packUrl
            releaseUrl = $releasePageUrl
            destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
            snapshotPath = $snapshotPath
            skeletonMappingPath = (Resolve-Path -LiteralPath $skeletonMappingPath).Path
        }
    }

    $syncStopwatch.Stop()
    Update-SyncProgress -ProgressContext $progressContext -StageName 'Finalize' -Status 'Finalizing sync report' -Position 0.5
    Write-SyncStep -Stage 'final report' -Message 'Contracts sync completed successfully.' -Details ([ordered]@{
            mode = $result.mode
            destinationRoot = $result.destinationRoot
            snapshotPath = $result.snapshotPath
            skeletonMappingPath = $result.skeletonMappingPath
            totalDurationMs = $syncStopwatch.ElapsedMilliseconds
        })
    Update-SyncProgress -ProgressContext $progressContext -StageName 'Finalize' -Status 'Completed' -Position 1
}
catch {
    $caught = $_
    $exceptionType = if ($null -ne $caught.Exception) { $caught.Exception.GetType().FullName } else { 'UnknownException' }
    $message = if ($null -ne $caught.Exception -and -not [string]::IsNullOrWhiteSpace($caught.Exception.Message)) {
        $caught.Exception.Message
    }
    else {
        [string]$caught
    }

    $recommendedAction = 'Review script output, correct the input/environment issue, then rerun the sync.'
    switch -Regex ($stage) {
        '^argument-validation$' {
            $exitCode = 10
            $recommendedAction = 'Fix parameter combinations/values and rerun.'
        }
        'download|resolve-pack-url' {
            $exitCode = 20
            $recommendedAction = 'Verify release URL, version/tag, and network connectivity; then rerun.'
        }
        'archive-layout-validation|prepare-destination|local-copy' {
            $exitCode = 30
            $recommendedAction = 'Validate archive/export layout and destination permissions; then rerun.'
        }
        'mapping-generation|snapshot-write' {
            $exitCode = 40
            $recommendedAction = 'Validate mapping contract/schema and required PowerShell modules; then rerun.'
        }
        default {
            $exitCode = 1
        }
    }

    $errorPayload = [ordered]@{
        status = 'error'
        stage = $stage
        message = $message
        exceptionType = $exceptionType
        recommendedAction = $recommendedAction
        exitCode = $exitCode
    }

    Write-Error "Contracts sync failed at stage '$stage': $message"
    $syncStopwatch.Stop()
    Write-SyncStep -Stage 'final report' -Message 'Contracts sync failed.' -Details ([ordered]@{
            stage = $stage
            exitCode = $exitCode
            totalDurationMs = $syncStopwatch.ElapsedMilliseconds
        })
    if ($VerbosePreference -ne 'SilentlyContinue') {
        Write-Verbose ("Exception type: {0}" -f $exceptionType)
        if ($null -ne $caught.ScriptStackTrace -and -not [string]::IsNullOrWhiteSpace($caught.ScriptStackTrace)) {
            Write-Verbose ("Script stack trace: {0}" -f $caught.ScriptStackTrace)
        }
        if ($null -ne $caught.Exception -and $null -ne $caught.Exception.InnerException) {
            Write-Verbose ("Inner exception: {0}" -f $caught.Exception.InnerException.Message)
        }
    }
}
finally {
    if ($progressStarted) {
        Complete-SyncProgress -ProgressContext $progressContext
    }

    if ($KeepTempArtifacts) {
        Write-Verbose ("Retaining temporary artifacts because -KeepTempArtifacts was supplied.")
    }
    else {
        foreach ($tempArtifactPath in $tempArtifacts) {
            if ([string]::IsNullOrWhiteSpace($tempArtifactPath)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $tempArtifactPath)) {
                continue
            }

            try {
                Remove-Item -LiteralPath $tempArtifactPath -Force -ErrorAction Stop
            }
            catch {
                Write-Warning ("Failed to clean up temporary artifact: {0}" -f $tempArtifactPath)
            }
        }
    }
}

if ($null -ne $result) {
    $result | ConvertTo-Json -Depth 5
    exit 0
}

$errorPayload | ConvertTo-Json -Depth 6
exit $exitCode
