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

    [string]$TechId,

    [string]$MappingContractRelativePath,

    [string]$SkeletonMappingOutputPath,

    [switch]$Clean,

    [switch]$KeepTempArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultSkeletonMappingOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedTechId
    )

    $techSlug = $ResolvedTechId
    $techTail = if ($ResolvedTechId -match '\.') { ($ResolvedTechId -split '\.')[-1] } else { $ResolvedTechId }
    $fileName = "{0}-SDT-Collector.mapping.json" -f $techTail
    return Join-Path $RepoRoot ("templates/skeletons/{0}/{1}" -f $techSlug, $fileName)
}

function Resolve-TechIdsToProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [string]$RequestedTechId
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedTechId)) {
        return @($RequestedTechId.Trim())
    }

    $techRoot = Join-Path $ContractsRoot 'tech'
    if (-not (Test-Path -LiteralPath $techRoot -PathType Container)) {
        return @()
    }

    $discovered = @(
        Get-ChildItem -LiteralPath $techRoot -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name
    )
    return @($discovered | Sort-Object -Unique)
}

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

function Invoke-PostSyncProcessing {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$RequestedTechId,
        [Parameter(Mandatory = $true)][hashtable]$BoundParameters,
        [string]$RequestedMappingContractRelativePath,
        [string]$RequestedSkeletonMappingOutputPath,
        [Parameter(Mandatory = $true)][hashtable]$SnapshotData,
        [Parameter(Mandatory = $true)][hashtable]$ProgressContext,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$StepTimer,
        [Parameter(Mandatory = $true)][ref]$Stage
    )

    $Stage.Value = 'archive-layout-validation'
    $StepTimer.Restart()
    Update-SyncProgress -ProgressContext $ProgressContext -StageName 'Extract/normalize' -Status 'Validating layout' -Position 0.25
    Initialize-LnvRootLayout -Root $ContractsRoot
    $layoutTechRoot = Join-Path $ContractsRoot 'tech'
    $layoutStandardsRoot = Join-Path $ContractsRoot 'standards'
    $StepTimer.Stop()
    Update-SyncProgress -ProgressContext $ProgressContext -StageName 'Extract/normalize' -Status 'Layout normalized' -Position 1
    Write-SyncStep -Stage 'layout normalization' -Message 'Validated and normalized contracts root layout.' -Details ([ordered]@{
            root = (Resolve-Path -LiteralPath $ContractsRoot).Path
            standardsPath = $layoutStandardsRoot
            techPath = $layoutTechRoot
            hasTechFolder = (Test-Path -LiteralPath $layoutTechRoot -PathType Container)
            durationMs = $StepTimer.ElapsedMilliseconds
        })

    $Stage.Value = 'snapshot-write'
    $StepTimer.Restart()
    Update-SyncProgress -ProgressContext $ProgressContext -StageName 'Snapshot + mapping' -Status 'Writing snapshot metadata' -Position 0.2
    $snapshotPath = Write-Snapshot -DestinationPath $ContractsRoot -Snapshot $SnapshotData
    $StepTimer.Stop()
    Write-SyncStep -Stage 'snapshot generation' -Message 'Wrote contracts snapshot metadata.' -Details ([ordered]@{
            snapshotPath = $snapshotPath
            source = [string]$SnapshotData.source
            version = if ($SnapshotData.ContainsKey('version')) { [string]$SnapshotData.version } else { '' }
            durationMs = $StepTimer.ElapsedMilliseconds
        })

    $Stage.Value = 'mapping-generation'
    $StepTimer.Restart()
    Update-SyncProgress -ProgressContext $ProgressContext -StageName 'Snapshot + mapping' -Status 'Generating skeleton mapping' -Position 0.8
    $techIdsToProcess = Resolve-TechIdsToProcess -ContractsRoot $ContractsRoot -RequestedTechId $RequestedTechId
    $generatedMappings = [System.Collections.Generic.List[string]]::new()
    $skippedTechIds = [System.Collections.Generic.List[string]]::new()

    foreach ($currentTechId in @($techIdsToProcess)) {
        $resolvedMappingContractRelativePath = if ($BoundParameters.ContainsKey('MappingContractRelativePath') -and -not [string]::IsNullOrWhiteSpace($RequestedMappingContractRelativePath)) {
            $RequestedMappingContractRelativePath
        }
        else {
            "tech/$currentTechId/mapping.dataset-to-sdt.v1.yaml"
        }
        $resolvedSkeletonMappingOutputPath = if ($BoundParameters.ContainsKey('SkeletonMappingOutputPath') -and -not [string]::IsNullOrWhiteSpace($RequestedSkeletonMappingOutputPath)) {
            $RequestedSkeletonMappingOutputPath
        }
        else {
            Get-DefaultSkeletonMappingOutputPath -RepoRoot $RepoRoot -ResolvedTechId $currentTechId
        }

        $resolvedContractPath = Join-Path $ContractsRoot $resolvedMappingContractRelativePath
        if (-not (Test-Path -LiteralPath $resolvedContractPath -PathType Leaf)) {
            $skippedTechIds.Add($currentTechId) | Out-Null
            Write-Verbose ("[collector-mapping-sync] skip techId={0} reason=missing mapping contract path={1}" -f $currentTechId, $resolvedContractPath)
            continue
        }

        $generatedPath = Sync-CollectorSkeletonMappingFromContract -ContractsRoot $ContractsRoot -OutputPath $resolvedSkeletonMappingOutputPath -ResolvedTechId $currentTechId -ResolvedMappingContractRelativePath $resolvedMappingContractRelativePath
        $generatedMappings.Add((Resolve-Path -LiteralPath $generatedPath).Path) | Out-Null
    }

    $StepTimer.Stop()
    Update-SyncProgress -ProgressContext $ProgressContext -StageName 'Snapshot + mapping' -Status 'Snapshot and mapping complete' -Position 1
    Write-SyncStep -Stage 'mapping generation' -Message 'Generated skeleton mapping from mapping contract.' -Details ([ordered]@{
            contractsRoot = (Resolve-Path -LiteralPath $ContractsRoot).Path
            generatedMappingCount = $generatedMappings.Count
            skippedTechCount = $skippedTechIds.Count
            techIdsProcessed = if ($techIdsToProcess.Count -gt 0) { ($techIdsToProcess -join ', ') } else { '<none>' }
            durationMs = $StepTimer.ElapsedMilliseconds
        })

    return [ordered]@{
        snapshotPath = $snapshotPath
        skeletonMappingPaths = @($generatedMappings)
        skippedTechIds = @($skippedTechIds)
    }
}

function ConvertTo-Dictionary {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value
    }

    if ($null -ne $Value.PSObject) {
        $converted = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            $converted[[string]$property.Name] = $property.Value
        }
        return $converted
    }

    return $null
}

function New-CollectorSdtTagPolicyFromContract {
    param(
        [Parameter(Mandatory = $true)][string]$MappingContractPath,
        [Parameter(Mandatory = $true)][hashtable]$Contract
    )

    $policySource = ConvertTo-Dictionary -Value $Contract.collectorSdtTagPolicy
    if ($null -eq $policySource) {
        return [ordered]@{
            required = $false
            tokenRewrites = [ordered]@{}
            tagAliases = [ordered]@{}
        }
    }

    $required = $false
    if ($policySource.ContainsKey('required')) {
        $required = [bool]$policySource.required
    }

    $tokenRewritesSource = ConvertTo-Dictionary -Value $policySource.tokenRewrites
    if ($null -eq $tokenRewritesSource) {
        if ($required) {
            throw "Mapping contract '$MappingContractPath' requires collectorSdtTagPolicy.tokenRewrites, but it is missing or not a mapping object."
        }

        $tokenRewritesSource = [ordered]@{}
    }

    $tagAliasesSource = ConvertTo-Dictionary -Value $policySource.tagAliases
    if ($null -eq $tagAliasesSource) {
        if ($required) {
            throw "Mapping contract '$MappingContractPath' requires collectorSdtTagPolicy.tagAliases, but it is missing or not a mapping object."
        }

        $tagAliasesSource = [ordered]@{}
    }

    $tokenRewrites = [ordered]@{}
    foreach ($token in @($tokenRewritesSource.Keys)) {
        $tokenName = [string]$token
        $replacement = [string]$tokenRewritesSource[$token]
        if ([string]::IsNullOrWhiteSpace($tokenName) -or [string]::IsNullOrWhiteSpace($replacement)) {
            throw "Mapping contract '$MappingContractPath' has invalid collectorSdtTagPolicy.tokenRewrites entry ('$tokenName' => '$replacement')."
        }

        $tokenRewrites[$tokenName] = $replacement
    }

    $tagAliases = [ordered]@{}
    foreach ($aliasFrom in @($tagAliasesSource.Keys)) {
        $sourceTag = [string]$aliasFrom
        $targetTag = [string]$tagAliasesSource[$aliasFrom]
        if ([string]::IsNullOrWhiteSpace($sourceTag) -or [string]::IsNullOrWhiteSpace($targetTag)) {
            throw "Mapping contract '$MappingContractPath' has invalid collectorSdtTagPolicy.tagAliases entry ('$sourceTag' => '$targetTag')."
        }

        $tagAliases[$sourceTag] = $targetTag
    }

    if ($required -and $tokenRewrites.Count -eq 0 -and $tagAliases.Count -eq 0) {
        throw "Mapping contract '$MappingContractPath' requires collectorSdtTagPolicy, but both tokenRewrites and tagAliases are empty."
    }

    return [ordered]@{
        required = $required
        tokenRewrites = $tokenRewrites
        tagAliases = $tagAliases
    }
}

function Get-CollectorSdtTagFromContract {
    param(
        [Parameter(Mandatory = $true)][hashtable]$MappingEntry,
        [Parameter(Mandatory = $true)][hashtable]$TagPolicy
    )

    $overrideTag = if ($MappingEntry.ContainsKey('outputSdtTag')) { [string]$MappingEntry.outputSdtTag } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($overrideTag)) {
        return $overrideTag
    }

    $contractTag = if ($MappingEntry.ContainsKey('sdtTag')) { [string]$MappingEntry.sdtTag } else { '' }
    if ([string]::IsNullOrWhiteSpace($contractTag) -and $MappingEntry.ContainsKey('target') -and $MappingEntry.target -is [System.Collections.IDictionary] -and $MappingEntry.target.ContainsKey('sdtTag')) {
        $contractTag = [string]$MappingEntry.target.sdtTag
    }
    if ([string]::IsNullOrWhiteSpace($contractTag)) {
        return ''
    }

    $normalized = $contractTag
    foreach ($sourceToken in @($TagPolicy.tokenRewrites.Keys)) {
        $normalized = $normalized.Replace([string]$sourceToken, [string]$TagPolicy.tokenRewrites[$sourceToken])
    }

    if ($TagPolicy.tagAliases.ContainsKey($normalized)) {
        return [string]$TagPolicy.tagAliases[$normalized]
    }

    return $normalized
}

function Get-CollectorDatasetPathTemplateMap {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedTechId
    )

    $datasetRoot = Join-Path (Join-Path (Join-Path $ContractsRoot 'tech') $ResolvedTechId) 'dataset'
    if (-not (Test-Path -LiteralPath $datasetRoot -PathType Container)) {
        throw "Dataset metadata directory not found at '$datasetRoot'."
    }

    $templateMap = @{}
    foreach ($metadataPath in @(Get-ChildItem -LiteralPath $datasetRoot -Filter '*.assembler.meta.json' -File | Sort-Object -Property Name)) {
        $metadata = Get-Content -LiteralPath $metadataPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ($null -eq $metadata) { continue }

        $datasetId = if ($metadata.ContainsKey('dataset')) { [string]$metadata.dataset } else { '' }
        if ([string]::IsNullOrWhiteSpace($datasetId)) {
            continue
        }

        $pathTemplate = ''
        if ($metadata.ContainsKey('datasetPathTemplate') -and -not [string]::IsNullOrWhiteSpace([string]$metadata.datasetPathTemplate)) {
            $pathTemplate = [string]$metadata.datasetPathTemplate
        }
        elseif ($metadata.ContainsKey('datasetPath') -and $metadata.datasetPath -is [System.Collections.IDictionary] -and $metadata.datasetPath.ContainsKey('template') -and -not [string]::IsNullOrWhiteSpace([string]$metadata.datasetPath.template)) {
            $pathTemplate = [string]$metadata.datasetPath.template
        }

        if (-not [string]::IsNullOrWhiteSpace($pathTemplate)) {
            $templateMap[$datasetId] = [ordered]@{
                template = $pathTemplate
                metadataPath = $metadataPath.FullName
            }
        }
    }

    return $templateMap
}

function Get-CollectorDatasetPathFromTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$DatasetName,
        [Parameter(Mandatory = $true)][string]$ResolvedTechId,
        [Parameter(Mandatory = $true)][hashtable]$DatasetPathTemplateMap
    )

    if ([string]::IsNullOrWhiteSpace($DatasetName)) {
        return ''
    }

    if (-not $DatasetPathTemplateMap.ContainsKey($DatasetName)) {
        throw "Dataset '$DatasetName' is missing datasetPath.template metadata under tech '$ResolvedTechId'."
    }

    $templateInfo = $DatasetPathTemplateMap[$DatasetName]
    $datasetTemplate = [string]$templateInfo.template
    if ([string]::IsNullOrWhiteSpace($datasetTemplate)) {
        throw "Dataset '$DatasetName' declared empty datasetPath.template metadata in '$($templateInfo.metadataPath)'."
    }

    $resolvedPath = $datasetTemplate.Replace('__TECH_ID__', $ResolvedTechId).Replace('__DATASET__', $DatasetName)
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        throw "Dataset '$DatasetName' resolved to an empty path from template '$datasetTemplate'."
    }

    return $resolvedPath
}

function New-CollectorMappingSyncPolicyFromContract {
    param(
        [Parameter(Mandatory = $true)][string]$MappingContractPath,
        [Parameter(Mandatory = $true)]$Contract
    )

    $defaultPolicy = [ordered]@{
        allowedRenderAs = @('table')
        selectorsByRenderAs = [ordered]@{
            table = @('items')
        }
        unsupportedRenderShape = [ordered]@{
            documentFacing = 'fail'
            nonDocumentFacing = 'skip'
        }
    }

    $syncPolicyRoot = ConvertTo-Dictionary -Value $Contract.syncPolicy
    if ($null -eq $syncPolicyRoot) {
        return $defaultPolicy
    }

    $collectorPolicy = ConvertTo-Dictionary -Value $syncPolicyRoot.collectorSkeletonMapping
    if ($null -eq $collectorPolicy) {
        return $defaultPolicy
    }

    $policy = [ordered]@{
        allowedRenderAs = @($defaultPolicy.allowedRenderAs)
        selectorsByRenderAs = [ordered]@{}
        unsupportedRenderShape = [ordered]@{
            documentFacing = [string]$defaultPolicy.unsupportedRenderShape.documentFacing
            nonDocumentFacing = [string]$defaultPolicy.unsupportedRenderShape.nonDocumentFacing
        }
    }

    foreach ($renderAsKey in @($defaultPolicy.selectorsByRenderAs.Keys)) {
        $policy.selectorsByRenderAs[[string]$renderAsKey] = @($defaultPolicy.selectorsByRenderAs[$renderAsKey])
    }

    if ($collectorPolicy.ContainsKey('allowedRenderAs')) {
        $allowed = @($collectorPolicy.allowedRenderAs)
        if ($allowed.Count -eq 0) {
            throw "Mapping contract '$MappingContractPath' declares syncPolicy.collectorSkeletonMapping.allowedRenderAs but it is empty."
        }

        $resolvedAllowed = New-Object System.Collections.Generic.List[string]
        foreach ($candidate in $allowed) {
            $value = [string]$candidate
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Mapping contract '$MappingContractPath' has blank allowedRenderAs value under syncPolicy.collectorSkeletonMapping.allowedRenderAs."
            }

            if (-not $resolvedAllowed.Contains($value)) {
                $resolvedAllowed.Add($value)
            }
        }

        $policy.allowedRenderAs = @($resolvedAllowed)
    }

    $selectorsPolicy = ConvertTo-Dictionary -Value $collectorPolicy.selectors
    if ($null -ne $selectorsPolicy -and $selectorsPolicy.ContainsKey('defaultByRenderAs')) {
        $selectorsByRenderAs = ConvertTo-Dictionary -Value $selectorsPolicy.defaultByRenderAs
        if ($null -eq $selectorsByRenderAs) {
            throw "Mapping contract '$MappingContractPath' has syncPolicy.collectorSkeletonMapping.selectors.defaultByRenderAs but it is not an object."
        }

        $policy.selectorsByRenderAs = [ordered]@{}
        foreach ($renderAs in @($selectorsByRenderAs.Keys)) {
            $renderAsValue = [string]$renderAs
            if ([string]::IsNullOrWhiteSpace($renderAsValue)) {
                throw "Mapping contract '$MappingContractPath' has blank renderAs key in syncPolicy.collectorSkeletonMapping.selectors.defaultByRenderAs."
            }

            $selectorCandidates = @($selectorsByRenderAs[$renderAs])
            if ($selectorCandidates.Count -eq 0) {
                throw "Mapping contract '$MappingContractPath' has empty selector list for renderAs '$renderAsValue' in syncPolicy.collectorSkeletonMapping.selectors.defaultByRenderAs."
            }

            $selectorList = New-Object System.Collections.Generic.List[string]
            foreach ($selector in $selectorCandidates) {
                $selectorValue = [string]$selector
                if ([string]::IsNullOrWhiteSpace($selectorValue)) {
                    throw "Mapping contract '$MappingContractPath' has blank selector for renderAs '$renderAsValue' in syncPolicy.collectorSkeletonMapping.selectors.defaultByRenderAs."
                }

                if (-not $selectorList.Contains($selectorValue)) {
                    $selectorList.Add($selectorValue)
                }
            }

            $policy.selectorsByRenderAs[$renderAsValue] = @($selectorList)
        }
    }

    $unsupportedPolicy = ConvertTo-Dictionary -Value $collectorPolicy.unsupportedRenderShape
    if ($null -ne $unsupportedPolicy) {
        foreach ($policyKey in @('documentFacing', 'nonDocumentFacing')) {
            if (-not $unsupportedPolicy.ContainsKey($policyKey)) {
                continue
            }

            $policyValue = [string]$unsupportedPolicy[$policyKey]
            if ($policyValue -notin @('skip', 'warn', 'fail')) {
                throw "Mapping contract '$MappingContractPath' has unsupported value '$policyValue' for syncPolicy.collectorSkeletonMapping.unsupportedRenderShape.$policyKey. Expected one of: skip, warn, fail."
            }

            $policy.unsupportedRenderShape[$policyKey] = $policyValue
        }
    }

    return $policy
}

function Sync-CollectorSkeletonMappingFromContract {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ResolvedTechId,
        [Parameter(Mandatory = $true)][string]$ResolvedMappingContractRelativePath
    )

    $contractMappingPath = Join-Path $ContractsRoot $ResolvedMappingContractRelativePath
    if (-not (Test-Path -LiteralPath $contractMappingPath -PathType Leaf)) {
        throw "Required mapping contract not found at '$contractMappingPath'."
    }

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "ConvertFrom-Yaml is required to sync collector skeleton mapping from '$contractMappingPath'."
    }

    $contract = Get-Content -LiteralPath $contractMappingPath -Raw -Encoding UTF8 | ConvertFrom-Yaml
    if (
        $null -eq $contract -or
        [string]$contract.schema -ne 'mapping.dataset-to-sdt' -or
        [int]$contract.schemaVersion -ne 1 -or
        [string]$contract.techId -ne $ResolvedTechId
    ) {
        throw "Mapping contract '$contractMappingPath' failed validation (expected schema=mapping.dataset-to-sdt, schemaVersion=1, techId=$ResolvedTechId)."
    }

    $tagPolicy = New-CollectorSdtTagPolicyFromContract -MappingContractPath $contractMappingPath -Contract $contract
    $syncPolicy = New-CollectorMappingSyncPolicyFromContract -MappingContractPath $contractMappingPath -Contract $contract
    $datasetPathTemplateMap = Get-CollectorDatasetPathTemplateMap -ContractsRoot $ContractsRoot -ResolvedTechId $ResolvedTechId
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
                Write-Verbose ("[collector-mapping-sync] skip mapping[{0}] sourceKey={1} reason=missing dataset+tag (null entry)" -f $mappingIndex, $sourceKey)
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
            if ([string]::IsNullOrWhiteSpace($sourceTag) -and $entryTable.ContainsKey('target') -and $entryTable.target -is [System.Collections.IDictionary] -and $entryTable.target.ContainsKey('sdtTag')) {
                $sourceTag = [string]$entryTable.target.sdtTag
            }
            $sourceDatasetKey = if ([string]::IsNullOrWhiteSpace($sourceDataset)) { '<missing-dataset>' } else { $sourceDataset }
            $sourceTagKey = if ([string]::IsNullOrWhiteSpace($sourceTag)) { '<missing-tag>' } else { $sourceTag }
            $sourceKey = "$sourceDatasetKey|$sourceTagKey"
            Write-Verbose ("[collector-mapping-sync] processing mapping[{0}] sourceKey={1}" -f $mappingIndex, $sourceKey)

            $datasetName = $sourceDataset
            $resolvedTag = Get-CollectorSdtTagFromContract -MappingEntry $entryTable -TagPolicy $tagPolicy

            if ([string]::IsNullOrWhiteSpace($datasetName)) {
                $skipReasonCounters.missingDataset++
                Write-Verbose ("[collector-mapping-sync] skip mapping[{0}] sourceKey={1} reason=missing dataset" -f $mappingIndex, $sourceKey)
                continue
            }

            if ([string]::IsNullOrWhiteSpace($resolvedTag)) {
                $skipReasonCounters.missingTag++
                Write-Verbose ("[collector-mapping-sync] skip mapping[{0}] sourceKey={1} reason=missing tag" -f $mappingIndex, $sourceKey)
                continue
            }

            $mappingEntry = [ordered]@{
                dataset = (Get-CollectorDatasetPathFromTemplate -DatasetName $datasetName -ResolvedTechId $ResolvedTechId -DatasetPathTemplateMap $datasetPathTemplateMap)
                required = [bool]$entryTable.required
            }

            $entryPhase = if ($entryTable.ContainsKey('phase')) { [string]$entryTable.phase } else { '' }
            $emitTargetOnly = $entryPhase -eq 'target-first'
            if (-not $emitTargetOnly) {
                # Transitional dual-form default: keep top-level sdtTag while also emitting target.sdtTag.
                $mappingEntry.sdtTag = $resolvedTag
            }
            $mappingEntry.target = [ordered]@{
                sdtTag = $resolvedTag
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

            $renderHint = [ordered]@{}
            if ($null -ne $renderHintSource) {
                foreach ($renderHintKey in @('renderAs', 'projectionRef', 'view')) {
                    if ($renderHintSource.ContainsKey($renderHintKey) -and -not [string]::IsNullOrWhiteSpace([string]$renderHintSource[$renderHintKey])) {
                        $renderHint[$renderHintKey] = [string]$renderHintSource[$renderHintKey]
                    }
                }
            }

            if ($renderHint.Count -gt 0) {
                $resolvedRenderAs = if ($renderHint.ContainsKey('renderAs')) { [string]$renderHint.renderAs } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($resolvedRenderAs) -and $resolvedRenderAs -notin @($syncPolicy.allowedRenderAs)) {
                    $unsupportedAction = if ([bool]$entryTable.required) {
                        [string]$syncPolicy.unsupportedRenderShape.documentFacing
                    }
                    else {
                        [string]$syncPolicy.unsupportedRenderShape.nonDocumentFacing
                    }

                    if ([string]::IsNullOrWhiteSpace($unsupportedAction)) {
                        $unsupportedAction = if ([bool]$entryTable.required) { 'fail' } else { 'skip' }
                    }

                    $skipReasonCounters.unsupportedShape++
                    $message = "unsupported render shape renderAs='$resolvedRenderAs' action='$unsupportedAction' allowedRenderAs='$(@($syncPolicy.allowedRenderAs) -join ',')'"
                    switch ($unsupportedAction) {
                        'warn' {
                            Write-Warning ("[collector-mapping-sync] mapping[{0}] sourceKey={1} {2}; skipping mapping." -f $mappingIndex, $sourceKey, $message)
                            continue
                        }
                        'skip' {
                            Write-Verbose ("[collector-mapping-sync] skip mapping[{0}] sourceKey={1} reason={2}" -f $mappingIndex, $sourceKey, $message)
                            continue
                        }
                        default {
                            throw "Contract policy rejected mapping[$mappingIndex] key '$sourceKey': $message"
                        }
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($resolvedRenderAs)) {
                    if (-not $syncPolicy.selectorsByRenderAs.ContainsKey($resolvedRenderAs)) {
                        throw "Contract policy missing selectors for renderAs '$resolvedRenderAs' at mapping[$mappingIndex] key '$sourceKey'. Define syncPolicy.collectorSkeletonMapping.selectors.defaultByRenderAs.$resolvedRenderAs."
                    }

                    $selectors = @($syncPolicy.selectorsByRenderAs[$resolvedRenderAs])
                    if ($selectors.Count -eq 0) {
                        throw "Contract policy resolved empty selector defaults for renderAs '$resolvedRenderAs' at mapping[$mappingIndex] key '$sourceKey'."
                    }

                    $mappingEntry.selectors = @($selectors)
                }

                $mappingEntry.renderHint = $renderHint
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
            throw "Mapping generation failed for contract '$contractMappingPath' at mapping[$mappingIndex] key '$sourceKey': $message"
        }
    }

    $skippedCount = $processedCount - $generatedCount
    Write-Verbose ("[collector-mapping-sync] totals: processed={0}; skipped={1}; generated={2}" -f $processedCount, $skippedCount, $generatedCount)
    Write-Verbose ("[collector-mapping-sync] skip reasons: missingDataset={0}; missingTag={1}; unsupportedShape={2}" -f $skipReasonCounters.missingDataset, $skipReasonCounters.missingTag, $skipReasonCounters.unsupportedShape)

    $outputDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $generatedMapping = [ordered]@{
        schema = 'mapping.dataset-to-sdt'
        schemaVersion = 1
        techId = $ResolvedTechId
        displayName = "$ResolvedTechId collector blueprint mapping"
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
            path = $ResolvedMappingContractRelativePath
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

    if ($PSBoundParameters.ContainsKey('TechId') -and [string]::IsNullOrWhiteSpace($TechId)) {
        throw "TechId cannot be empty when provided."
    }

    if ($PSBoundParameters.ContainsKey('MappingContractRelativePath') -and -not $PSBoundParameters.ContainsKey('TechId')) {
        throw "MappingContractRelativePath requires TechId; it cannot be used in auto-discovery mode."
    }

    if ($PSBoundParameters.ContainsKey('SkeletonMappingOutputPath') -and -not $PSBoundParameters.ContainsKey('TechId')) {
        throw "SkeletonMappingOutputPath requires TechId; it cannot be used in auto-discovery mode."
    }
    $stepTimer.Stop()
    Update-SyncProgress -ProgressContext $progressContext -StageName 'Validate params' -Status 'Validated parameters' -Position 1
    Write-SyncStep -Stage 'input validation' -Message 'Validated parameter combinations and operating mode.' -Details ([ordered]@{
            useLocalCopy = $useLocalCopy
            techId = if ($PSBoundParameters.ContainsKey('TechId')) { $TechId.Trim() } else { '<auto-discover-under-tech-root>' }
            mappingContractRelativePath = if ($PSBoundParameters.ContainsKey('MappingContractRelativePath')) { $MappingContractRelativePath } else { '<derived-per-tech>' }
            skeletonMappingOutputPath = if ($PSBoundParameters.ContainsKey('SkeletonMappingOutputPath')) { $SkeletonMappingOutputPath } else { '<derived-per-tech>' }
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

        $postSync = Invoke-PostSyncProcessing -ContractsRoot $DepsContractsPath -RepoRoot (Join-Path $PSScriptRoot '..') -RequestedTechId $TechId -BoundParameters $PSBoundParameters -RequestedMappingContractRelativePath $MappingContractRelativePath -RequestedSkeletonMappingOutputPath $SkeletonMappingOutputPath -SnapshotData ([ordered]@{
                schemaVersion = 1
                syncedUtc = (Get-Date).ToUniversalTime().ToString('o')
                source = 'local-export-copy'
                exportContractsPath = $sourceRoot
            }) -ProgressContext $progressContext -StepTimer $stepTimer -Stage ([ref]$stage)

        $result = [ordered]@{
            status = 'ok'
            mode = 'LocalExport'
            sourceRoot = $sourceRoot
            destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
            snapshotPath = $postSync.snapshotPath
            skeletonMappingPaths = @($postSync.skeletonMappingPaths)
            skippedTechIds = @($postSync.skippedTechIds)
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

        $postSync = Invoke-PostSyncProcessing -ContractsRoot $DepsContractsPath -RepoRoot (Join-Path $PSScriptRoot '..') -RequestedTechId $TechId -BoundParameters $PSBoundParameters -RequestedMappingContractRelativePath $MappingContractRelativePath -RequestedSkeletonMappingOutputPath $SkeletonMappingOutputPath -SnapshotData ([ordered]@{
                schemaVersion = 1
                syncedUtc = (Get-Date).ToUniversalTime().ToString('o')
                source = 'published-pack'
                version = $resolvedVersion
                tag = $resolvedTag
                packUrl = $packUrl
                releaseUrl = $releasePageUrl
                packPath = $tmpZip
            }) -ProgressContext $progressContext -StepTimer $stepTimer -Stage ([ref]$stage)

        $result = [ordered]@{
            status = 'ok'
            mode = if ($ContractsPackUrl) { 'PackUrl' } elseif ($ContractsVersion) { 'PackVersion' } else { 'PackLatest' }
            version = $resolvedVersion
            tag = $resolvedTag
            packUrl = $packUrl
            releaseUrl = $releasePageUrl
            destinationRoot = (Resolve-Path -LiteralPath $DepsContractsPath).Path
            snapshotPath = $postSync.snapshotPath
            skeletonMappingPaths = @($postSync.skeletonMappingPaths)
            skippedTechIds = @($postSync.skippedTechIds)
        }
    }

    $syncStopwatch.Stop()
    Update-SyncProgress -ProgressContext $progressContext -StageName 'Finalize' -Status 'Finalizing sync report' -Position 0.5
    Write-SyncStep -Stage 'final report' -Message 'Contracts sync completed successfully.' -Details ([ordered]@{
            mode = $result.mode
            destinationRoot = $result.destinationRoot
            snapshotPath = $result.snapshotPath
            skeletonMappingPaths = if ($result.ContainsKey('skeletonMappingPaths')) { ($result.skeletonMappingPaths -join ', ') } else { '<none>' }
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
