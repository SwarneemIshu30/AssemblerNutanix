#!/usr/bin/env pwsh
<#
.SYNOPSIS
Populate SDT placeholder tags from a Direct-v1 bundle and mapping contract.
#>
param(
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$MappingPath,
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $false)][string]$ReportPath,
    [Parameter(Mandatory = $false)][string]$ContractsRoot,
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
    [Parameter(Mandatory = $false)][string]$SupportRegionSidecarPath,
    [Parameter(Mandatory = $false)][switch]$AnnotateResolvedTags,
    [Parameter(Mandatory = $false)][switch]$EnableDiagramRendering,
    [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
    [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerSchemaValidation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerDocxLiteralTokens.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-UtcTimestamp { (Get-Date).ToUniversalTime().ToString('o') }

function Test-MapHasKey {
    param(
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ($null -eq $Map) { return $false }

    if ($null -ne $Map.PSObject.Methods['ContainsKey']) {
        return [bool]$Map.ContainsKey($Key)
    }

    if ($null -ne $Map.PSObject.Methods['Contains']) {
        return [bool]$Map.Contains($Key)
    }

    foreach ($candidateKey in @($Map.Keys)) {
        if ([string]$candidateKey -eq $Key) {
            return $true
        }
    }

    return $false
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }

    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
}

function Get-SupportMapValue {
    param(
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)]$Default = $null
    )

    if ($null -eq $Map) { return $Default }
    if ($null -ne $Map.PSObject.Methods['ContainsKey'] -and $Map.ContainsKey($Key)) { return $Map[$Key] }
    if ($null -ne $Map.PSObject.Methods['Contains'] -and $Map.Contains($Key)) { return $Map[$Key] }
    foreach ($candidateKey in @($Map.Keys)) {
        if ([string]$candidateKey -eq $Key) { return $Map[$candidateKey] }
    }

    return $Default
}

function Format-SupportPhoneNumbers {
    param(
        [Parameter(Mandatory = $false)]$PhoneNumbers,
        [Parameter(Mandatory = $false)][switch]$Inline
    )

    $formatted = [System.Collections.Generic.List[string]]::new()
    foreach ($phoneNumber in @($PhoneNumbers)) {
        if ($null -eq $phoneNumber) { continue }
        if ($phoneNumber -is [System.Collections.IDictionary]) {
            $label = [string](Get-SupportMapValue -Map $phoneNumber -Key 'label' -Default '')
            $number = [string](Get-SupportMapValue -Map $phoneNumber -Key 'number' -Default '')
            if ([string]::IsNullOrWhiteSpace($label) -and [string]::IsNullOrWhiteSpace($number)) { continue }
            if ([string]::IsNullOrWhiteSpace($label)) {
                $formatted.Add($number)
            }
            elseif ([string]::IsNullOrWhiteSpace($number)) {
                $formatted.Add($label)
            }
            else {
                $formatted.Add(('{0}: {1}' -f $label, $number))
            }
        }
        else {
            $value = [string]$phoneNumber
            if (-not [string]::IsNullOrWhiteSpace($value)) { $formatted.Add($value) }
        }
    }

    if ($Inline.IsPresent) { return ($formatted.ToArray() -join '; ') }
    return ($formatted.ToArray() -join [Environment]::NewLine)
}

function Format-SupportGuidance {
    param([Parameter(Mandatory = $false)]$Guidance)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Guidance)) {
        $value = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($value)) { $lines.Add($value) }
    }

    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Format-SupportLanguages {
    param([Parameter(Mandatory = $false)]$Languages)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($language in @($Languages)) {
        $value = [string]$language
        if (-not [string]::IsNullOrWhiteSpace($value)) { $lines.Add($value) }
    }

    return ($lines.ToArray() -join ', ')
}

function New-SupportProcessText {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$SupportRegionModel)

    $paragraphs = [System.Collections.Generic.List[string]]::new()
    $regionLabel = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportRegionLabel' -Default '')
    $supportTier = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportTier' -Default '')
    $phoneNumbersInline = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPhoneNumbersInline' -Default '')
    $workingHours = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportWorkingHours' -Default '')
    $languages = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportLanguages' -Default '')
    $serviceRequestUrl = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportServiceRequestUrl' -Default '')
    $supportPortalUrl = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPortalUrl' -Default '')
    $supportPlanUrl = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPlanUrl' -Default '')
    $guidance = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportGuidance' -Default '')

    if (-not [string]::IsNullOrWhiteSpace($regionLabel) -and -not [string]::IsNullOrWhiteSpace($supportTier)) {
        $paragraphs.Add(("For {0}, raise entitled Lenovo storage hardware or software incidents through {1}." -f $regionLabel, $supportTier))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($supportTier)) {
        $paragraphs.Add(("Raise entitled Lenovo storage hardware or software incidents through {0}." -f $supportTier))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($regionLabel)) {
        $paragraphs.Add(("Use the Lenovo Data Center Support process for {0}." -f $regionLabel))
    }

    if (-not [string]::IsNullOrWhiteSpace($phoneNumbersInline)) {
        $paragraphs.Add(("Phone support: {0}." -f $phoneNumbersInline))
    }

    if (-not [string]::IsNullOrWhiteSpace($workingHours)) {
        $paragraphs.Add(("Working hours: {0}." -f $workingHours))
    }

    if (-not [string]::IsNullOrWhiteSpace($languages)) {
        $paragraphs.Add(("Support language: {0}." -f $languages))
    }

    if (-not [string]::IsNullOrWhiteSpace($serviceRequestUrl)) {
        $paragraphs.Add(("Web support: open {0}. Sign in as required, confirm the registered serial number and product entitlement, choose the relevant hardware or software problem type, describe the fault and business impact, and upload controller/support logs where available." -f $serviceRequestUrl))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($supportPortalUrl)) {
        $paragraphs.Add(("Web support: open {0}. Sign in as required, confirm the registered serial number and product entitlement, describe the fault and business impact, and upload controller/support logs where available." -f $supportPortalUrl))
    }

    if (-not [string]::IsNullOrWhiteSpace($guidance)) {
        foreach ($line in @($guidance -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $paragraphs.Add([string]$line) }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($supportPlanUrl)) {
        $paragraphs.Add(("For current entitlement and case-handling guidance, refer to {0}." -f $supportPlanUrl))
    }

    return ($paragraphs.ToArray() -join [Environment]::NewLine)
}

function Resolve-SupportRegionDocumentModel {
    param(
        [Parameter(Mandatory = $false)][string]$SupportRegion,
        [Parameter(Mandatory = $false)][string]$SupportTier,
        [Parameter(Mandatory = $false)][string]$SidecarPath
    )

    $requestedRegion = ([string]$SupportRegion).Trim()
    $requestedTier = ([string]$SupportTier).Trim()
    $selectedRegion = $null
    $selectedTier = $null
    $selectedTierId = $requestedTier
    $resolvedSidecarPath = ''
    $defaultSupportTier = ''

    if (-not [string]::IsNullOrWhiteSpace($SidecarPath) -and (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
        $resolvedSidecarPath = (Resolve-Path -LiteralPath $SidecarPath).Path
        $sidecar = Read-JsonFile -Path $resolvedSidecarPath
        $defaultSupportTier = [string](Get-SupportMapValue -Map $sidecar -Key 'defaultSupportTier' -Default '')
        $regions = @(Get-SupportMapValue -Map $sidecar -Key 'regions' -Default @())
        if (-not [string]::IsNullOrWhiteSpace($requestedRegion)) {
            foreach ($region in $regions) {
                if ($region -isnot [System.Collections.IDictionary]) { continue }
                $id = [string](Get-SupportMapValue -Map $region -Key 'id' -Default '')
                $label = [string](Get-SupportMapValue -Map $region -Key 'label' -Default '')
                $display = if ([string]::IsNullOrWhiteSpace($label)) { $id } else { ('{0} - {1}' -f $id, $label) }
                if ($requestedRegion -ieq $id -or $requestedRegion -ieq $label -or $requestedRegion -ieq $display) {
                    $selectedRegion = $region
                    break
                }
            }
        }

        if ($null -eq $selectedRegion) {
            $defaultRegion = [string](Get-SupportMapValue -Map $sidecar -Key 'defaultRegion' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($defaultRegion)) {
                foreach ($region in $regions) {
                    if ($region -isnot [System.Collections.IDictionary]) { continue }
                    if ($defaultRegion -ieq [string](Get-SupportMapValue -Map $region -Key 'id' -Default '')) {
                        $selectedRegion = $region
                        break
                    }
                }
            }
        }

        if ($null -eq $selectedRegion -and @($regions).Count -gt 0 -and $regions[0] -is [System.Collections.IDictionary]) {
            $selectedRegion = $regions[0]
        }
    }

    $model = [ordered]@{
        SupportRegion = $requestedRegion
        DocSupportRegion = $requestedRegion
        SupportTierId = $requestedTier
        DocSupportTier = $requestedTier
        SupportRegionLabel = ''
        SupportRegionDisplayName = $requestedRegion
        SupportLanguage = ''
        SupportLanguages = ''
        SupportWorkingHours = ''
        SupportCountryCode = ''
        SupportTier = ''
        SupportPhoneNumbers = ''
        SupportPhoneNumbersInline = ''
        SupportServiceRequestUrl = ''
        SupportPortalUrl = ''
        SupportPhoneListUrl = ''
        SupportPlanUrl = ''
        SupportGuidance = ''
        SupportProcessText = ''
        SupportRegionSidecarPath = $resolvedSidecarPath
    }

    if ($selectedRegion -is [System.Collections.IDictionary]) {
        $id = [string](Get-SupportMapValue -Map $selectedRegion -Key 'id' -Default $requestedRegion)
        $label = [string](Get-SupportMapValue -Map $selectedRegion -Key 'label' -Default '')
        $display = if ([string]::IsNullOrWhiteSpace($label)) { $id } else { ('{0} - {1}' -f $id, $label) }
        $supportTiers = Get-SupportMapValue -Map $selectedRegion -Key 'supportTiers' -Default $null
        if ($supportTiers -is [System.Collections.IDictionary] -and @($supportTiers.Keys).Count -gt 0) {
            $tierCandidates = @()
            if (-not [string]::IsNullOrWhiteSpace($requestedTier)) { $tierCandidates += $requestedTier }
            if (-not [string]::IsNullOrWhiteSpace($defaultSupportTier)) { $tierCandidates += $defaultSupportTier }
            $tierCandidates += @('Premier', 'ESS')

            foreach ($tierCandidate in @($tierCandidates)) {
                if ([string]::IsNullOrWhiteSpace([string]$tierCandidate)) { continue }
                foreach ($tierKey in @($supportTiers.Keys)) {
                    $tier = $supportTiers[$tierKey]
                    if ($tier -isnot [System.Collections.IDictionary]) { continue }
                    $tierId = [string](Get-SupportMapValue -Map $tier -Key 'id' -Default $tierKey)
                    $tierLabel = [string](Get-SupportMapValue -Map $tier -Key 'label' -Default $tierId)
                    if ([string]$tierCandidate -ieq [string]$tierKey -or [string]$tierCandidate -ieq $tierId -or [string]$tierCandidate -ieq $tierLabel) {
                        $selectedTier = $tier
                        $selectedTierId = $tierId
                        break
                    }
                }
                if ($null -ne $selectedTier) { break }
            }

            if ($null -eq $selectedTier) {
                foreach ($tierKey in @($supportTiers.Keys)) {
                    $tier = $supportTiers[$tierKey]
                    if ($tier -is [System.Collections.IDictionary]) {
                        $selectedTier = $tier
                        $selectedTierId = [string](Get-SupportMapValue -Map $tier -Key 'id' -Default $tierKey)
                        break
                    }
                }
            }
        }
        $phoneNumbers = if ($selectedTier -is [System.Collections.IDictionary]) { Get-SupportMapValue -Map $selectedTier -Key 'phoneNumbers' -Default @() } else { Get-SupportMapValue -Map $selectedRegion -Key 'phoneNumbers' -Default @() }
        $languages = if ($selectedTier -is [System.Collections.IDictionary]) { Get-SupportMapValue -Map $selectedTier -Key 'languages' -Default (Get-SupportMapValue -Map $selectedRegion -Key 'languages' -Default @()) } else { Get-SupportMapValue -Map $selectedRegion -Key 'languages' -Default @() }
        $languageText = Format-SupportLanguages -Languages $languages
        if ([string]::IsNullOrWhiteSpace($languageText)) {
            $languageText = [string](Get-SupportMapValue -Map $selectedRegion -Key 'language' -Default '')
        }

        $model.SupportRegion = $id
        $model.DocSupportRegion = $id
        $model.SupportTierId = $selectedTierId
        $model.DocSupportTier = $selectedTierId
        $model.SupportRegionLabel = $label
        $model.SupportRegionDisplayName = $display
        $model.SupportLanguage = $languageText
        $model.SupportLanguages = $languageText
        $model.SupportWorkingHours = if ($selectedTier -is [System.Collections.IDictionary]) { [string](Get-SupportMapValue -Map $selectedTier -Key 'workingHours' -Default '') } else { [string](Get-SupportMapValue -Map $selectedRegion -Key 'workingHours' -Default '') }
        $model.SupportCountryCode = [string](Get-SupportMapValue -Map $selectedRegion -Key 'countryCode' -Default '')
        $model.SupportTier = if ($selectedTier -is [System.Collections.IDictionary]) { [string](Get-SupportMapValue -Map $selectedTier -Key 'label' -Default $selectedTierId) } else { [string](Get-SupportMapValue -Map $selectedRegion -Key 'supportTier' -Default $selectedTierId) }
        $model.SupportPhoneNumbers = Format-SupportPhoneNumbers -PhoneNumbers $phoneNumbers
        $model.SupportPhoneNumbersInline = Format-SupportPhoneNumbers -PhoneNumbers $phoneNumbers -Inline
        $model.SupportServiceRequestUrl = if ($selectedTier -is [System.Collections.IDictionary]) { [string](Get-SupportMapValue -Map $selectedTier -Key 'serviceRequestUrl' -Default (Get-SupportMapValue -Map $selectedRegion -Key 'serviceRequestUrl' -Default '')) } else { [string](Get-SupportMapValue -Map $selectedRegion -Key 'serviceRequestUrl' -Default '') }
        $model.SupportPortalUrl = if ($selectedTier -is [System.Collections.IDictionary]) { [string](Get-SupportMapValue -Map $selectedTier -Key 'supportPortalUrl' -Default (Get-SupportMapValue -Map $selectedRegion -Key 'supportPortalUrl' -Default '')) } else { [string](Get-SupportMapValue -Map $selectedRegion -Key 'supportPortalUrl' -Default '') }
        $model.SupportPhoneListUrl = if ($selectedTier -is [System.Collections.IDictionary]) { [string](Get-SupportMapValue -Map $selectedTier -Key 'supportPhoneListUrl' -Default (Get-SupportMapValue -Map $selectedRegion -Key 'supportPhoneListUrl' -Default '')) } else { [string](Get-SupportMapValue -Map $selectedRegion -Key 'supportPhoneListUrl' -Default '') }
        $model.SupportPlanUrl = if ($selectedTier -is [System.Collections.IDictionary]) { [string](Get-SupportMapValue -Map $selectedTier -Key 'supportPlanUrl' -Default (Get-SupportMapValue -Map $selectedRegion -Key 'supportPlanUrl' -Default '')) } else { [string](Get-SupportMapValue -Map $selectedRegion -Key 'supportPlanUrl' -Default '') }
        $model.SupportGuidance = Format-SupportGuidance -Guidance (Get-SupportMapValue -Map $selectedRegion -Key 'guidance' -Default @())
    }

    $model.SupportProcessText = New-SupportProcessText -SupportRegionModel $model
    return $model
}

function Get-FileSha256Hex {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($Bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Resolve-AssemblerContractsRoot {
    param(
        [Parameter(Mandatory = $false)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ContractsRoot)) {
        if (-not (Test-Path -LiteralPath $ContractsRoot -PathType Container)) {
            throw "ContractsRoot '$ContractsRoot' was provided but does not exist."
        }
        return (Resolve-Path -LiteralPath $ContractsRoot).Path
    }

    $candidates = @(
        (Join-Path $RepoRoot '.deps/contracts')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Unable to resolve contracts root. Checked: $($candidates -join ', ')."
}

function Resolve-Selector {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $current = $InputObject
    $resolved = $true
    foreach ($segment in $Selector.Split('.')) {
        if ($null -eq $current) {
            $resolved = $false
            break
        }

        if ($current -is [System.Collections.IDictionary]) {
            if (-not (Test-MapHasKey -Map $current -Key $segment)) {
                $resolved = $false
                break
            }
            $current = $current[$segment]
            continue
        }

        if ($current -is [System.Collections.IList]) {
            [int]$idx = 0
            if (-not [int]::TryParse($segment, [ref]$idx)) {
                $resolved = $false
                break
            }
            if ($idx -lt 0 -or $idx -ge $current.Count) {
                $resolved = $false
                break
            }
            $current = $current[$idx]
            continue
        }

        $resolved = $false
        break
    }

    return [ordered]@{
        found = $resolved
        value = $current
        valueIsNull = ($resolved -and $null -eq $current)
        valueIsEmptyArray = ($resolved -and $current -is [System.Array] -and $current.Length -eq 0)
    }
}


function Resolve-DatasetFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$DatasetRelativePath,
        [Parameter(Mandatory = $false)][string]$TechId
    )

    $exactPath = Join-Path $BundleRoot $DatasetRelativePath
    return [ordered]@{ path = $exactPath; autoResolved = $false; reason = $null }
}

function Get-UnresolvedMappingDatasetPlaceholderViolations {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Mapping
    )

    $violations = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-MapHasKey -Map $Mapping -Key 'mappings')) {
        return @($violations.ToArray())
    }

    foreach ($entry in @($Mapping.mappings)) {
        if (-not ($entry -is [System.Collections.IDictionary])) { continue }
        if (-not (Test-MapHasKey -Map $entry -Key 'dataset')) { continue }

        $datasetPath = [string]$entry.dataset
        if ([string]::IsNullOrWhiteSpace($datasetPath)) { continue }
        if ($datasetPath -notmatch '__TARGET__|__SYSTEM__') { continue }

        $tag = if (Test-MapHasKey -Map $entry -Key 'sdtTag') { [string]$entry['sdtTag'] } elseif ((Test-MapHasKey -Map $entry -Key 'target') -and $entry['target'] -is [System.Collections.IDictionary] -and (Test-MapHasKey -Map $entry['target'] -Key 'sdtTag')) { [string]$entry['target']['sdtTag'] } else { '' }

        $violations.Add([ordered]@{
            dataset = $datasetPath
            tag = $tag
        })
    }

    return @($violations.ToArray())
}

function Test-DatasetEnvelope {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Dataset,
        [Parameter(Mandatory = $true)][string]$DatasetPath
    )

    # Validation rules are sourced from:
    # .deps/contracts/standards/architecture.direct-v1.collector-contracts.md
    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not $Dataset.ContainsKey('schema_version') -or [string]::IsNullOrWhiteSpace([string]$Dataset.schema_version)) {
        $errors.Add("Dataset envelope missing required field 'schema_version'")
    }
    elseif ([string]$Dataset.schema_version -ne 'lnv.collector.dataset.v1') {
        $errors.Add("Dataset envelope schema_version must be 'lnv.collector.dataset.v1' (got '$($Dataset.schema_version)')")
    }

    foreach ($requiredField in @('collector', 'source', 'dataset', 'item_count', 'items')) {
        if (-not $Dataset.ContainsKey($requiredField)) {
            $errors.Add("Dataset envelope missing required field '$requiredField'")
        }
    }

    if ($Dataset.ContainsKey('items') -and $Dataset.items -is [System.Collections.IList]) {
        [int]$itemCount = 0
        if (-not [int]::TryParse([string]$Dataset.item_count, [ref]$itemCount)) {
            $errors.Add("Dataset envelope field 'item_count' must be an integer when 'items' is an array")
        }
        elseif ($itemCount -ne @($Dataset.items).Count) {
            $errors.Add("Dataset envelope item_count ($itemCount) must equal items.Length (@($Dataset.items).Count)")
        }
    }

    return @($errors.ToArray())
}

function Test-LegacySummaryCompatibilityDataset {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Dataset,
        [Parameter(Mandatory = $true)][string]$DatasetPath
    )

    if ([string]::IsNullOrWhiteSpace($DatasetPath)) { return $false }
    if ([System.IO.Path]::GetFileName($DatasetPath) -ne 'run_summary.json') { return $false }
    if ($Dataset.ContainsKey('schema_version') -or $Dataset.ContainsKey('items')) { return $false }

    foreach ($requiredField in @('collectedUtc', 'mode', 'controller', 'port', 'systemCount')) {
        if (-not $Dataset.ContainsKey($requiredField)) {
            return $false
        }
    }

    return $true
}

function Resolve-SelectorWithSummaryCompatibility {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Dataset,
        [Parameter(Mandatory = $true)][string[]]$Selectors,
        [Parameter(Mandatory = $true)][string]$DatasetPath
    )

    $resolved = $Dataset
    foreach ($selector in $Selectors) {
        $resolution = Resolve-Selector -InputObject $resolved -Selector ([string]$selector)
        if (-not $resolution.found) {
            $summaryItem = $null
            if (
                [System.IO.Path]::GetFileName($DatasetPath) -eq 'run_summary.json' -and
                $Dataset.ContainsKey('items') -and
                $Dataset.items -is [System.Collections.IList] -and
                @($Dataset.items).Count -eq 1 -and
                $Dataset.items[0] -is [hashtable] -and
                -not [string]::IsNullOrWhiteSpace([string]$selector) -and
                -not ([string]$selector).StartsWith('items.', [System.StringComparison]::Ordinal)
            ) {
                $summaryItem = $Dataset.items[0]
            }

            if ($null -ne $summaryItem) {
                $resolution = Resolve-Selector -InputObject $summaryItem -Selector ([string]$selector)
            }

            if (-not $resolution.found) {
                return [ordered]@{
                    value = $null
                    selectorFailed = $true
                    valueIsNull = $false
                    valueIsEmptyArray = $false
                }
            }
        }

        $resolved = $resolution.value
    }

    return [ordered]@{
        value = $resolved
        selectorFailed = $false
        valueIsNull = [bool]$resolution.valueIsNull
        valueIsEmptyArray = [bool]$resolution.valueIsEmptyArray
    }
}

function Convert-CellValueToString {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [ValueType]) { return [string]$Value }

    return ($Value | ConvertTo-Json -Depth 10 -Compress)
}

function Get-UnresolvedSdtTagOccurrences {
    param(
        [Parameter(Mandatory = $true)][string]$RenderedText
    )

    $matches = [regex]::Matches($RenderedText, '<<SDT:\s*(?<tag>[^>]+?)\s*>>')
    $occurrencesByTag = @{}
    if ($matches.Count -eq 0) { return $occurrencesByTag }

    $lineStartIndices = [System.Collections.Generic.List[int]]::new()
    $lineStartIndices.Add(0)
    for ($idx = 0; $idx -lt $RenderedText.Length; $idx++) {
        if ($RenderedText[$idx] -eq "`n") {
            $lineStartIndices.Add($idx + 1)
        }
    }

    foreach ($tokenMatch in $matches) {
        $tag = ([string]$tokenMatch.Groups['tag'].Value).Trim()
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }

        if (-not (Test-MapHasKey -Map $occurrencesByTag -Key $tag)) {
            $occurrencesByTag[$tag] = [ordered]@{
                tag = $tag
                count = 0
                locations = [System.Collections.Generic.List[hashtable]]::new()
            }
        }

        $occurrence = $occurrencesByTag[$tag]
        $occurrence.count = [int]$occurrence.count + 1

        $lineNumber = 1
        for ($lineIdx = 0; $lineIdx -lt $lineStartIndices.Count; $lineIdx++) {
            if ($lineIdx -eq ($lineStartIndices.Count - 1) -or $lineStartIndices[$lineIdx + 1] -gt $tokenMatch.Index) {
                $lineNumber = $lineIdx + 1
                break
            }
        }

        $columnNumber = ($tokenMatch.Index - $lineStartIndices[$lineNumber - 1]) + 1
        $occurrence.locations.Add([ordered]@{ line = $lineNumber; column = $columnNumber })
    }

    return $occurrencesByTag
}

function Merge-UnresolvedSdtTagOccurrences {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Target,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Source
    )

    foreach ($tag in @($Source.Keys)) {
        if (-not (Test-MapHasKey -Map $Target -Key $tag)) {
            $Target[$tag] = [ordered]@{
                tag = $tag
                count = 0
                locations = [System.Collections.Generic.List[hashtable]]::new()
            }
        }

        $targetOccurrence = $Target[$tag]
        $sourceOccurrence = $Source[$tag]
        $targetOccurrence.count = [int]$targetOccurrence.count + [int]$sourceOccurrence.count

        foreach ($location in @($sourceOccurrence.locations)) {
            $targetOccurrence.locations.Add([ordered]@{ line = [int]$location.line; column = [int]$location.column })
        }
    }
}

function Get-WordXmlPartEntries {
    param([Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive)

    return @(
        Get-AssemblerWordXmlPartNames -Archive $Archive |
            ForEach-Object { $Archive.GetEntry([string]$_) } |
            Where-Object { $null -ne $_ }
    )
}

function Set-ZipEntryText {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchiveEntry]$Entry,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $stream = $Entry.Open()
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($stream, $utf8NoBom)
        try {
            $writer.Write($Text)
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Set-XmlNodeInnerText {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$Node,
        [Parameter(Mandatory = $false)][string]$Value
    )

    if ($null -eq $Node) { return }
    $Node.InnerText = [string]$Value
}

function Update-DocxMetadataProperties {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $false)][string]$Title,
        [Parameter(Mandatory = $false)][string]$Customer,
        [Parameter(Mandatory = $false)][string]$CustomerAbbr,
        [Parameter(Mandatory = $false)][string]$Location,
        [Parameter(Mandatory = $false)][string]$Subsidiary,
        [Parameter(Mandatory = $false)][string]$Environment,
        [Parameter(Mandatory = $false)][string]$DocumentReference,
        [Parameter(Mandatory = $false)][string]$Version,
        [Parameter(Mandatory = $false)][string]$ConfigSnapDate,
        [Parameter(Mandatory = $false)][string]$ReferenceId,
        [Parameter(Mandatory = $false)][string]$Classification,
        [Parameter(Mandatory = $false)][string]$SupportRegion,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$SupportRegionModel
    )

    $coreEntry = $Archive.GetEntry('docProps/core.xml')
    if ($null -ne $coreEntry -and -not [string]::IsNullOrWhiteSpace($Title)) {
        $coreTextReader = [System.IO.StreamReader]::new($coreEntry.Open())
        try {
            $coreXmlText = $coreTextReader.ReadToEnd()
        }
        finally {
            $coreTextReader.Dispose()
        }

        [xml]$coreXml = $coreXmlText
        $coreNs = [System.Xml.XmlNamespaceManager]::new($coreXml.NameTable)
        $coreNs.AddNamespace('cp', 'http://schemas.openxmlformats.org/package/2006/metadata/core-properties')
        $coreNs.AddNamespace('dc', 'http://purl.org/dc/elements/1.1/')
        $titleNode = $coreXml.SelectSingleNode('/cp:coreProperties/dc:title', $coreNs)
        if ($null -eq $titleNode) {
            $root = $coreXml.SelectSingleNode('/cp:coreProperties', $coreNs)
            if ($null -ne $root) {
                $titleNode = $coreXml.CreateElement('dc', 'title', 'http://purl.org/dc/elements/1.1/')
                [void]$root.AppendChild($titleNode)
            }
        }
        Set-XmlNodeInnerText -Node $titleNode -Value $Title
        $coreEntry.Delete()
        $updatedCoreEntry = $Archive.CreateEntry('docProps/core.xml')
        Set-ZipEntryText -Entry $updatedCoreEntry -Text $coreXml.OuterXml
    }

    $customEntry = $Archive.GetEntry('docProps/custom.xml')
    if ($null -eq $customEntry) { return }

    $customTextReader = [System.IO.StreamReader]::new($customEntry.Open())
    try {
        $customXmlText = $customTextReader.ReadToEnd()
    }
    finally {
        $customTextReader.Dispose()
    }

    [xml]$customXml = $customXmlText
    $customNs = [System.Xml.XmlNamespaceManager]::new($customXml.NameTable)
    $customNs.AddNamespace('cp', 'http://schemas.openxmlformats.org/officeDocument/2006/custom-properties')
    $propertyUpdates = [ordered]@{
        'Customer' = $Customer
        'CustomerAbbr' = $CustomerAbbr
        'Location' = $Location
        'Subsidiary' = $Subsidiary
        'Environment' = $Environment
        'DocumentReference' = $DocumentReference
        'LNV.Version' = $Version
        'LNV.ConfigSnapDate' = $ConfigSnapDate
        'LNV.ReferenceID' = $ReferenceId
        'ClassificationContentMarkingHeaderText' = $Classification
        'SupportRegion' = $SupportRegion
    }
    if ($null -ne $SupportRegionModel) {
        foreach ($propertyName in @(
            'SupportRegionLabel',
            'SupportRegionDisplayName',
            'SupportLanguage',
            'SupportLanguages',
            'SupportWorkingHours',
            'SupportCountryCode',
            'SupportTierId',
            'SupportTier',
            'SupportPhoneNumbers',
            'SupportPhoneNumbersInline',
            'SupportServiceRequestUrl',
            'SupportPortalUrl',
            'SupportPhoneListUrl',
            'SupportPlanUrl',
            'SupportGuidance',
            'SupportProcessText'
        )) {
            $propertyUpdates[$propertyName] = [string](Get-SupportMapValue -Map $SupportRegionModel -Key $propertyName -Default '')
        }
    }

    foreach ($propertyName in @($propertyUpdates.Keys)) {
        $propertyValue = [string]$propertyUpdates[$propertyName]
        if ([string]::IsNullOrWhiteSpace($propertyValue)) { continue }
        $propertyNode = $customXml.SelectSingleNode("/cp:Properties/cp:property[@name='$propertyName']", $customNs)
        if ($null -eq $propertyNode) { continue }
        $valueNode = $null
        foreach ($child in @($propertyNode.ChildNodes)) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                $valueNode = $child
                break
            }
        }
        if ($null -eq $valueNode) { continue }
        Set-XmlNodeInnerText -Node $valueNode -Value $propertyValue
    }

    $customEntry.Delete()
    $updatedCustomEntry = $Archive.CreateEntry('docProps/custom.xml')
    Set-ZipEntryText -Entry $updatedCustomEntry -Text $customXml.OuterXml
}

function Set-DocxUpdateFieldsOnOpen {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $settingsEntry = $Archive.GetEntry('word/settings.xml')
    if ($null -eq $settingsEntry) {
        return [ordered]@{
            applied = $false
            reason = 'word/settings.xml not found'
        }
    }

    $settingsReader = [System.IO.StreamReader]::new($settingsEntry.Open())
    try {
        $settingsXmlText = $settingsReader.ReadToEnd()
    }
    finally {
        $settingsReader.Dispose()
    }

    [xml]$settingsXml = $settingsXmlText
    $settingsNode = $settingsXml.SelectSingleNode("/*[local-name()='settings']")
    if ($null -eq $settingsNode) {
        return [ordered]@{
            applied = $false
            reason = 'settings root not found'
        }
    }

    $wordNamespace = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    $updateFieldsNode = $settingsXml.SelectSingleNode("/*[local-name()='settings']/*[local-name()='updateFields']")
    if (-not $Enabled) {
        if ($null -ne $updateFieldsNode) {
            [void]$settingsNode.RemoveChild($updateFieldsNode)
            $settingsEntry.Delete()
            $updatedSettingsEntry = $Archive.CreateEntry('word/settings.xml')
            Set-ZipEntryText -Entry $updatedSettingsEntry -Text $settingsXml.OuterXml

            return [ordered]@{
                applied = $true
                enabled = $false
                reason = 'word/settings.xml updated with w:updateFields removed'
            }
        }

        return [ordered]@{
            applied = $false
            enabled = $false
            reason = 'word/settings.xml has no w:updateFields setting'
        }
    }

    if ($null -eq $updateFieldsNode) {
        $updateFieldsNode = $settingsXml.CreateElement('w', 'updateFields', $wordNamespace)
        [void]$settingsNode.AppendChild($updateFieldsNode)
    }

    $valAttr = $updateFieldsNode.Attributes.GetNamedItem('val', $wordNamespace)
    if ($null -eq $valAttr) {
        $valAttr = $settingsXml.CreateAttribute('w', 'val', $wordNamespace)
        [void]$updateFieldsNode.Attributes.Append($valAttr)
    }
    $valAttr.Value = 'true'

    $settingsEntry.Delete()
    $updatedSettingsEntry = $Archive.CreateEntry('word/settings.xml')
    Set-ZipEntryText -Entry $updatedSettingsEntry -Text $settingsXml.OuterXml

    return [ordered]@{
        applied = $true
        enabled = $true
        reason = 'word/settings.xml updated with w:updateFields=true'
    }
}

function Get-DocxFieldRefreshState {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $result = [ordered]@{
        path = $resolvedPath
        exists = $false
        lengthBytes = 0
        lastWriteUtc = ''
        attributes = ''
        updateFieldsOnOpenEnabled = $false
        updateFieldsOnOpenRaw = ''
        attachedTemplateTarget = ''
        attachedTemplateTargetMode = ''
        readError = ''
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        $result.readError = "DOCX not found: $resolvedPath"
        return $result
    }

    $item = Get-Item -LiteralPath $resolvedPath
    $result.exists = $true
    $result.lengthBytes = [int64]$item.Length
    $result.lastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
    $result.attributes = [string]$item.Attributes

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedPath)

        $settingsEntry = $archive.GetEntry('word/settings.xml')
        if ($null -ne $settingsEntry) {
            $settingsReader = [System.IO.StreamReader]::new($settingsEntry.Open())
            try {
                $settingsXmlText = $settingsReader.ReadToEnd()
            }
            finally {
                $settingsReader.Dispose()
            }

            [xml]$settingsXml = $settingsXmlText
            $updateFieldsNode = $settingsXml.SelectSingleNode("/*[local-name()='settings']/*[local-name()='updateFields']")
            if ($null -ne $updateFieldsNode) {
                $result.updateFieldsOnOpenRaw = $updateFieldsNode.OuterXml
                $wordNamespace = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
                $valAttr = $updateFieldsNode.Attributes.GetNamedItem('val', $wordNamespace)
                $val = if ($null -ne $valAttr) { [string]$valAttr.Value } else { 'true' }
                $result.updateFieldsOnOpenEnabled = ($val -in @('true', '1', 'on'))
            }
        }

        $settingsRelsEntry = $archive.GetEntry('word/_rels/settings.xml.rels')
        if ($null -ne $settingsRelsEntry) {
            $relsReader = [System.IO.StreamReader]::new($settingsRelsEntry.Open())
            try {
                $settingsRelsXmlText = $relsReader.ReadToEnd()
            }
            finally {
                $relsReader.Dispose()
            }

            [xml]$settingsRelsXml = $settingsRelsXmlText
            $attachedTemplateNode = $settingsRelsXml.SelectSingleNode("/*[local-name()='Relationships']/*[local-name()='Relationship' and contains(@Type, '/attachedTemplate')]")
            if ($null -ne $attachedTemplateNode) {
                $result.attachedTemplateTarget = [string]$attachedTemplateNode.Target
                $result.attachedTemplateTargetMode = [string]$attachedTemplateNode.TargetMode
            }
        }
    }
    catch {
        $result.readError = [string]$_.Exception.Message
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }

    return $result
}

function Try-RefreshDocxTableOfContents {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $beforeState = Get-DocxFieldRefreshState -Path $OutputPath
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        return [ordered]@{
            status = 'skipped'
            method = 'none'
            message = "Output DOCX not found: $OutputPath"
            diagnostics = [ordered]@{
                before = $beforeState
                after = $beforeState
                word = [ordered]@{}
            }
        }
    }

    if (-not $IsWindows) {
        return [ordered]@{
            status = 'deferred'
            method = 'none'
            message = 'Word automation is unavailable on non-Windows platforms.'
            diagnostics = [ordered]@{
                before = $beforeState
                after = $beforeState
                word = [ordered]@{}
            }
        }
    }

    $word = $null
    $document = $null
    $wordDiagnostics = [ordered]@{}
    try {
        $word = New-Object -ComObject Word.Application -ErrorAction Stop
        $word.Visible = $false
        $word.ScreenUpdating = $false
        $word.DisplayAlerts = 0

        $document = $word.Documents.Open($OutputPath)
        $wordDiagnostics.documentFullName = [string]$document.FullName
        $wordDiagnostics.documentPath = [string]$document.Path
        $wordDiagnostics.readOnly = [bool]$document.ReadOnly
        $wordDiagnostics.savedBeforeUpdate = [bool]$document.Saved
        try {
            $wordDiagnostics.attachedTemplate = [string]$document.AttachedTemplate.FullName
        }
        catch {
            $wordDiagnostics.attachedTemplate = ''
            $wordDiagnostics.attachedTemplateError = [string]$_.Exception.Message
        }

        [void]$document.Fields.Update()
        $document.Repaginate()

        $tocCount = [int]$document.TablesOfContents.Count
        for ($tocIndex = 1; $tocIndex -le $tocCount; $tocIndex++) {
            $toc = $null
            try {
                $toc = $document.TablesOfContents.Item($tocIndex)
                [void]$toc.Update()
                [void]$toc.UpdatePageNumbers()
            }
            finally {
                if ($null -ne $toc) {
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($toc)
                }
            }
        }

        $document.Repaginate()
        $document.Save()
        $wordDiagnostics.savedAfterExplicitSave = [bool]$document.Saved
        $saveChanges = -1
        $document.Close([ref]$saveChanges)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($document)
        $document = $null
        $afterState = Get-DocxFieldRefreshState -Path $OutputPath

        return [ordered]@{
            status = 'updated'
            method = 'word-com'
            message = "Updated $tocCount table(s) of contents via Word automation."
            diagnostics = [ordered]@{
                before = $beforeState
                after = $afterState
                word = $wordDiagnostics
            }
        }
    }
    catch {
        $afterState = Get-DocxFieldRefreshState -Path $OutputPath
        return [ordered]@{
            status = 'deferred'
            method = 'none'
            message = [string]$_.Exception.Message
            diagnostics = [ordered]@{
                before = $beforeState
                after = $afterState
                word = $wordDiagnostics
            }
        }
    }
    finally {
        if ($null -ne $document) {
            try {
                $document.Close()
            }
            catch {
            }
            finally {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($document)
            }
        }

        if ($null -ne $word) {
            try {
                $word.Quit()
            }
            catch {
            }
            finally {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word)
            }
        }
    }
}

function Get-WordStyleId {
    param(
        [Parameter(Mandatory = $false)][string]$StylesXmlText,
        [Parameter(Mandatory = $true)][string]$StyleName,
        [Parameter(Mandatory = $true)][string]$StyleType
    )

    if ([string]::IsNullOrWhiteSpace($StylesXmlText)) { return '' }
    try {
        $doc = [xml]$StylesXmlText
        $nsMgr = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
        $nsMgr.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $styleNode = $doc.SelectSingleNode("//w:style[@w:type='$StyleType'][w:name[@w:val='$StyleName']]", $nsMgr)
        if ($null -eq $styleNode) { return '' }

        $idAttr = $styleNode.Attributes.GetNamedItem('styleId', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        if ($null -eq $idAttr) { return '' }
        return [string]$idAttr.Value
    }
    catch {
        return ''
    }
}

function Get-WordTableStyleId {
    param(
        [Parameter(Mandatory = $false)][string]$StylesXmlText,
        [Parameter(Mandatory = $true)][string]$StyleName
    )

    return Get-WordStyleId -StylesXmlText $StylesXmlText -StyleName $StyleName -StyleType 'table'
}

function Get-WordParagraphStyleId {
    param(
        [Parameter(Mandatory = $false)][string]$StylesXmlText,
        [Parameter(Mandatory = $true)][string]$StyleName
    )

    return Get-WordStyleId -StylesXmlText $StylesXmlText -StyleName $StyleName -StyleType 'paragraph'
}

function ConvertTo-WordXmlEscapedText {
    param([Parameter(Mandatory = $false)][string]$Text)
    return [System.Security.SecurityElement]::Escape([string]$Text)
}

function Get-WordTableCellText {
    param(
        [Parameter(Mandatory = $false)]$Row,
        [Parameter(Mandatory = $true)][string]$ColumnName
    )

    if ($null -eq $Row) { return '' }
    $property = $Row.PSObject.Properties[$ColumnName]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-WordTableTextSegments {
    param([Parameter(Mandatory = $false)][string]$Text)

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        foreach ($segment in @(([string]$line) -split '\s+')) {
            if (-not [string]::IsNullOrWhiteSpace($segment)) {
                $segments.Add([string]$segment) | Out-Null
            }
        }
    }
    if ($segments.Count -eq 0) { $segments.Add('') | Out-Null }
    return @($segments)
}

function Get-PercentileInteger {
    param(
        [Parameter(Mandatory = $false)][int[]]$Values,
        [Parameter(Mandatory = $false)][double]$Percentile = 0.9
    )

    $ordered = @($Values | Sort-Object)
    if (@($ordered).Count -eq 0) { return 1 }
    $index = [int][Math]::Ceiling((@($ordered).Count * $Percentile)) - 1
    $index = [Math]::Max(0, [Math]::Min($index, @($ordered).Count - 1))
    return [int]$ordered[$index]
}

function Test-WordTableWideTextColumn {
    param([Parameter(Mandatory = $true)][string]$ColumnName)

    return ([string]$ColumnName -match '(?i)(^|[^a-z])(name|description|desc|notes?|members?|schedule|iqn|subject|issuer|thumbprint|fingerprint|serial|baseobject|object|ref|id|wwn|dn|certificate|policy|role|feature|entitlement)([^a-z]|$)')
}

function Test-WordTableNoWrapColumn {
    param(
        [Parameter(Mandatory = $true)][string]$ColumnName,
        [Parameter(Mandatory = $true)][int]$MaxTokenLength,
        [Parameter(Mandatory = $true)][int]$PercentileLength
    )

    if (Test-WordTableWideTextColumn -ColumnName $ColumnName) { return $false }
    if ($MaxTokenLength -gt 24 -or $PercentileLength -gt 32) { return $false }

    return ([string]$ColumnName -match '(?i)^(controller|slot|port|lun|status|state|address|mask|gateway|type|transport|activetransport|protocol|mode|linkstatus|enabled|scope|acquisition|channel|tcpport|firmware|version|raw|usable|used|free|size|media)$')
}

function Get-WordTableNoWrapLookup {
    param(
        [Parameter(Mandatory = $true)][string[]]$DisplayColumns,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    $lookup = @{}
    foreach ($columnName in @($DisplayColumns)) {
        $lineLengths = [System.Collections.Generic.List[int]]::new()
        $maxTokenLength = [Math]::Max(1, ([string]$columnName).Length)
        $lineLengths.Add([Math]::Max(1, ([string]$columnName).Length)) | Out-Null

        foreach ($row in @($Rows)) {
            $cellValue = Get-WordTableCellText -Row $row -ColumnName $columnName
            foreach ($line in @(([string]$cellValue) -split "`r?`n")) {
                $lineLengths.Add([Math]::Max(1, ([string]$line).Length)) | Out-Null
            }
            foreach ($segment in @(Get-WordTableTextSegments -Text $cellValue)) {
                $maxTokenLength = [Math]::Max($maxTokenLength, ([string]$segment).Length)
            }
        }

        $p90Length = Get-PercentileInteger -Values @($lineLengths) -Percentile 0.9
        $lookup[[string]$columnName] = [bool](Test-WordTableNoWrapColumn -ColumnName $columnName -MaxTokenLength $maxTokenLength -PercentileLength $p90Length)
    }

    return $lookup
}

function Convert-TableModelToWordTableXml {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$TableModel,
        [Parameter(Mandatory = $false)][string]$TableStyleId,
        [Parameter(Mandatory = $false)][string]$ParagraphStyleId
    )

    $displayColumns = @($TableModel.displayColumns | ForEach-Object { [string]$_ })
    $rows = @($TableModel.rows)
    if (@($displayColumns).Count -eq 0 -or @($rows).Count -eq 0) { return '' }

    $tableWidthPct = 4783
    $noWrapByColumn = Get-WordTableNoWrapLookup -DisplayColumns $displayColumns -Rows $rows
    $columnWeights = [System.Collections.Generic.List[int]]::new()
    foreach ($columnName in @($displayColumns)) {
        $maxLength = [Math]::Max(1, ([string]$columnName).Length)
        foreach ($row in @($rows)) {
            $cellValue = Get-WordTableCellText -Row $row -ColumnName $columnName
            $cellMaxSegmentLength = 1
            foreach ($segment in @($cellValue -split "`r?`n")) {
                $cellMaxSegmentLength = [Math]::Max($cellMaxSegmentLength, ([string]$segment).Length)
            }
            $maxLength = [Math]::Max($maxLength, $cellMaxSegmentLength)
        }
        [void]$columnWeights.Add([Math]::Max(1, $maxLength))
    }

    $weightTotal = ($columnWeights | Measure-Object -Sum).Sum
    if ($null -eq $weightTotal -or [int]$weightTotal -le 0) { $weightTotal = @($displayColumns).Count }
    $columnWidthPctValues = [System.Collections.Generic.List[int]]::new()
    $pctAssigned = 0
    for ($columnIndex = 0; $columnIndex -lt @($displayColumns).Count; $columnIndex++) {
        $weight = [int]$columnWeights[$columnIndex]
        $columnPct = if ($columnIndex -eq (@($displayColumns).Count - 1)) {
            $tableWidthPct - $pctAssigned
        }
        else {
            [Math]::Max(1, [int][Math]::Round(($tableWidthPct * $weight) / [double]$weightTotal))
        }
        $pctAssigned += $columnPct
        [void]$columnWidthPctValues.Add($columnPct)
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<w:tbl>')
    [void]$sb.Append('<w:tblPr>')
    if (-not [string]::IsNullOrWhiteSpace($TableStyleId)) {
        [void]$sb.Append("<w:tblStyle w:val=`"$(ConvertTo-WordXmlEscapedText -Text $TableStyleId)`"/>")
    }
    [void]$sb.Append("<w:tblW w:w=`"$tableWidthPct`" w:type=`"pct`"/>")
    [void]$sb.Append('<w:tblLook w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="1" w:val="0420"/>')
    [void]$sb.Append('</w:tblPr>')
    [void]$sb.Append('<w:tblGrid>')
    foreach ($columnPct in @($columnWidthPctValues)) {
        [void]$sb.Append("<w:gridCol w:w=`"$columnPct`"/>")
    }
    [void]$sb.Append('</w:tblGrid>')

    [void]$sb.Append('<w:tr>')
    for ($columnIndex = 0; $columnIndex -lt @($displayColumns).Count; $columnIndex++) {
        $columnName = [string]$displayColumns[$columnIndex]
        $columnPct = [int]$columnWidthPctValues[$columnIndex]
        $noWrapXml = if ([bool]$noWrapByColumn[$columnName]) { '<w:noWrap/>' } else { '' }
        [void]$sb.Append("<w:tc><w:tcPr><w:tcW w:w=`"$columnPct`" w:type=`"pct`"/>$noWrapXml</w:tcPr><w:p><w:pPr>")
        if (-not [string]::IsNullOrWhiteSpace($ParagraphStyleId)) {
            [void]$sb.Append("<w:pStyle w:val=`"$(ConvertTo-WordXmlEscapedText -Text $ParagraphStyleId)`"/>")
        }
        [void]$sb.Append('</w:pPr><w:r><w:t>')
        [void]$sb.Append((ConvertTo-WordXmlEscapedText -Text $columnName))
        [void]$sb.Append('</w:t></w:r></w:p></w:tc>')
    }
    [void]$sb.Append('</w:tr>')

    foreach ($row in $rows) {
        [void]$sb.Append('<w:tr>')
        for ($columnIndex = 0; $columnIndex -lt @($displayColumns).Count; $columnIndex++) {
            $columnName = [string]$displayColumns[$columnIndex]
            $columnPct = [int]$columnWidthPctValues[$columnIndex]
            $noWrapXml = if ([bool]$noWrapByColumn[$columnName]) { '<w:noWrap/>' } else { '' }
            $cellValue = Get-WordTableCellText -Row $row -ColumnName $columnName
            [void]$sb.Append("<w:tc><w:tcPr><w:tcW w:w=`"$columnPct`" w:type=`"pct`"/>$noWrapXml</w:tcPr><w:p><w:pPr>")
            if (-not [string]::IsNullOrWhiteSpace($ParagraphStyleId)) {
                [void]$sb.Append("<w:pStyle w:val=`"$(ConvertTo-WordXmlEscapedText -Text $ParagraphStyleId)`"/>")
            }
            [void]$sb.Append('</w:pPr><w:r><w:t xml:space="preserve">')
            [void]$sb.Append((ConvertTo-WordXmlEscapedText -Text $cellValue))
            [void]$sb.Append('</w:t></w:r></w:p></w:tc>')
        }
        [void]$sb.Append('</w:tr>')
    }

    [void]$sb.Append('</w:tbl>')
    return $sb.ToString()
}

function Add-DocxPngImagePart {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$ImageBase64,
        [Parameter(Mandatory = $false)][string]$ImageExtension = 'png',
        [Parameter(Mandatory = $false)][string]$ContentType = 'image/png'
    )

    $imageBytes = [Convert]::FromBase64String($ImageBase64)
    $safeExtension = [regex]::Replace($ImageExtension.ToLowerInvariant(), '[^a-z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($safeExtension)) { $safeExtension = 'png' }
    $mediaIndex = @($Archive.Entries | Where-Object { $_.FullName -like "word/media/assembler-diagram-*.$safeExtension" }).Count + 1
    $mediaPath = "word/media/assembler-diagram-$mediaIndex.$safeExtension"
    while ($null -ne $Archive.GetEntry($mediaPath)) {
        $mediaIndex++
        $mediaPath = "word/media/assembler-diagram-$mediaIndex.$safeExtension"
    }

    $mediaEntry = $Archive.CreateEntry($mediaPath)
    $mediaStream = $mediaEntry.Open()
    try {
        $mediaStream.Write($imageBytes, 0, $imageBytes.Length)
    }
    finally {
        $mediaStream.Dispose()
    }

    $contentTypesEntry = $Archive.GetEntry('[Content_Types].xml')
    if ($null -ne $contentTypesEntry) {
        $reader = [System.IO.StreamReader]::new($contentTypesEntry.Open())
        try {
            $contentTypesXmlText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        [xml]$contentTypesXml = $contentTypesXmlText
        $contentTypesNamespace = 'http://schemas.openxmlformats.org/package/2006/content-types'
        $imageDefault = @($contentTypesXml.SelectNodes("/*[local-name()='Types']/*[local-name()='Default'][@Extension='$safeExtension']")) | Select-Object -First 1
        if ($null -eq $imageDefault) {
            $defaultNode = $contentTypesXml.CreateElement('Default', $contentTypesNamespace)
            $extensionAttribute = $contentTypesXml.CreateAttribute('Extension')
            $extensionAttribute.Value = $safeExtension
            [void]$defaultNode.Attributes.Append($extensionAttribute)
            $contentTypeAttribute = $contentTypesXml.CreateAttribute('ContentType')
            $contentTypeAttribute.Value = $ContentType
            [void]$defaultNode.Attributes.Append($contentTypeAttribute)
            [void]$contentTypesXml.DocumentElement.AppendChild($defaultNode)

            $contentTypesEntry.Delete()
            $updatedContentTypesEntry = $Archive.CreateEntry('[Content_Types].xml')
            Set-ZipEntryText -Entry $updatedContentTypesEntry -Text $contentTypesXml.OuterXml
        }
    }

    $relsPath = 'word/_rels/document.xml.rels'
    $relsEntry = $Archive.GetEntry($relsPath)
    $relsNamespace = 'http://schemas.openxmlformats.org/package/2006/relationships'
    if ($null -eq $relsEntry) {
        $relsEntry = $Archive.CreateEntry($relsPath)
        Set-ZipEntryText -Entry $relsEntry -Text "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$relsNamespace`"></Relationships>"
        $relsEntry = $Archive.GetEntry($relsPath)
    }

    $relsReader = [System.IO.StreamReader]::new($relsEntry.Open())
    try {
        $relsXmlText = $relsReader.ReadToEnd()
    }
    finally {
        $relsReader.Dispose()
    }

    [xml]$relsXml = $relsXmlText
    $maxRelationshipId = 0
    foreach ($relationshipNode in @($relsXml.SelectNodes("/*[local-name()='Relationships']/*[local-name()='Relationship']"))) {
        $idValue = [string]$relationshipNode.Id
        if ($idValue -match '^rId(\d+)$') {
            $maxRelationshipId = [Math]::Max($maxRelationshipId, [int]$Matches[1])
        }
    }

    $relationshipId = 'rId' + ($maxRelationshipId + 1)
    $relationship = $relsXml.CreateElement('Relationship', $relsNamespace)
    foreach ($attribute in @(
        @{ name = 'Id'; value = $relationshipId },
        @{ name = 'Type'; value = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image' },
        @{ name = 'Target'; value = ('media/' + [System.IO.Path]::GetFileName($mediaPath)) }
    )) {
        $attr = $relsXml.CreateAttribute([string]$attribute.name)
        $attr.Value = [string]$attribute.value
        [void]$relationship.Attributes.Append($attr)
    }
    [void]$relsXml.DocumentElement.AppendChild($relationship)

    $relsEntry.Delete()
    $updatedRelsEntry = $Archive.CreateEntry($relsPath)
    Set-ZipEntryText -Entry $updatedRelsEntry -Text $relsXml.OuterXml

    return $relationshipId
}

function Get-PngDimensionsFromBase64 {
    param([Parameter(Mandatory = $true)][string]$ImageBase64)

    try {
        $bytes = [Convert]::FromBase64String($ImageBase64)
        if ($bytes.Length -lt 24) { return $null }
        $pngSignature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
        for ($index = 0; $index -lt $pngSignature.Length; $index++) {
            if ($bytes[$index] -ne $pngSignature[$index]) { return $null }
        }

        $width = (($bytes[16] -shl 24) -bor ($bytes[17] -shl 16) -bor ($bytes[18] -shl 8) -bor $bytes[19])
        $height = (($bytes[20] -shl 24) -bor ($bytes[21] -shl 16) -bor ($bytes[22] -shl 8) -bor $bytes[23])
        if ($width -le 0 -or $height -le 0) { return $null }
        return [pscustomobject]@{ Width = [int]$width; Height = [int]$height }
    }
    catch {
        return $null
    }
}

function New-DocxImageSizeFromPngBase64 {
    param(
        [Parameter(Mandatory = $true)][string]$ImageBase64,
        [Parameter(Mandatory = $false)][int64]$MaxWidthEmu = 5486400,
        [Parameter(Mandatory = $false)][int64]$MaxHeightEmu = 7315200
    )

    $dimensions = Get-PngDimensionsFromBase64 -ImageBase64 $ImageBase64
    if ($null -eq $dimensions) {
        return [pscustomobject]@{ WidthEmu = $MaxWidthEmu; HeightEmu = 3200400 }
    }

    $widthEmu = [double]$MaxWidthEmu
    $heightEmu = $widthEmu * ([double]$dimensions.Height / [double]$dimensions.Width)
    if ($heightEmu -gt [double]$MaxHeightEmu) {
        $heightEmu = [double]$MaxHeightEmu
        $widthEmu = $heightEmu * ([double]$dimensions.Width / [double]$dimensions.Height)
    }

    return [pscustomobject]@{
        WidthEmu = [int64][Math]::Round($widthEmu)
        HeightEmu = [int64][Math]::Round($heightEmu)
    }
}

function New-DocxImageSizeFromPixelDimensions {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $false)][int64]$MaxWidthEmu = 5486400,
        [Parameter(Mandatory = $false)][int64]$MaxHeightEmu = 7315200
    )

    if ($Width -le 0 -or $Height -le 0) {
        return [pscustomobject]@{ WidthEmu = $MaxWidthEmu; HeightEmu = 3200400 }
    }

    $widthEmu = [double]$MaxWidthEmu
    $heightEmu = $widthEmu * ([double]$Height / [double]$Width)
    if ($heightEmu -gt [double]$MaxHeightEmu) {
        $heightEmu = [double]$MaxHeightEmu
        $widthEmu = $heightEmu * ([double]$Width / [double]$Height)
    }

    return [pscustomobject]@{
        WidthEmu = [int64][Math]::Round($widthEmu)
        HeightEmu = [int64][Math]::Round($heightEmu)
    }
}

function Convert-ImageModelToWordDrawingXml {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ImageModel,
        [Parameter(Mandatory = $true)][string]$RelationshipId,
        [Parameter(Mandatory = $true)][int]$ImageIndex
    )

    $widthEmu = if (Test-MapHasKey -Map $ImageModel -Key 'widthEmu') { [int64]$ImageModel.widthEmu } else { 5486400 }
    $heightEmu = if (Test-MapHasKey -Map $ImageModel -Key 'heightEmu') { [int64]$ImageModel.heightEmu } else { 3200400 }
    $name = if (Test-MapHasKey -Map $ImageModel -Key 'name') { [string]$ImageModel.name } else { "Assembler Diagram $ImageIndex" }
    $escapedName = ConvertTo-WordXmlEscapedText -Text $name

    return @"
<w:p>
  <w:r>
    <w:drawing>
      <wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" distT="0" distB="0" distL="0" distR="0">
        <wp:extent cx="$widthEmu" cy="$heightEmu"/>
        <wp:docPr id="$ImageIndex" name="$escapedName"/>
        <wp:cNvGraphicFramePr>
          <a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/>
        </wp:cNvGraphicFramePr>
        <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
            <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
              <pic:nvPicPr>
                <pic:cNvPr id="$ImageIndex" name="$escapedName"/>
                <pic:cNvPicPr/>
              </pic:nvPicPr>
              <pic:blipFill>
                <a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="$RelationshipId"/>
                <a:stretch><a:fillRect/></a:stretch>
              </pic:blipFill>
              <pic:spPr>
                <a:xfrm><a:off x="0" y="0"/><a:ext cx="$widthEmu" cy="$heightEmu"/></a:xfrm>
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
              </pic:spPr>
            </pic:pic>
          </a:graphicData>
        </a:graphic>
      </wp:inline>
    </w:drawing>
  </w:r>
</w:p>
"@.Trim()
}

function Replace-DocxParagraphTokenWithBlockXml {
    param(
        [Parameter(Mandatory = $true)][string]$XmlText,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$BlockXml
    )

    if ([string]::IsNullOrWhiteSpace($BlockXml)) { return $XmlText }

    [xml]$xmlDoc = $XmlText
    $escapedTag = [regex]::Escape([string]$Tag)
    $tokenPattern = "<<SDT:\s*$escapedTag\s*>>"
    $paragraphNodes = @(
        $xmlDoc.SelectNodes("//*[local-name()='p']") |
            Where-Object { [string]$_.InnerText -match $tokenPattern }
    )

    if (@($paragraphNodes).Count -eq 0) {
        return $XmlText
    }

    foreach ($paragraphNode in @($paragraphNodes)) {
        $parentNode = $paragraphNode.ParentNode
        if ($null -eq $parentNode) { continue }

        $importedNodes = @(Convert-WordXmlFragmentToNodes -OwnerDocument $xmlDoc -XmlFragment $BlockXml)
        if (@($importedNodes).Count -eq 0) { continue }

        foreach ($importedNode in @($importedNodes)) {
            [void]$parentNode.InsertBefore($importedNode, $paragraphNode)
        }
        [void]$parentNode.RemoveChild($paragraphNode)

        if (
            $parentNode.LocalName -eq 'tc' -and
            ($null -eq $parentNode.LastChild -or $parentNode.LastChild.LocalName -ne 'p')
        ) {
            $emptyParagraph = (Convert-TextToWordParagraphNodes -XmlDocument $xmlDoc -Text '')[0]
            [void]$parentNode.AppendChild($emptyParagraph)
        }
    }

    return $xmlDoc.OuterXml
}

function Replace-LiteralSdtTokenText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Replacement
    )

    $escapedTag = [regex]::Escape([string]$Tag)
    $pattern = "<<SDT:\s*$escapedTag\s*>>"
    return [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement })
}

function Replace-LiteralSdtTokenXmlText {
    param(
        [Parameter(Mandatory = $true)][string]$XmlText,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Replacement
    )

    $updated = Replace-LiteralSdtTokenText -Text $XmlText -Tag $Tag -Replacement $Replacement
    $escapedTag = [regex]::Escape([string]$Tag)
    $escapedPattern = "&lt;&lt;SDT:\s*$escapedTag\s*&gt;&gt;"
    return [regex]::Replace($updated, $escapedPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement })
}

function Measure-LiteralSdtTokenXmlText {
    param(
        [Parameter(Mandatory = $true)][string]$XmlText,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $escapedTag = [regex]::Escape([string]$Tag)
    $rawPattern = "<<SDT:\s*$escapedTag\s*>>"
    $escapedPattern = "&lt;&lt;SDT:\s*$escapedTag\s*&gt;&gt;"
    $rawMatches = [regex]::Matches($XmlText, $rawPattern).Count
    $escapedMatches = [regex]::Matches($XmlText, $escapedPattern).Count
    return ([int]$rawMatches + [int]$escapedMatches)
}

function Remove-UnresolvedSdtTokensFromText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $updated = [regex]::Replace($Text, '<<SDT:\s*[^>]+>>', '')
    return [regex]::Replace($updated, '&lt;&lt;SDT:\s*[^&]+&gt;&gt;', '')
}

function Test-DocxMatchModeIncludes {
    param(
        [Parameter(Mandatory = $true)][string]$DocxMatchMode,
        [Parameter(Mandatory = $true)][ValidateSet('content-control-tag','literal-token')][string]$Mode
    )

    if ($DocxMatchMode -eq 'both') { return $true }
    return ($DocxMatchMode -eq $Mode)
}

function New-WordXmlNamespaceManager {
    param([Parameter(Mandatory = $true)][xml]$XmlDocument)

    $nsMgr = [System.Xml.XmlNamespaceManager]::new($XmlDocument.NameTable)
    $nsMgr.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    return $nsMgr
}
function Convert-TextToWordParagraphNodes {
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $false)][string]$Text
    )

    $namespaceUri = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    $paragraphNodes = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
    $lines = @(([string]$Text) -split "`r?`n", 0, [System.StringSplitOptions]::None)
    if ($lines.Count -eq 0) { $lines = @('') }

    foreach ($line in $lines) {
        $paragraph = $XmlDocument.CreateElement('w', 'p', $namespaceUri)
        $run = $XmlDocument.CreateElement('w', 'r', $namespaceUri)
        $textNode = $XmlDocument.CreateElement('w', 't', $namespaceUri)
        $spaceAttr = $XmlDocument.CreateAttribute('xml', 'space', 'http://www.w3.org/XML/1998/namespace')
        $spaceAttr.Value = 'preserve'
        [void]$textNode.Attributes.Append($spaceAttr)
        $textNode.InnerText = [string]$line

        [void]$run.AppendChild($textNode)
        [void]$paragraph.AppendChild($run)
        [void]$paragraphNodes.Add($paragraph)
    }

    return @($paragraphNodes.ToArray())
}

function Convert-TextToWordRunNodes {
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $false)][string]$Text
    )

    $namespaceUri = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    $runNodes = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
    $lines = @(([string]$Text) -split "`r?`n", 0, [System.StringSplitOptions]::None)
    if ($lines.Count -eq 0) { $lines = @('') }

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lineIndex -gt 0) {
            $breakRun = $XmlDocument.CreateElement('w', 'r', $namespaceUri)
            $breakNode = $XmlDocument.CreateElement('w', 'br', $namespaceUri)
            [void]$breakRun.AppendChild($breakNode)
            [void]$runNodes.Add($breakRun)
        }

        $run = $XmlDocument.CreateElement('w', 'r', $namespaceUri)
        $textNode = $XmlDocument.CreateElement('w', 't', $namespaceUri)
        $spaceAttr = $XmlDocument.CreateAttribute('xml', 'space', 'http://www.w3.org/XML/1998/namespace')
        $spaceAttr.Value = 'preserve'
        [void]$textNode.Attributes.Append($spaceAttr)
        $textNode.InnerText = [string]$lines[$lineIndex]

        [void]$run.AppendChild($textNode)
        [void]$runNodes.Add($run)
    }

    return @($runNodes.ToArray())
}

function Get-FirstWordRunPropertiesNode {
    param(
        [Parameter(Mandatory = $false)][System.Xml.XmlNode[]]$RunNodes,
        [Parameter(Mandatory = $false)][System.Xml.XmlNode]$FallbackRunPropertiesNode
    )

    foreach ($runNode in @($RunNodes)) {
        if ($null -eq $runNode -or $runNode.LocalName -ne 'r') { continue }
        foreach ($childNode in @($runNode.ChildNodes)) {
            if ($childNode.NodeType -eq [System.Xml.XmlNodeType]::Element -and $childNode.LocalName -eq 'rPr') {
                return $childNode
            }
        }
    }

    return $FallbackRunPropertiesNode
}

function Add-WordRunPropertiesClone {
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$RunNode,
        [Parameter(Mandatory = $false)][System.Xml.XmlNode]$RunPropertiesNode
    )

    if ($null -eq $RunPropertiesNode) { return }
    $clonedRunProperties = $XmlDocument.ImportNode($RunPropertiesNode, $true)
    if ($null -eq $RunNode.FirstChild) {
        [void]$RunNode.AppendChild($clonedRunProperties)
    }
    else {
        [void]$RunNode.InsertBefore($clonedRunProperties, $RunNode.FirstChild)
    }
}

function Convert-TextToStyledWordRunNodes {
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $false)][string]$Text,
        [Parameter(Mandatory = $false)][System.Xml.XmlNode[]]$PrototypeRunNodes,
        [Parameter(Mandatory = $false)][System.Xml.XmlNode]$FallbackRunPropertiesNode
    )

    $namespaceUri = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    $runNodes = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
    $lines = @(([string]$Text) -split "`r?`n", 0, [System.StringSplitOptions]::None)
    if ($lines.Count -eq 0) { $lines = @('') }

    $runPropertiesNode = Get-FirstWordRunPropertiesNode -RunNodes $PrototypeRunNodes -FallbackRunPropertiesNode $FallbackRunPropertiesNode

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lineIndex -gt 0) {
            $breakRun = $XmlDocument.CreateElement('w', 'r', $namespaceUri)
            Add-WordRunPropertiesClone -XmlDocument $XmlDocument -RunNode $breakRun -RunPropertiesNode $runPropertiesNode
            $breakNode = $XmlDocument.CreateElement('w', 'br', $namespaceUri)
            [void]$breakRun.AppendChild($breakNode)
            [void]$runNodes.Add($breakRun)
        }

        $run = $XmlDocument.CreateElement('w', 'r', $namespaceUri)
        Add-WordRunPropertiesClone -XmlDocument $XmlDocument -RunNode $run -RunPropertiesNode $runPropertiesNode
        $textNode = $XmlDocument.CreateElement('w', 't', $namespaceUri)
        $spaceAttr = $XmlDocument.CreateAttribute('xml', 'space', 'http://www.w3.org/XML/1998/namespace')
        $spaceAttr.Value = 'preserve'
        [void]$textNode.Attributes.Append($spaceAttr)
        $textNode.InnerText = [string]$lines[$lineIndex]

        [void]$run.AppendChild($textNode)
        [void]$runNodes.Add($run)
    }

    return @($runNodes.ToArray())
}

function Get-WordSdtRunPropertiesNode {
    param([Parameter(Mandatory = $false)][System.Xml.XmlNode]$SdtNode)

    if ($null -eq $SdtNode) { return $null }
    return $SdtNode.SelectSingleNode("./*[local-name()='sdtPr']/*[local-name()='rPr']")
}

function Test-WordSdtContentContainsFieldCodes {
    param([Parameter(Mandatory = $false)][System.Xml.XmlNode]$SdtContentNode)

    if ($null -eq $SdtContentNode) { return $false }
    return ($null -ne $SdtContentNode.SelectSingleNode(".//*[local-name()='fldChar' or local-name()='instrText'] | ./*[local-name()='fldChar' or local-name()='instrText']"))
}

function Convert-TextToWordSdtContentNodes {
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $false)][System.Xml.XmlNode]$SdtNode,
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$SdtContentNode,
        [Parameter(Mandatory = $false)][string]$Text
    )

    $hasBlockChildren = @(
        $SdtContentNode.ChildNodes |
            Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq 'p' }
    ).Count -gt 0
    $isRunLevel = $SdtContentNode.ParentNode -and $SdtContentNode.ParentNode.LocalName -eq 'sdt' -and $SdtContentNode.ParentNode.ParentNode -and $SdtContentNode.ParentNode.ParentNode.LocalName -eq 'p'

    if ($hasBlockChildren -or (-not $isRunLevel)) {
        return @(Convert-TextToWordParagraphNodes -XmlDocument $XmlDocument -Text $Text)
    }

    $prototypeRuns = @(
        $SdtContentNode.ChildNodes |
            Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq 'r' }
    )
    $fallbackRunPropertiesNode = Get-WordSdtRunPropertiesNode -SdtNode $SdtNode

    return @(Convert-TextToStyledWordRunNodes -XmlDocument $XmlDocument -Text $Text -PrototypeRunNodes $prototypeRuns -FallbackRunPropertiesNode $fallbackRunPropertiesNode)
}

function Set-WordSdtContentNodes {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$SdtContentNode,
        [Parameter(Mandatory = $true)][System.Xml.XmlNode[]]$Nodes
    )

    while ($SdtContentNode.HasChildNodes) {
        [void]$SdtContentNode.RemoveChild($SdtContentNode.FirstChild)
    }

    foreach ($node in @($Nodes)) {
        if ($null -eq $node) { continue }
        [void]$SdtContentNode.AppendChild($node)
    }
}

function Convert-WordXmlFragmentToNodes {
    param(
        [Parameter(Mandatory = $true)][xml]$OwnerDocument,
        [Parameter(Mandatory = $true)][string]$XmlFragment
    )

    if ([string]::IsNullOrWhiteSpace($XmlFragment)) { return @() }

    $fragmentDoc = [xml]("<root xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'>$XmlFragment</root>")
    $importedNodes = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
    foreach ($child in @($fragmentDoc.DocumentElement.ChildNodes)) {
        [void]$importedNodes.Add($OwnerDocument.ImportNode($child, $true))
    }

    return @($importedNodes.ToArray())
}

function Get-DocxContentControlReplacementMap {
    param(
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
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$SupportRegionModel
    )

    $map = [ordered]@{}
    $propertyAliases = [ordered]@{
        Title = @('Title', 'DocTitle', 'DocumentTitle')
        Customer = @('Customer', 'DocCustomer')
        CustomerAbbr = @('CustomerAbbr', 'DocCustomerAbbr')
        Location = @('Location', 'DocLocation')
        Subsidiary = @('Subsidiary', 'DocSubsidiary')
        Environment = @('Environment', 'DocEnvironment')
        DocumentReference = @('DocumentReference', 'DocDocumentReference')
        Version = @('LNV.Version', 'DocVersion')
        ConfigSnapDate = @('LNV.ConfigSnapDate', 'DocConfigSnapDate')
        ReferenceId = @('LNV.ReferenceID', 'DocReferenceId')
        Classification = @('ClassificationContentMarkingHeaderText', 'Classification', 'DocClassification')
        SupportRegion = @('SupportRegion', 'DocSupportRegion')
        SupportRegionLabel = @('SupportRegionLabel', 'DocSupportRegionLabel')
        SupportRegionDisplayName = @('SupportRegionDisplayName', 'DocSupportRegionDisplayName')
        SupportLanguage = @('SupportLanguage', 'DocSupportLanguage')
        SupportLanguages = @('SupportLanguages', 'DocSupportLanguages')
        SupportWorkingHours = @('SupportWorkingHours', 'DocSupportWorkingHours')
        SupportCountryCode = @('SupportCountryCode', 'DocSupportCountryCode')
        SupportTierId = @('SupportTierId', 'DocSupportTierId')
        SupportTier = @('SupportTier', 'DocSupportTier')
        SupportPhoneNumbers = @('SupportPhoneNumbers', 'DocSupportPhoneNumbers')
        SupportPhoneNumbersInline = @('SupportPhoneNumbersInline', 'DocSupportPhoneNumbersInline')
        SupportServiceRequestUrl = @('SupportServiceRequestUrl', 'DocSupportServiceRequestUrl')
        SupportPortalUrl = @('SupportPortalUrl', 'DocSupportPortalUrl')
        SupportPhoneListUrl = @('SupportPhoneListUrl', 'DocSupportPhoneListUrl')
        SupportPlanUrl = @('SupportPlanUrl', 'DocSupportPlanUrl')
        SupportGuidance = @('SupportGuidance', 'DocSupportGuidance')
        SupportProcessText = @('SupportProcessText', 'DocSupportProcessText')
    }
    $propertyValues = [ordered]@{
        Title = $DocTitle
        Customer = $DocCustomer
        CustomerAbbr = $DocCustomerAbbr
        Location = $DocLocation
        Subsidiary = $DocSubsidiary
        Environment = $DocEnvironment
        DocumentReference = $DocDocumentReference
        Version = $DocVersion
        ConfigSnapDate = $DocConfigSnapDate
        ReferenceId = $DocReferenceId
        Classification = $DocClassification
        SupportRegion = $DocSupportRegion
        SupportTierId = $DocSupportTier
    }
    if ($null -ne $SupportRegionModel) {
        foreach ($propertyName in @(
            'SupportRegion',
            'SupportRegionLabel',
            'SupportRegionDisplayName',
            'SupportLanguage',
            'SupportLanguages',
            'SupportWorkingHours',
            'SupportCountryCode',
            'SupportTierId',
            'SupportTier',
            'SupportPhoneNumbers',
            'SupportPhoneNumbersInline',
            'SupportServiceRequestUrl',
            'SupportPortalUrl',
            'SupportPhoneListUrl',
            'SupportPlanUrl',
            'SupportGuidance',
            'SupportProcessText'
        )) {
            $propertyValues[$propertyName] = [string](Get-SupportMapValue -Map $SupportRegionModel -Key $propertyName -Default '')
        }
    }

    foreach ($propertyName in @($propertyValues.Keys)) {
        $value = [string]$propertyValues[$propertyName]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        foreach ($alias in @($propertyAliases[$propertyName])) {
            if ([string]::IsNullOrWhiteSpace([string]$alias)) { continue }
            $map[[string]$alias] = $value
        }
    }

    return $map
}

function Get-DocxDocPropertyFieldReplacementMap {
    param(
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
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$SupportRegionModel
    )

    $map = [ordered]@{}
    foreach ($entry in @(
        @{ name = 'Title'; value = $DocTitle },
        @{ name = 'Customer'; value = $DocCustomer },
        @{ name = 'CustomerAbbr'; value = $DocCustomerAbbr },
        @{ name = 'Location'; value = $DocLocation },
        @{ name = 'Subsidiary'; value = $DocSubsidiary },
        @{ name = 'Environment'; value = $DocEnvironment },
        @{ name = 'DocumentReference'; value = $DocDocumentReference },
        @{ name = 'LNV.Version'; value = $DocVersion },
        @{ name = 'LNV.ConfigSnapDate'; value = $DocConfigSnapDate },
        @{ name = 'LNV.ReferenceID'; value = $DocReferenceId },
        @{ name = 'ClassificationContentMarkingHeaderText'; value = $DocClassification },
        @{ name = 'SupportRegion'; value = $DocSupportRegion },
        @{ name = 'DocSupportRegion'; value = $DocSupportRegion },
        @{ name = 'SupportTierId'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportTierId' -Default $DocSupportTier) },
        @{ name = 'DocSupportTierId'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportTierId' -Default $DocSupportTier) },
        @{ name = 'SupportRegionLabel'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportRegionLabel' -Default '') },
        @{ name = 'DocSupportRegionLabel'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportRegionLabel' -Default '') },
        @{ name = 'SupportRegionDisplayName'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportRegionDisplayName' -Default '') },
        @{ name = 'DocSupportRegionDisplayName'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportRegionDisplayName' -Default '') },
        @{ name = 'SupportLanguage'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportLanguage' -Default '') },
        @{ name = 'DocSupportLanguage'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportLanguage' -Default '') },
        @{ name = 'SupportLanguages'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportLanguages' -Default '') },
        @{ name = 'DocSupportLanguages'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportLanguages' -Default '') },
        @{ name = 'SupportWorkingHours'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportWorkingHours' -Default '') },
        @{ name = 'DocSupportWorkingHours'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportWorkingHours' -Default '') },
        @{ name = 'SupportCountryCode'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportCountryCode' -Default '') },
        @{ name = 'DocSupportCountryCode'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportCountryCode' -Default '') },
        @{ name = 'SupportTier'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportTier' -Default '') },
        @{ name = 'DocSupportTier'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportTier' -Default '') },
        @{ name = 'SupportPhoneNumbers'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPhoneNumbers' -Default '') },
        @{ name = 'DocSupportPhoneNumbers'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPhoneNumbers' -Default '') },
        @{ name = 'SupportPhoneNumbersInline'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPhoneNumbersInline' -Default '') },
        @{ name = 'DocSupportPhoneNumbersInline'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPhoneNumbersInline' -Default '') },
        @{ name = 'SupportServiceRequestUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportServiceRequestUrl' -Default '') },
        @{ name = 'DocSupportServiceRequestUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportServiceRequestUrl' -Default '') },
        @{ name = 'SupportPortalUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPortalUrl' -Default '') },
        @{ name = 'DocSupportPortalUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPortalUrl' -Default '') },
        @{ name = 'SupportPhoneListUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPhoneListUrl' -Default '') },
        @{ name = 'DocSupportPhoneListUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPhoneListUrl' -Default '') },
        @{ name = 'SupportPlanUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPlanUrl' -Default '') },
        @{ name = 'DocSupportPlanUrl'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportPlanUrl' -Default '') },
        @{ name = 'SupportGuidance'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportGuidance' -Default '') },
        @{ name = 'DocSupportGuidance'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportGuidance' -Default '') },
        @{ name = 'SupportProcessText'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportProcessText' -Default '') },
        @{ name = 'DocSupportProcessText'; value = [string](Get-SupportMapValue -Map $SupportRegionModel -Key 'SupportProcessText' -Default '') }
    )) {
        $name = [string]$entry.name
        $value = [string]$entry.value
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($value)) { continue }
        $map[$name] = $value
    }

    return $map
}

function Get-DocPropertyFieldNameFromInstructionText {
    param([Parameter(Mandatory = $false)][string]$InstructionText)

    $text = [string]$InstructionText
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }

    $match = [regex]::Match($text, '(?i)\bDOCPROPERTY\b\s+(?:"([^"]+)"|([^\s\\]+))')
    if (-not $match.Success) { return '' }

    $quoted = [string]$match.Groups[1].Value
    if (-not [string]::IsNullOrWhiteSpace($quoted)) {
        return $quoted.Trim()
    }

    return ([string]$match.Groups[2].Value).Trim()
}

function Get-WordNodeFieldCharType {
    param([Parameter(Mandatory = $false)][System.Xml.XmlNode]$Node)

    if ($null -eq $Node) { return '' }
    $attr = $Node.SelectSingleNode(".//*[local-name()='fldChar']/@*[local-name()='fldCharType'] | ./*[local-name()='fldChar']/@*[local-name()='fldCharType']")
    if ($null -eq $attr) { return '' }
    return [string]$attr.Value
}

function Get-WordNodeInstructionText {
    param([Parameter(Mandatory = $false)][System.Xml.XmlNode]$Node)

    if ($null -eq $Node) { return '' }
    return (@(
        $Node.SelectNodes(".//*[local-name()='instrText'] | ./*[local-name()='instrText']") |
            ForEach-Object { [string]$_.InnerText }
    ) -join '')
}

function Get-WordSdtCandidateIdentifiers {
    param([Parameter(Mandatory = $true)][System.Xml.XmlNode]$SdtNode)

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        $SdtNode.SelectSingleNode("./*[local-name()='sdtPr']/*[local-name()='tag']/@*[local-name()='val']"),
        $SdtNode.SelectSingleNode("./*[local-name()='sdtPr']/*[local-name()='alias']/@*[local-name()='val']")
    )) {
        if ($null -eq $candidate) { continue }
        $value = [string]$candidate.Value
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $candidates.Add($value.Trim())
    }

    $dataBindingXPath = $SdtNode.SelectSingleNode("./*[local-name()='sdtPr']/*[local-name()='dataBinding']/@*[local-name()='xpath']")
    if ($null -ne $dataBindingXPath) {
        $xpathValue = [string]$dataBindingXPath.Value
        if ($xpathValue -match '(?i)/title(?:\[\d+\])?$') {
            $candidates.Add('Title')
        }
    }

    $fieldInstructionText = @(
        $SdtNode.SelectNodes(".//*[local-name()='instrText']") |
            ForEach-Object { [string]$_.InnerText }
    ) -join ' '
    $fieldName = Get-DocPropertyFieldNameFromInstructionText -InstructionText $fieldInstructionText
    if (-not [string]::IsNullOrWhiteSpace($fieldName)) {
        $candidates.Add($fieldName)
    }

    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Update-DocPropertyFieldResults {
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ReplaceByPropertyName
    )

    $discovered = 0
    $populated = 0

    foreach ($simpleField in @($XmlDocument.SelectNodes("//*[local-name()='fldSimple'][@*[local-name()='instr']]"))) {
        $instrAttr = $simpleField.Attributes | Where-Object { $_.LocalName -eq 'instr' } | Select-Object -First 1
        if ($null -eq $instrAttr) { continue }
        $propertyName = Get-DocPropertyFieldNameFromInstructionText -InstructionText ([string]$instrAttr.Value)
        if ([string]::IsNullOrWhiteSpace($propertyName)) { continue }
        $discovered++
        if (-not (Test-MapHasKey -Map $ReplaceByPropertyName -Key $propertyName)) { continue }
        $prototypeRuns = @(
            $simpleField.ChildNodes |
                Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq 'r' }
        )
        $replacementNodes = Convert-TextToStyledWordRunNodes -XmlDocument $XmlDocument -Text ([string]$ReplaceByPropertyName[$propertyName]) -PrototypeRunNodes $prototypeRuns
        Set-WordSdtContentNodes -SdtContentNode $simpleField -Nodes @($replacementNodes)
        $populated++
    }

    $fieldContainers = @(
        $XmlDocument.SelectNodes("//*[local-name()='p'] | //*[local-name()='sdtContent' and not(*[local-name()='p'])]")
    )

    foreach ($containerNode in $fieldContainers) {
        $currentNode = $containerNode.FirstChild
        while ($null -ne $currentNode) {
            $nextNode = $currentNode.NextSibling
            if ((Get-WordNodeFieldCharType -Node $currentNode) -ne 'begin') {
                $currentNode = $nextNode
                continue
            }

            $scanNode = $currentNode.NextSibling
            $separateNode = $null
            $endNode = $null
            $instructionText = ''
            while ($null -ne $scanNode) {
                $fieldCharType = Get-WordNodeFieldCharType -Node $scanNode
                if ($fieldCharType -eq 'separate') {
                    $separateNode = $scanNode
                    $scanNode = $scanNode.NextSibling
                    continue
                }
                if ($fieldCharType -eq 'end') {
                    $endNode = $scanNode
                    break
                }
                if ($null -eq $separateNode) {
                    $instructionText += (Get-WordNodeInstructionText -Node $scanNode)
                }
                $scanNode = $scanNode.NextSibling
            }

            if ($null -eq $separateNode -or $null -eq $endNode) {
                $currentNode = $nextNode
                continue
            }

            $propertyName = Get-DocPropertyFieldNameFromInstructionText -InstructionText $instructionText
            if (-not [string]::IsNullOrWhiteSpace($propertyName)) {
                $discovered++
                if (Test-MapHasKey -Map $ReplaceByPropertyName -Key $propertyName) {
                    $prototypeRuns = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
                    $prototypeScanNode = $separateNode.NextSibling
                    while ($null -ne $prototypeScanNode -and $prototypeScanNode -ne $endNode) {
                        if ($prototypeScanNode.NodeType -eq [System.Xml.XmlNodeType]::Element -and $prototypeScanNode.LocalName -eq 'r') {
                            $prototypeRuns.Add($prototypeScanNode)
                        }
                        $prototypeScanNode = $prototypeScanNode.NextSibling
                    }

                    $removeNode = $separateNode.NextSibling
                    while ($null -ne $removeNode -and $removeNode -ne $endNode) {
                        $nextRemoveNode = $removeNode.NextSibling
                        [void]$containerNode.RemoveChild($removeNode)
                        $removeNode = $nextRemoveNode
                    }

                    foreach ($replacementNode in @(Convert-TextToStyledWordRunNodes -XmlDocument $XmlDocument -Text ([string]$ReplaceByPropertyName[$propertyName]) -PrototypeRunNodes $prototypeRuns.ToArray())) {
                        [void]$containerNode.InsertBefore($replacementNode, $endNode)
                    }
                    $populated++
                }
            }

            $currentNode = $endNode.NextSibling
        }
    }

    return [ordered]@{
        discovered = [int]$discovered
        populated = [int]$populated
    }
}

function Resolve-DocPropNoPopulationSeverity {
    param(
        [Parameter(Mandatory = $false)][string]$PolicyValue
    )

    $candidate = [string]$PolicyValue
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = [string]$env:ASB_ASM_DOCPROP_NO_POPULATION_SEVERITY
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return 'ERROR'
    }

    $normalized = $candidate.Trim().ToUpperInvariant()
    if ($normalized -eq 'WARN') {
        return 'WARN'
    }

    return 'ERROR'
}

function Get-LiteralTagDiagnosticsSummary {
    param(
        [Parameter(Mandatory = $false)][object[]]$Diagnostics,
        [Parameter(Mandatory = $false)][object]$TopEntries = 20,
        [Parameter(Mandatory = $false)][object]$TopZeroHitTags = 5,
        [Parameter(Mandatory = $false)][object]$TopInspectedPartsPerTag = 3
    )

    function Get-FirstBoundedIntValue {
        param(
            [Parameter(Mandatory = $false)][object]$Value,
            [Parameter(Mandatory = $true)][int]$Default,
            [Parameter(Mandatory = $true)][int]$Min
        )

        $candidate = $Value
        if ($candidate -is [System.Collections.IEnumerable] -and -not ($candidate -is [string])) {
            $candidate = @($candidate | Select-Object -First 1)
            if (@($candidate).Count -gt 0) {
                $candidate = $candidate[0]
            } else {
                $candidate = $null
            }
        }

        $parsed = 0
        if ($null -eq $candidate -or -not [int]::TryParse([string]$candidate, [ref]$parsed)) {
            return [int]$Default
        }

        if ($parsed -lt $Min) {
            return [int]$Default
        }

        return [int]$parsed
    }

    function Get-DeterministicContiguousTokenHits {
        param([Parameter(Mandatory = $false)][object]$Value)

        if ($null -eq $Value) {
            return 0
        }

        if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
            # Deterministic rule: prefer the first numeric value in sequence order.
            foreach ($candidate in @($Value)) {
                $parsed = 0
                if ([int]::TryParse([string]$candidate, [ref]$parsed)) {
                    return [int]$parsed
                }
            }
            return 0
        }

        $parsedScalar = 0
        if ([int]::TryParse([string]$Value, [ref]$parsedScalar)) {
            return [int]$parsedScalar
        }

        return 0
    }

    $topEntriesBounded = Get-FirstBoundedIntValue -Value $TopEntries -Default 20 -Min 1
    $topZeroHitTagsBounded = Get-FirstBoundedIntValue -Value $TopZeroHitTags -Default 5 -Min 1
    $topInspectedPartsBounded = Get-FirstBoundedIntValue -Value $TopInspectedPartsPerTag -Default 3 -Min 1

    $diagnosticsFlattened = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Diagnostics)) {
        if ($null -eq $item) {
            continue
        }

        if (
            ($item -is [System.Collections.IDictionary]) -or
            ($item.PSObject -and $item.PSObject.Properties['tag']) -or
            ($item.PSObject -and $item.PSObject.Properties['partName']) -or
            ($item.PSObject -and $item.PSObject.Properties['mode']) -or
            ($item.PSObject -and $item.PSObject.Properties['contiguousTokenHits'])
        ) {
            $diagnosticsFlattened.Add($item)
            continue
        }

        if ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string])) {
            foreach ($nestedItem in @($item)) {
                if ($null -ne $nestedItem) {
                    $diagnosticsFlattened.Add($nestedItem)
                }
            }
            continue
        }

        $diagnosticsFlattened.Add($item)
    }

    $allDiagnostics = @($diagnosticsFlattened)
    if ($null -eq $allDiagnostics -or $allDiagnostics.Count -eq 0) {
        return [ordered]@{
            totalEntries = 0
            hitEntries = 0
            zeroHitEntries = 0
            contiguousTokenHitTotal = 0
            distinctTagCount = 0
            distinctPartCount = 0
            topEntryLimit = [int]$topEntriesBounded
            topEntries = @()
            zeroHitTagSampleLimit = [int]$topZeroHitTagsBounded
            zeroHitTagSamples = @()
        }
    }

    $diagnosticsNormalized = @(
        $allDiagnostics | ForEach-Object {
            $contiguousTokenHits = Get-DeterministicContiguousTokenHits -Value $_.contiguousTokenHits

            [ordered]@{
                tag = [string]$_.tag
                partName = [string]$_.partName
                mode = [string]$_.mode
                contiguousTokenHits = [int]$contiguousTokenHits
            }
        }
    )

    $hits = @($diagnosticsNormalized | ForEach-Object { [int]($_.contiguousTokenHits ?? 0) })
    $totalContiguousTokenHits = ($hits | Measure-Object -Sum).Sum
    if ($null -eq $totalContiguousTokenHits) { $totalContiguousTokenHits = 0 }

    $hitDiagnostics = @($diagnosticsNormalized | Where-Object { $_.contiguousTokenHits -gt 0 })
    $zeroHitDiagnostics = @($diagnosticsNormalized | Where-Object { $_.contiguousTokenHits -eq 0 })

    $topEntries = @(
        $diagnosticsNormalized |
            Sort-Object -Property @{ Expression = { $_.contiguousTokenHits }; Descending = $true }, @{ Expression = { [string]$_.tag }; Descending = $false }, @{ Expression = { [string]$_.partName }; Descending = $false } |
            Select-Object -First ([int]$topEntriesBounded) |
            ForEach-Object {
                [ordered]@{
                    tag = [string]$_.tag
                    partName = [string]$_.partName
                    mode = [string]$_.mode
                    contiguousTokenHits = [int]$_.contiguousTokenHits
                }
            }
    )

    $zeroHitSamplesByTag = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($group in @($zeroHitDiagnostics | Group-Object -Property tag, mode)) {
        $groupTag = ''
        $groupMode = ''
        $first = @($group.Group | Select-Object -First 1)
        if (@($first).Count -gt 0) {
            $groupTag = [string]$first[0].tag
            $groupMode = [string]$first[0].mode
        }
        $inspectedParts = @(
            $group.Group |
                ForEach-Object { [string]$_.partName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $zeroHitSamplesByTag.Add([ordered]@{
            tag = $groupTag
            mode = $groupMode
            inspectedParts = @($inspectedParts | Select-Object -First ([int]$topInspectedPartsBounded))
            inspectedPartCount = @($inspectedParts).Count
        })
    }

    $zeroHitSampleBounded = @(
        $zeroHitSamplesByTag |
            Sort-Object -Property @{ Expression = { [string]$_.tag }; Descending = $false }, @{ Expression = { [string]$_.mode }; Descending = $false } |
            Select-Object -First ([int]$topZeroHitTagsBounded)
    )

    return [ordered]@{
        totalEntries = $diagnosticsNormalized.Count
        hitEntries = $hitDiagnostics.Count
        zeroHitEntries = $zeroHitDiagnostics.Count
        contiguousTokenHitTotal = [int]$totalContiguousTokenHits
        distinctTagCount = @($diagnosticsNormalized | ForEach-Object { [string]$_.tag } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique).Count
        distinctPartCount = @($diagnosticsNormalized | ForEach-Object { [string]$_.partName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique).Count
        topEntryLimit = [int]$topEntriesBounded
        topEntries = $topEntries
        zeroHitTagSampleLimit = [int]$topZeroHitTagsBounded
        zeroHitTagSamples = $zeroHitSampleBounded
    }
}

function Get-LiteralTokenDiagnosticLookup {
    param(
        [Parameter(Mandatory = $false)][object[]]$Diagnostics
    )

    $lookup = @{}
    foreach ($diagnostic in @($Diagnostics)) {
        if ($null -eq $diagnostic) { continue }
        $key = "{0}`n{1}" -f [string]$diagnostic.partName, [string]$diagnostic.tag
        $lookup[$key] = $diagnostic
    }

    return $lookup
}

function Get-LiteralTagHitSummary {
    param(
        [Parameter(Mandatory = $false)][object[]]$Diagnostics
    )

    $summary = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($group in @(@($Diagnostics) | Group-Object -Property tag, mode)) {
        $items = @($group.Group)
        $first = @($items | Select-Object -First 1)
        if (@($first).Count -eq 0) { continue }

        $rawTokenHits = ($items | Measure-Object -Property rawTokenHits -Sum).Sum
        if ($null -eq $rawTokenHits) { $rawTokenHits = 0 }
        $escapedTokenHits = ($items | Measure-Object -Property escapedTokenHits -Sum).Sum
        if ($null -eq $escapedTokenHits) { $escapedTokenHits = 0 }
        $contiguousTokenHits = ($items | Measure-Object -Property contiguousTokenHits -Sum).Sum
        if ($null -eq $contiguousTokenHits) { $contiguousTokenHits = 0 }

        $matchedParts = @(
            $items |
                Where-Object { [int]$_.contiguousTokenHits -gt 0 } |
                ForEach-Object { [string]$_.partName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $fragmentHintParts = @(
            $items |
                Where-Object { [bool]$_.fragmentHint } |
                ForEach-Object { [string]$_.partName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        $summary.Add([ordered]@{
            tag = [string]$first[0].tag
            mode = [string]$first[0].mode
            rawTokenHits = [int]$rawTokenHits
            escapedTokenHits = [int]$escapedTokenHits
            contiguousTokenHits = [int]$contiguousTokenHits
            matchedPartCount = @($matchedParts).Count
            matchedParts = @($matchedParts)
            fragmentHintPartCount = @($fragmentHintParts).Count
            fragmentHintParts = @($fragmentHintParts)
        })
    }

    return @(
        $summary |
            Sort-Object -Property @{ Expression = { [string]$_.tag }; Descending = $false }, @{ Expression = { [string]$_.mode }; Descending = $false }
    )
}

function Get-LiteralPartHitSummary {
    param(
        [Parameter(Mandatory = $false)][object[]]$Diagnostics
    )

    $summary = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($group in @(@($Diagnostics) | Group-Object -Property partName)) {
        $items = @($group.Group)
        $first = @($items | Select-Object -First 1)
        if (@($first).Count -eq 0) { continue }

        $contiguousTokenHits = ($items | Measure-Object -Property contiguousTokenHits -Sum).Sum
        if ($null -eq $contiguousTokenHits) { $contiguousTokenHits = 0 }

        $matchedTags = @(
            $items |
                Where-Object { [int]$_.contiguousTokenHits -gt 0 } |
                ForEach-Object { [string]$_.tag } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $fragmentHintTags = @(
            $items |
                Where-Object { [bool]$_.fragmentHint } |
                ForEach-Object { [string]$_.tag } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        $summary.Add([ordered]@{
            partName = [string]$first[0].partName
            contiguousTokenHits = [int]$contiguousTokenHits
            matchedTagCount = @($matchedTags).Count
            matchedTags = @($matchedTags)
            fragmentHintTagCount = @($fragmentHintTags).Count
            fragmentHintTags = @($fragmentHintTags)
        })
    }

    return @(
        $summary |
            Sort-Object -Property @{ Expression = { [string]$_.partName }; Descending = $false }
    )
}
function Invoke-DocxLiteralTokenPass {
    param(
        [Parameter(Mandatory = $true)][string]$DocxPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ReplaceByTag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$TableByTag
    )

    $archive = [System.IO.Compression.ZipFile]::Open($DocxPath, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $tableStyleId = ''
        $tableParagraphStyleId = ''
        if ($null -ne $TableByTag -and @($TableByTag.Keys).Count -gt 0) {
            $stylesEntry = $archive.GetEntry('word/styles.xml')
            if ($null -ne $stylesEntry) {
                $stylesReader = [System.IO.StreamReader]::new($stylesEntry.Open())
                try {
                    $stylesXmlText = $stylesReader.ReadToEnd()
                    $tableStyleId = Get-WordTableStyleId -StylesXmlText $stylesXmlText -StyleName 'LNV Table 1 - 9pt Head Banded Grid'
                    $tableParagraphStyleId = Get-WordParagraphStyleId -StylesXmlText $stylesXmlText -StyleName 'LNVTableText1-9Pt-Indented'
                }
                finally {
                    $stylesReader.Dispose()
                }
            }
        }

        $literalTokensMatched = 0
        $literalTokensMatchedScalar = 0
        $literalTokensMatchedTable = 0
        foreach ($partName in @(Get-AssemblerWordXmlPartNames -Archive $archive)) {
            $entry = $archive.GetEntry([string]$partName)
            if ($null -eq $entry) { continue }

            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                $xmlText = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }

            $originalXmlText = $xmlText
            if ($null -ne $TableByTag) {
                foreach ($tag in @($TableByTag.Keys)) {
                    $tagText = [string]$tag
                    $tableXml = Convert-TableModelToWordTableXml -TableModel $TableByTag[$tag] -TableStyleId $tableStyleId -ParagraphStyleId $tableParagraphStyleId
                    if ([string]::IsNullOrWhiteSpace($tableXml)) { continue }
                    $escapedTag = [regex]::Escape($tagText)
                    $rawTokenPattern = "<<SDT:\s*$escapedTag\s*>>"
                    $escapedTokenPattern = "&lt;&lt;SDT:\s*$escapedTag\s*&gt;&gt;"
                    $tableTokenCount = [regex]::Matches($xmlText, "$rawTokenPattern|$escapedTokenPattern").Count
                    $literalTokensMatched += [int]$tableTokenCount
                    $literalTokensMatchedTable += [int]$tableTokenCount
                    $xmlText = Replace-DocxParagraphTokenWithBlockXml -XmlText $xmlText -Tag $tagText -BlockXml $tableXml
                }
            }

            foreach ($tag in @($ReplaceByTag.Keys)) {
                $tagText = [string]$tag
                $escapedTag = [regex]::Escape($tagText)
                $rawTokenPattern = "<<SDT:\s*$escapedTag\s*>>"
                $escapedTokenPattern = "&lt;&lt;SDT:\s*$escapedTag\s*&gt;&gt;"
                $scalarTokenCount = [regex]::Matches($xmlText, "$rawTokenPattern|$escapedTokenPattern").Count
                $literalTokensMatched += [int]$scalarTokenCount
                $literalTokensMatchedScalar += [int]$scalarTokenCount
                $xmlText = Replace-LiteralSdtTokenXmlText -XmlText $xmlText -Tag $tagText -Replacement ([string]$ReplaceByTag[$tag])
            }

            if ($xmlText -ne $originalXmlText) {
                $entry.Delete()
                $updatedEntry = $archive.CreateEntry([string]$partName)
                Set-ZipEntryText -Entry $updatedEntry -Text $xmlText
            }
        }

        return [ordered]@{
            literalTokensMatched = [int]$literalTokensMatched
            literalTokensMatchedScalar = [int]$literalTokensMatchedScalar
            literalTokensMatchedTable = [int]$literalTokensMatchedTable
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Render-DocxTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ReplaceByTag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$TableByTag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ImageByTag,
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
        [Parameter(Mandatory = $false)][string]$SupportRegionSidecarPath,
        [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'both',
        [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
    )

    Copy-Item -LiteralPath $TemplatePath -Destination $OutputPath -Force

    $renderResult = $null
    $updateFieldsOnOpenResult = [ordered]@{
        applied = $false
        reason = 'not-attempted'
    }

    $archive = [System.IO.Compression.ZipFile]::Open($OutputPath, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $unresolvedLiteralByTag = @{}
        $partsUpdated = 0
        $literalDatasetTokenLookup = @{}
        foreach ($datasetTag in @($ReplaceByTag.Keys)) {
            $datasetTagText = [string]$datasetTag
            if ([string]::IsNullOrWhiteSpace($datasetTagText)) { continue }
            $literalDatasetTokenLookup[$datasetTagText] = $true
        }
        if ($null -ne $TableByTag) {
            foreach ($datasetTag in @($TableByTag.Keys)) {
                $datasetTagText = [string]$datasetTag
                if ([string]::IsNullOrWhiteSpace($datasetTagText)) { continue }
                $literalDatasetTokenLookup[$datasetTagText] = $true
            }
        }
        if ($null -ne $ImageByTag) {
            foreach ($datasetTag in @($ImageByTag.Keys)) {
                $datasetTagText = [string]$datasetTag
                if ([string]::IsNullOrWhiteSpace($datasetTagText)) { continue }
                $literalDatasetTokenLookup[$datasetTagText] = $true
            }
        }
        $literalDatasetTokensExpected = @($literalDatasetTokenLookup.Keys).Count
        $literalDatasetTokensDiscovered = 0
        $literalDatasetTagsDiscovered = 0
        $literalTokensMatched = 0
        $literalTokensMatchedScalar = 0
        $literalTokensMatchedTable = 0
        $literalTokensMatchedImage = 0
        $docPropertyLiteralTokensMatched = 0
        $controlsDiscovered = 0
        $taggedControlsMatched = 0
        $controlsPopulated = 0
        $controlsDiscoveredMapped = 0
        $controlsDiscoveredUnmapped = 0
        $docPropertyFieldsDiscovered = 0
        $docPropertyFieldsPopulated = 0
        $discoveredTaggedControls = [System.Collections.Generic.List[string]]::new()
        $discoveredUnmappedTaggedControls = [System.Collections.Generic.List[string]]::new()
        $partErrors = [System.Collections.Generic.List[hashtable]]::new()
        $literalTagDiagnostics = [System.Collections.Generic.List[hashtable]]::new()
        $literalDatasetFragmentHintTags = @()
        $literalDatasetTagStatus = @()
        $literalTagHitSummary = @()
        $literalPartHitSummary = @()
        $supportRegionDocumentModel = Resolve-SupportRegionDocumentModel -SupportRegion $DocSupportRegion -SupportTier $DocSupportTier -SidecarPath $SupportRegionSidecarPath
        $contentControlReplaceByTag = Get-DocxContentControlReplacementMap -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment -DocDocumentReference $DocDocumentReference -DocVersion $DocVersion -DocConfigSnapDate $DocConfigSnapDate -DocReferenceId $DocReferenceId -DocClassification $DocClassification -DocSupportRegion ([string]$supportRegionDocumentModel.SupportRegion) -DocSupportTier ([string]$supportRegionDocumentModel.SupportTierId) -SupportRegionModel $supportRegionDocumentModel
        $docPropertyFieldReplaceByName = Get-DocxDocPropertyFieldReplacementMap -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment -DocDocumentReference $DocDocumentReference -DocVersion $DocVersion -DocConfigSnapDate $DocConfigSnapDate -DocReferenceId $DocReferenceId -DocClassification $DocClassification -DocSupportRegion ([string]$supportRegionDocumentModel.SupportRegion) -DocSupportTier ([string]$supportRegionDocumentModel.SupportTierId) -SupportRegionModel $supportRegionDocumentModel
        $tableStyleId = ''
        $tableParagraphStyleId = ''
        if ($null -ne $TableByTag -and @($TableByTag.Keys).Count -gt 0) {
            $stylesEntry = $archive.GetEntry('word/styles.xml')
            if ($null -ne $stylesEntry) {
                $stylesReader = [System.IO.StreamReader]::new($stylesEntry.Open())
                try {
                    $stylesXmlText = $stylesReader.ReadToEnd()
                    $tableStyleId = Get-WordTableStyleId -StylesXmlText $stylesXmlText -StyleName 'LNV Table 1 - 9pt Head Banded Grid'
                    $tableParagraphStyleId = Get-WordParagraphStyleId -StylesXmlText $stylesXmlText -StyleName 'LNVTableText1-9Pt-Indented'
                }
                finally {
                    $stylesReader.Dispose()
                }
            }
        }

        $partEntries = @(Get-WordXmlPartEntries -Archive $archive)
        $updatedPartXmlByName = [ordered]@{}
        $partXmlByName = [ordered]@{}
        foreach ($entry in @($partEntries)) {
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                $partXmlByName[[string]$entry.FullName] = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }

        $tableXmlByTag = @{}
        if ($null -ne $TableByTag) {
            foreach ($tag in @($TableByTag.Keys)) {
                $tagText = [string]$tag
                $tableXmlByTag[$tagText] = Convert-TableModelToWordTableXml -TableModel $TableByTag[$tag] -TableStyleId $tableStyleId -ParagraphStyleId $tableParagraphStyleId
            }
        }

        $imageXmlByTag = @{}
        $imageIndex = 1
        if ($null -ne $ImageByTag) {
            foreach ($tag in @($ImageByTag.Keys)) {
                $tagText = [string]$tag
                $imageModel = $ImageByTag[$tag]
                if (-not ($imageModel -is [System.Collections.IDictionary])) { continue }
                if (-not (Test-MapHasKey -Map $imageModel -Key 'imageBase64') -or [string]::IsNullOrWhiteSpace([string]$imageModel.imageBase64)) { continue }
                $imageFormat = if ((Test-MapHasKey -Map $imageModel -Key 'imageFormat') -and [string]$imageModel.imageFormat -eq 'svg') { 'svg' } else { 'png' }
                $contentType = if ($imageFormat -eq 'svg') { 'image/svg+xml' } else { 'image/png' }
                $relationshipId = Add-DocxPngImagePart -Archive $archive -ImageBase64 ([string]$imageModel.imageBase64) -ImageExtension $imageFormat -ContentType $contentType
                $imageXmlByTag[$tagText] = Convert-ImageModelToWordDrawingXml -ImageModel $imageModel -RelationshipId $relationshipId -ImageIndex $imageIndex
                $imageIndex++
            }
        }

        $literalDiagnosticLookup = @{}
        if ($literalDatasetTokensExpected -gt 0) {
            $sharedLiteralDiagnostics = @(Get-AssemblerDocxLiteralTokenDiagnosticsFromXmlParts -XmlPartsByName $partXmlByName -Tags @($literalDatasetTokenLookup.Keys))
            $literalDiagnosticLookup = Get-LiteralTokenDiagnosticLookup -Diagnostics $sharedLiteralDiagnostics
            $literalDatasetTagStatus = @(Get-AssemblerDocxLiteralTokenTagSummary -Diagnostics $sharedLiteralDiagnostics)

            $literalDatasetTokensDiscovered = ($sharedLiteralDiagnostics | Measure-Object -Property contiguousTokenHits -Sum).Sum
            if ($null -eq $literalDatasetTokensDiscovered) { $literalDatasetTokensDiscovered = 0 }
            $literalDatasetTokensDiscovered = [int]$literalDatasetTokensDiscovered

            $literalDatasetTagsDiscovered = @($literalDatasetTagStatus | Where-Object { [int]$_.contiguousLiteralHits -gt 0 }).Count
            $literalDatasetFragmentHintTags = @(
                $literalDatasetTagStatus |
                    Where-Object { [string]$_.status -eq 'FRAGMENTED_OR_NON_LITERAL' } |
                    ForEach-Object { [string]$_.tag } |
                    Sort-Object -Unique
            )

            foreach ($diagnostic in @($sharedLiteralDiagnostics)) {
                $tagText = [string]$diagnostic.tag
                if (Test-MapHasKey -Map $tableXmlByTag -Key $tagText) {
                    $literalTagDiagnostics.Add([ordered]@{
                        partName = [string]$diagnostic.partName
                        tag = $tagText
                        mode = 'table'
                        tableXmlGenerated = -not [string]::IsNullOrWhiteSpace([string]$tableXmlByTag[$tagText])
                        rawTokenHits = [int]$diagnostic.rawTokenHits
                        escapedTokenHits = [int]$diagnostic.escapedTokenHits
                        contiguousTokenHits = [int]$diagnostic.contiguousTokenHits
                        containsTagText = [bool]$diagnostic.containsTagText
                        fragmentHint = [bool]$diagnostic.fragmentHint
                    })
                }
                if (Test-MapHasKey -Map $ReplaceByTag -Key $tagText) {
                    $literalTagDiagnostics.Add([ordered]@{
                        partName = [string]$diagnostic.partName
                        tag = $tagText
                        mode = 'scalar'
                        rawTokenHits = [int]$diagnostic.rawTokenHits
                        escapedTokenHits = [int]$diagnostic.escapedTokenHits
                        contiguousTokenHits = [int]$diagnostic.contiguousTokenHits
                        containsTagText = [bool]$diagnostic.containsTagText
                        fragmentHint = [bool]$diagnostic.fragmentHint
                    })
                }
                if (Test-MapHasKey -Map $imageXmlByTag -Key $tagText) {
                    $literalTagDiagnostics.Add([ordered]@{
                        partName = [string]$diagnostic.partName
                        tag = $tagText
                        mode = 'image'
                        imageXmlGenerated = -not [string]::IsNullOrWhiteSpace([string]$imageXmlByTag[$tagText])
                        rawTokenHits = [int]$diagnostic.rawTokenHits
                        escapedTokenHits = [int]$diagnostic.escapedTokenHits
                        contiguousTokenHits = [int]$diagnostic.contiguousTokenHits
                        containsTagText = [bool]$diagnostic.containsTagText
                        fragmentHint = [bool]$diagnostic.fragmentHint
                    })
                }
            }

            $literalTagHitSummary = @(Get-LiteralTagHitSummary -Diagnostics $literalTagDiagnostics.ToArray())
            $literalPartHitSummary = @(Get-LiteralPartHitSummary -Diagnostics $literalTagDiagnostics.ToArray())
        }

        foreach ($entry in @($partEntries)) {
            $xmlText = [string]$partXmlByName[[string]$entry.FullName]
            $originalXmlText = $xmlText
            $selectionContextNode = $null
            $xmlDocTyped = $null
            $nsMgrTyped = $null

            if (Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'literal-token') {
                if ($null -ne $ImageByTag -and [string]$entry.FullName -eq 'word/document.xml') {
                    foreach ($tag in @($ImageByTag.Keys)) {
                        $tagText = [string]$tag
                        $imageTokenCount = 0
                        $diagKey = "{0}`n{1}" -f [string]$entry.FullName, $tagText
                        if (Test-MapHasKey -Map $literalDiagnosticLookup -Key $diagKey) {
                            $imageTokenCount = [int]$literalDiagnosticLookup[$diagKey].contiguousTokenHits
                        }

                        $literalTokensMatched += [int]$imageTokenCount
                        $literalTokensMatchedImage += [int]$imageTokenCount
                        $imageXml = if (Test-MapHasKey -Map $imageXmlByTag -Key $tagText) { [string]$imageXmlByTag[$tagText] } else { '' }
                        if (-not [string]::IsNullOrWhiteSpace($imageXml)) {
                            $xmlText = Replace-DocxParagraphTokenWithBlockXml -XmlText $xmlText -Tag $tagText -BlockXml $imageXml
                        }
                    }
                }

                if ($null -ne $TableByTag) {
                    foreach ($tag in @($TableByTag.Keys)) {
                        $tagText = [string]$tag
                        $tableTokenCount = 0
                        $diagKey = "{0}`n{1}" -f [string]$entry.FullName, $tagText
                        if (Test-MapHasKey -Map $literalDiagnosticLookup -Key $diagKey) {
                            $tableTokenCount = [int]$literalDiagnosticLookup[$diagKey].contiguousTokenHits
                        }

                        $literalTokensMatched += [int]$tableTokenCount
                        $literalTokensMatchedTable += [int]$tableTokenCount
                        $tableXml = if (Test-MapHasKey -Map $tableXmlByTag -Key $tagText) { [string]$tableXmlByTag[$tagText] } else { '' }
                        if (-not [string]::IsNullOrWhiteSpace($tableXml)) {
                            $xmlText = Replace-DocxParagraphTokenWithBlockXml -XmlText $xmlText -Tag $tagText -BlockXml $tableXml
                        }
                    }
                }

                foreach ($tag in @($ReplaceByTag.Keys)) {
                    $tagText = [string]$tag
                    $scalarTokenCount = 0
                    $diagKey = "{0}`n{1}" -f [string]$entry.FullName, $tagText
                    if (Test-MapHasKey -Map $literalDiagnosticLookup -Key $diagKey) {
                        $scalarTokenCount = [int]$literalDiagnosticLookup[$diagKey].contiguousTokenHits
                    }

                    $literalTokensMatched += [int]$scalarTokenCount
                    $literalTokensMatchedScalar += [int]$scalarTokenCount
                    $xmlText = Replace-LiteralSdtTokenXmlText -XmlText $xmlText -Tag $tagText -Replacement ([string]$ReplaceByTag[$tag])
                }

                foreach ($tag in @($contentControlReplaceByTag.Keys)) {
                    $tagText = [string]$tag
                    if (Test-MapHasKey -Map $ReplaceByTag -Key $tagText) { continue }

                    $scalarTokenCount = Measure-LiteralSdtTokenXmlText -XmlText $xmlText -Tag $tagText
                    $literalTokensMatched += [int]$scalarTokenCount
                    $literalTokensMatchedScalar += [int]$scalarTokenCount
                    $docPropertyLiteralTokensMatched += [int]$scalarTokenCount
                    $xmlText = Replace-LiteralSdtTokenXmlText -XmlText $xmlText -Tag $tagText -Replacement ([string]$contentControlReplaceByTag[$tagText])
                }
            }

            try {
                if (Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'content-control-tag') {
                    [System.Xml.XmlDocument]$xmlDocTyped = [xml]$xmlText
                    $selectionContextNode = [System.Xml.XmlNode]$xmlDocTyped.DocumentElement
                    if ($null -eq $selectionContextNode) {
                        throw 'Unable to discover content controls because XML document element was null.'
                    }
                    $sdtNodes = @($selectionContextNode.SelectNodes("//*[local-name()='sdt'][*[local-name()='sdtPr']]"))
                    foreach ($sdtNode in $sdtNodes) {
                        $candidateIdentifiers = @(Get-WordSdtCandidateIdentifiers -SdtNode $sdtNode)
                        if (@($candidateIdentifiers).Count -eq 0) { continue }
                        $controlsDiscovered++
                        foreach ($candidateIdentifier in @($candidateIdentifiers)) {
                            $discoveredTaggedControls.Add([string]$candidateIdentifier)
                        }

                        $matchedIdentifier = @(
                            $candidateIdentifiers |
                                Where-Object { Test-MapHasKey -Map $contentControlReplaceByTag -Key ([string]$_) } |
                                Select-Object -First 1
                        ) | Select-Object -First 1

                        if (-not [string]::IsNullOrWhiteSpace([string]$matchedIdentifier)) {
                            $controlsDiscoveredMapped++
                        }
                        else {
                            $controlsDiscoveredUnmapped++
                            foreach ($candidateIdentifier in @($candidateIdentifiers)) {
                                $discoveredUnmappedTaggedControls.Add([string]$candidateIdentifier)
                            }
                        }

                        $sdtContent = $sdtNode.SelectSingleNode("./*[local-name()='sdtContent']")
                        if ($null -eq $sdtContent) { continue }

                        if (-not [string]::IsNullOrWhiteSpace([string]$matchedIdentifier) -and (Test-MapHasKey -Map $contentControlReplaceByTag -Key ([string]$matchedIdentifier))) {
                            $taggedControlsMatched++
                            if (-not (Test-WordSdtContentContainsFieldCodes -SdtContentNode $sdtContent)) {
                                $replacementNodes = Convert-TextToWordSdtContentNodes -XmlDocument $xmlDocTyped -SdtNode $sdtNode -SdtContentNode $sdtContent -Text ([string]$contentControlReplaceByTag[[string]$matchedIdentifier])
                                Set-WordSdtContentNodes -SdtContentNode $sdtContent -Nodes $replacementNodes
                                $controlsPopulated++
                            }
                        }
                    }

                    $fieldUpdate = Update-DocPropertyFieldResults -XmlDocument $xmlDocTyped -ReplaceByPropertyName $docPropertyFieldReplaceByName
                    $docPropertyFieldsDiscovered += [int]$fieldUpdate.discovered
                    $docPropertyFieldsPopulated += [int]$fieldUpdate.populated
                    $xmlText = $xmlDocTyped.OuterXml
                }
            }
            catch {
                $partErrors.Add([ordered]@{
                    partName = [string]$entry.FullName
                    message = [string]$_.Exception.Message
                    matchMode = [string]$DocxMatchMode
                    xmlNodeType = if ($null -eq $selectionContextNode) { '' } else { [string]$selectionContextNode.GetType().FullName }
                    nsMgrType = if ($null -eq $nsMgrTyped) { '' } else { [string]$nsMgrTyped.GetType().FullName }
                    xmlDocType = if ($null -eq $xmlDocTyped) { '' } else { [string]$xmlDocTyped.GetType().FullName }
                    powershellVersion = if ($null -eq $PSVersionTable -or $null -eq $PSVersionTable.PSVersion) { '' } else { [string]$PSVersionTable.PSVersion.ToString() }
                })
                $xmlDocTyped = $null
                $xmlText = $originalXmlText
            }

            if ([string]$UnresolvedTokenPolicy -eq 'remove') {
                $xmlText = Remove-UnresolvedSdtTokensFromText -Text $xmlText
            }

            $updatedPartXmlByName[[string]$entry.FullName] = $xmlText
            $partsUpdated++

            $partUnresolved = Get-UnresolvedSdtTagOccurrences -RenderedText $xmlText
            Merge-UnresolvedSdtTagOccurrences -Target $unresolvedLiteralByTag -Source $partUnresolved
        }

        foreach ($partName in @($updatedPartXmlByName.Keys)) {
            $existingEntry = $archive.GetEntry([string]$partName)
            if ($null -ne $existingEntry) {
                $existingEntry.Delete()
            }
            $updatedEntry = $archive.CreateEntry([string]$partName)
            Set-ZipEntryText -Entry $updatedEntry -Text ([string]$updatedPartXmlByName[$partName])
        }

        $mappedTagsNotDiscovered = [System.Collections.Generic.List[string]]::new()
        $discoveredLookup = @{}
        foreach ($discoveredTag in @($discoveredTaggedControls)) {
            if ([string]::IsNullOrWhiteSpace([string]$discoveredTag)) { continue }
            $discoveredLookup[[string]$discoveredTag] = $true
        }
        foreach ($mappedTag in @($contentControlReplaceByTag.Keys)) {
            $mappedTagText = [string]$mappedTag
            if ([string]::IsNullOrWhiteSpace($mappedTagText)) { continue }
            if (-not (Test-MapHasKey -Map $discoveredLookup -Key $mappedTagText)) {
                $mappedTagsNotDiscovered.Add($mappedTagText)
            }
        }

        Update-DocxMetadataProperties -Archive $archive -Title $DocTitle -Customer $DocCustomer -CustomerAbbr $DocCustomerAbbr -Location $DocLocation -Subsidiary $DocSubsidiary -Environment $DocEnvironment -DocumentReference $DocDocumentReference -Version $DocVersion -ConfigSnapDate $DocConfigSnapDate -ReferenceId $DocReferenceId -Classification $DocClassification -SupportRegion ([string]$supportRegionDocumentModel.SupportRegion) -SupportRegionModel $supportRegionDocumentModel
        $updateFieldsOnOpenPreparationResult = Set-DocxUpdateFieldsOnOpen -Archive $archive -Enabled $false

        $renderResult = [ordered]@{
            unresolvedLiteralByTag = $unresolvedLiteralByTag
            partsUpdated = $partsUpdated
            outputPathResolved = [System.IO.Path]::GetFullPath($OutputPath)
            literalDatasetTokensExpected = [int]$literalDatasetTokensExpected
            literalDatasetTokensDiscovered = [int]$literalDatasetTokensDiscovered
            literalDatasetTagsDiscovered = [int]$literalDatasetTagsDiscovered
            literalDatasetFragmentHintTags = @($literalDatasetFragmentHintTags)
            literalDatasetTagStatus = @($literalDatasetTagStatus)
            literalDatasetTokensPopulated = [int]$literalTokensMatched
            literalTokensMatched = $literalTokensMatched
            literalTokensMatchedScalar = $literalTokensMatchedScalar
            literalTokensMatchedTable = $literalTokensMatchedTable
            literalTokensMatchedImage = $literalTokensMatchedImage
            docPropertyLiteralTokensMatched = [int]$docPropertyLiteralTokensMatched
            docPropControlsExpected = @($contentControlReplaceByTag.Keys).Count
            docPropControlsMatched = $taggedControlsMatched
            docPropControlsPopulated = $controlsPopulated
            controlsDiscovered = $controlsDiscovered
            controlsDiscoveredMapped = $controlsDiscoveredMapped
            controlsDiscoveredUnmapped = $controlsDiscoveredUnmapped
            docPropertyFieldsDiscovered = [int]$docPropertyFieldsDiscovered
            docPropertyFieldsPopulated = [int]$docPropertyFieldsPopulated
            taggedControlsMatched = $taggedControlsMatched
            controlsPopulated = $controlsPopulated
            discoveredTaggedControls = @($discoveredTaggedControls | Sort-Object -Unique)
            discoveredUnmappedTaggedControls = @($discoveredUnmappedTaggedControls | Sort-Object -Unique)
            unmatchedTaggedControls = @($mappedTagsNotDiscovered | Sort-Object -Unique)
            docPropMappedTags = @($contentControlReplaceByTag.Keys | Sort-Object -Unique)
            contentControlMappedTags = @($contentControlReplaceByTag.Keys | Sort-Object -Unique)
            supportRegion = [ordered]@{
                id = [string]$supportRegionDocumentModel.SupportRegion
                label = [string]$supportRegionDocumentModel.SupportRegionLabel
                displayName = [string]$supportRegionDocumentModel.SupportRegionDisplayName
                tierId = [string]$supportRegionDocumentModel.SupportTierId
                tier = [string]$supportRegionDocumentModel.SupportTier
                workingHours = [string]$supportRegionDocumentModel.SupportWorkingHours
                sidecarPath = [string]$supportRegionDocumentModel.SupportRegionSidecarPath
            }
            partErrors = @($partErrors)
            literalTagDiagnostics = $literalTagDiagnostics.ToArray()
            literalTagHitSummary = @($literalTagHitSummary)
            literalPartHitSummary = @($literalPartHitSummary)
            updateFieldsOnOpenEnabled = $false
            updateFieldsOnOpenReason = [string]$updateFieldsOnOpenPreparationResult.reason
            updateFieldsOnOpenPreparation = $updateFieldsOnOpenPreparationResult
            updateFieldsOnOpenFinal = [ordered]@{}
            tocRefreshDiagnostics = [ordered]@{}
        }
    }
    finally {
        $archive.Dispose()
    }

    if ($null -ne $renderResult) {
        $tocRefreshResult = Try-RefreshDocxTableOfContents -OutputPath $OutputPath
        $finalFieldRefreshState = Get-DocxFieldRefreshState -Path $OutputPath
        $updateFieldsFinalReason = if ([bool]$finalFieldRefreshState.updateFieldsOnOpenEnabled) {
            'Final DOCX contains enabled w:updateFields; Word may prompt to update fields/links on open.'
        }
        else {
            'Final DOCX does not contain enabled w:updateFields.'
        }
        $renderResult.tocRefreshStatus = [string]$tocRefreshResult.status
        $renderResult.tocRefreshMethod = [string]$tocRefreshResult.method
        $renderResult.tocRefreshMessage = [string]$tocRefreshResult.message
        $renderResult.tocRefreshDiagnostics = $tocRefreshResult.diagnostics
        $renderResult.updateFieldsOnOpenEnabled = [bool]$finalFieldRefreshState.updateFieldsOnOpenEnabled
        $renderResult.updateFieldsOnOpenReason = $updateFieldsFinalReason
        $renderResult.updateFieldsOnOpenFinal = $finalFieldRefreshState
    }

    return $renderResult
}

function Format-SizeHuman {
    param([Parameter(Mandatory = $false)]$Bytes)

    if ($null -eq $Bytes) { return '' }
    [double]$value = 0
    if (-not [double]::TryParse([string]$Bytes, [ref]$value)) { return [string]$Bytes }

    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $idx = 0
    while ($value -ge 1024 -and $idx -lt ($units.Count - 1)) {
        $value = $value / 1024
        $idx++
    }
    return ('{0:N2} {1}' -f $value, $units[$idx])
}

function ConvertTo-PlainHashtable {
    param([Parameter(Mandatory = $false)]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $converted = @{}
        foreach ($key in $InputObject.Keys) {
            $converted[[string]$key] = ConvertTo-PlainHashtable -InputObject $InputObject[$key]
        }
        return $converted
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-PlainHashtable -InputObject $item))
        }
        return ,$items.ToArray()
    }

    $properties = $null
    if ($InputObject.PSObject) {
        $properties = @($InputObject.PSObject.Properties)
    }

    if ($null -ne $properties -and $properties.Count -gt 0) {
        $converted = @{}
        foreach ($property in $properties) {
            $converted[[string]$property.Name] = ConvertTo-PlainHashtable -InputObject $property.Value
        }
        return $converted
    }

    return $InputObject
}

function Copy-AsHashtable {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return $null }
    return (($Value | ConvertTo-Json -Depth 30) | ConvertFrom-Json -AsHashtable)
}

function Set-MappingEntryTagShape {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entry,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    $sdtTag = if (Test-MapHasKey -Map $Entry -Key 'sdtTag') { [string]$Entry['sdtTag'] } else { '' }
    $targetTag = if (
        (Test-MapHasKey -Map $Entry -Key 'target') -and
        $Entry['target'] -is [System.Collections.IDictionary] -and
        (Test-MapHasKey -Map $Entry['target'] -Key 'sdtTag')
    ) { [string]$Entry['target']['sdtTag'] } else { '' }

    switch ($Mode) {
        'source-only' {
            if (-not [string]::IsNullOrWhiteSpace($targetTag)) {
                $Entry['sdtTag'] = $targetTag
            }
            if (Test-MapHasKey -Map $Entry -Key 'target') {
                $Entry.Remove('target')
            }
        }
        'target-only' {
            if (-not [string]::IsNullOrWhiteSpace($sdtTag) -and [string]::IsNullOrWhiteSpace($targetTag)) {
                $targetTag = $sdtTag
            }
            if (-not [string]::IsNullOrWhiteSpace($targetTag)) {
                $Entry['target'] = [ordered]@{ sdtTag = $targetTag }
            }
            if (Test-MapHasKey -Map $Entry -Key 'sdtTag') {
                $Entry.Remove('sdtTag')
            }
        }
        'dual' {
            if (-not [string]::IsNullOrWhiteSpace($targetTag) -and [string]::IsNullOrWhiteSpace($sdtTag)) {
                $sdtTag = $targetTag
            }
            if (-not [string]::IsNullOrWhiteSpace($sdtTag) -and [string]::IsNullOrWhiteSpace($targetTag)) {
                $targetTag = $sdtTag
            }

            if (-not [string]::IsNullOrWhiteSpace($sdtTag)) {
                $Entry['sdtTag'] = $sdtTag
            }
            if (-not [string]::IsNullOrWhiteSpace($targetTag)) {
                $Entry['target'] = [ordered]@{ sdtTag = $targetTag }
            }
        }
        default {
            throw "Unknown mapping tag-shape mode '$Mode'."
        }
    }
}

function Resolve-MappingSchemaCompatibleDocument {
    param(
        [Parameter(Mandatory = $true)][hashtable]$MappingDocument,
        [Parameter(Mandatory = $true)][string]$SchemaPath,
        [Parameter(Mandatory = $true)][string]$DocumentLabel
    )

    $candidates = @(
        [ordered]@{ mode = 'as-is'; value = (Copy-AsHashtable -Value $MappingDocument) },
        [ordered]@{ mode = 'dual'; value = (Copy-AsHashtable -Value $MappingDocument) },
        [ordered]@{ mode = 'target-only'; value = (Copy-AsHashtable -Value $MappingDocument) },
        [ordered]@{ mode = 'source-only'; value = (Copy-AsHashtable -Value $MappingDocument) }
    )

    foreach ($candidate in $candidates) {
        if ($candidate.mode -ne 'as-is' -and (Test-MapHasKey -Map $candidate.value -Key 'mappings')) {
            foreach ($entry in @($candidate.value.mappings)) {
                if ($entry -is [System.Collections.IDictionary]) {
                    Set-MappingEntryTagShape -Entry $entry -Mode ([string]$candidate.mode)
                }
            }
        }

        $candidateJson = $candidate.value | ConvertTo-Json -Depth 30
        $validation = Test-AssemblerSchemaJson -JsonText $candidateJson -SchemaPath $SchemaPath -DocumentLabel $DocumentLabel
        if ($validation.isValid) {
            return [ordered]@{
                isValid = $true
                mode = [string]$candidate.mode
                mapping = $candidate.value
                message = [string]$validation.message
            }
        }
    }

    $finalValidation = Test-AssemblerSchemaFile -DocumentPath $DocumentLabel -SchemaPath $SchemaPath
    return [ordered]@{
        isValid = $false
        mode = 'none'
        mapping = $MappingDocument
        message = [string]$finalValidation.message
    }
}


$script:DatasetPresentationMetadataCache = @{}

function Get-DatasetContractKey {
    param(
        [Parameter(Mandatory = $false)][string]$DatasetRelativePath,
        [Parameter(Mandatory = $false)][hashtable]$Dataset
    )

    if ($null -ne $Dataset -and $Dataset.ContainsKey('dataset')) {
        $datasetValue = $Dataset.dataset
        if ($datasetValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$datasetValue)) {
            return [string]$datasetValue
        }

        if ($datasetValue -is [System.Collections.IDictionary] -and (Test-MapHasKey -Map $datasetValue -Key 'key') -and -not [string]::IsNullOrWhiteSpace([string]$datasetValue['key'])) {
            return [string]$datasetValue['key']
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DatasetRelativePath)) {
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension([string]$DatasetRelativePath)
        if (-not [string]::IsNullOrWhiteSpace($fileName)) {
            return $fileName
        }
    }

    return $null
}

function Get-DatasetPresentationMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $false)][string]$DatasetContractKey
    )

    if ([string]::IsNullOrWhiteSpace($DatasetContractKey)) {
        return $null
    }

    $cacheKey = "$ContractsRoot|$TechId|$DatasetContractKey"
    if (Test-MapHasKey -Map $script:DatasetPresentationMetadataCache -Key $cacheKey) {
        return $script:DatasetPresentationMetadataCache[$cacheKey]
    }

    $metadataPath = Join-Path (Join-Path (Join-Path (Join-Path $ContractsRoot 'tech') $TechId) 'dataset') ($DatasetContractKey + '.assembler.meta.json')
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        $script:DatasetPresentationMetadataCache[$cacheKey] = $null
        return $null
    }

    $metadata = ConvertTo-PlainHashtable -InputObject (Read-JsonFile -Path $metadataPath)
    $script:DatasetPresentationMetadataCache[$cacheKey] = $metadata
    return $metadata
}

function Resolve-PreferredProjectionFromMetadata {
    param(
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DatasetPresentation,
        [Parameter(Mandatory = $false)][string]$Tag
    )

    if ($null -eq $DatasetPresentation -or -not (Test-MapHasKey -Map $DatasetPresentation -Key 'preferredProjectionViews')) {
        return $null
    }

    $preferredProjectionViews = if (Test-MapHasKey -Map $DatasetPresentation -Key 'preferredProjectionViews') { $DatasetPresentation['preferredProjectionViews'] } else { $null }
    $views = @(ConvertTo-ObjectArray -InputObject $preferredProjectionViews | Where-Object { $_ -is [System.Collections.IDictionary] })
    if (@($views).Count -eq 0) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        foreach ($view in $views) {
            $viewName = if (Test-MapHasKey -Map $view -Key 'name') { [string]$view['name'] } else { '' }
            $projectionRef = if (Test-MapHasKey -Map $view -Key 'projectionRef') { [string]$view['projectionRef'] } else { '' }
            if ((-not [string]::IsNullOrWhiteSpace($viewName) -and $Tag.IndexOf($viewName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or (-not [string]::IsNullOrWhiteSpace($projectionRef) -and $Tag.IndexOf($projectionRef, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                return $view
            }
        }
    }

    if (@($views).Count -eq 1) {
        return $views[0]
    }

    return $null
}

function Get-MappingRenderHint {
    param(
        [Parameter(Mandatory = $false)]$MappingEntry,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DatasetPresentation,
        [Parameter(Mandatory = $false)][string]$Tag
    )

    $hint = [ordered]@{}

    if ($null -ne $DatasetPresentation) {
        $presentationKind = if (Test-MapHasKey -Map $DatasetPresentation -Key 'presentationKind') { [string]$DatasetPresentation['presentationKind'] } else { '' }
        switch ($presentationKind) {
            'table' { $hint.renderAs = 'table' }
            'relationshipTable' { $hint.renderAs = 'table' }
            'evidence' { $hint.renderMode = 'json-evidence' }
            'summary' { }
        }

        $preferredProjection = Resolve-PreferredProjectionFromMetadata -DatasetPresentation $DatasetPresentation -Tag $Tag
        if ($null -ne $preferredProjection) {
            if ((Test-MapHasKey -Map $preferredProjection -Key 'projectionRef') -and -not [string]::IsNullOrWhiteSpace([string]$preferredProjection['projectionRef'])) {
                $hint.projectionRef = [string]$preferredProjection['projectionRef']
            }
            if ((Test-MapHasKey -Map $preferredProjection -Key 'name') -and -not [string]::IsNullOrWhiteSpace([string]$preferredProjection['name'])) {
                $hint.view = [string]$preferredProjection['name']
            }
        }
    }

    if ($null -eq $MappingEntry -or -not ($MappingEntry -is [System.Collections.IDictionary])) {
        return $hint
    }

    if ((Test-MapHasKey -Map $MappingEntry -Key 'renderHint') -and $MappingEntry['renderHint'] -is [System.Collections.IDictionary]) {
        foreach ($key in @($MappingEntry['renderHint'].Keys)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$key)) {
                $hint[[string]$key] = $MappingEntry['renderHint'][$key]
            }
        }
    }

    foreach ($topLevelHintKey in @('projectionRef', 'diagramRef', 'renderAs', 'view', 'renderMode', 'structuredValuePolicy', 'missingProjectionPolicy')) {
        if (-not $hint.Contains($topLevelHintKey) -and (Test-MapHasKey -Map $MappingEntry -Key $topLevelHintKey) -and -not [string]::IsNullOrWhiteSpace([string]$MappingEntry[$topLevelHintKey])) {
            $hint[$topLevelHintKey] = [string]$MappingEntry[$topLevelHintKey]
        }
    }

    return $hint
}

function Get-EffectiveRenderMode {
    param(
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinition,
        [Parameter(Mandatory = $false)][string]$Tag
    )

    if ($null -ne $ProjectionDefinition -and (Test-MapHasKey -Map $ProjectionDefinition -Key 'renderMode') -and -not [string]::IsNullOrWhiteSpace([string]$ProjectionDefinition['renderMode'])) {
        return [string]$ProjectionDefinition['renderMode']
    }

    if ($null -ne $RenderHint) {
        if ((Test-MapHasKey -Map $RenderHint -Key 'renderMode') -and -not [string]::IsNullOrWhiteSpace([string]$RenderHint['renderMode'])) {
            return [string]$RenderHint['renderMode']
        }

        if ((Test-MapHasKey -Map $RenderHint -Key 'renderAs') -and -not [string]::IsNullOrWhiteSpace([string]$RenderHint['renderAs'])) {
            return [string]$RenderHint['renderAs']
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Tag) -and $Tag.EndsWith('_TABLE_JSON')) {
        return 'table'
    }

    return 'scalar'
}

function Test-RenderModeWasExplicitlyDeclared {
    param(
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinition
    )

    foreach ($source in @($ProjectionDefinition, $RenderHint)) {
        if ($null -eq $source) { continue }
        if ((Test-MapHasKey -Map $source -Key 'renderMode') -and -not [string]::IsNullOrWhiteSpace([string]$source.renderMode)) {
            return $true
        }
    }

    return $false
}

function Get-StructuredValuePolicy {
    param(
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinition,
        [Parameter(Mandatory = $false)][string]$RenderMode
    )

    foreach ($source in @($ProjectionDefinition, $RenderHint)) {
        if ($null -eq $source) { continue }
        foreach ($key in @('structuredValuePolicy', 'missingProjectionPolicy')) {
            if ((Test-MapHasKey -Map $source -Key $key) -and -not [string]::IsNullOrWhiteSpace([string]$source[$key])) {
                return [string]$source[$key]
            }
        }
    }

    if ($RenderMode -eq 'table') {
        return 'blank'
    }

    return 'placeholder'
}

function New-RenderIssueRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$PathValue
    )

    return [ordered]@{ code = $Code; severity = $Severity; message = $Message; path = $PathValue }
}

function Add-RenderIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$PathValue
    )

    if ($null -ne $script:issues) {
        $script:issues.Add((New-RenderIssueRecord -Code $Code -Severity $Severity -Message $Message -PathValue $PathValue))
    }
    if ($Severity -eq 'ERROR') {
        $script:status = 'ERROR'
    }
}

function Get-StructuredValuePlaceholder {
    param(
        [Parameter(Mandatory = $true)][string]$RenderMode,
        [Parameter(Mandatory = $true)][string]$Policy
    )

    if ($Policy -eq 'blank') {
        return ''
    }

    switch ($RenderMode) {
        'table' { return '[table data omitted: projection required]' }
        'diagram' { return '[diagram omitted: diagram contract required]' }
        'json-evidence' { return '[json evidence omitted]' }
        'json-debug' { return '[debug json omitted]' }
        default { return '[structured value omitted]' }
    }
}

function Get-EffectiveSelectorsForMapping {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$MappingEntry,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DatasetPresentation
    )

    $selectorsInput = $null
    if (Test-MapHasKey -Map $MappingEntry -Key 'selectors') {
        $selectorsInput = $MappingEntry['selectors']
    }

    $selectors = @(ConvertTo-ObjectArray -InputObject $selectorsInput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if (@($selectors).Count -gt 0) {
        return @($selectors)
    }

    $defaultItemRoot = ''
    if ($null -ne $DatasetPresentation -and (Test-MapHasKey -Map $DatasetPresentation -Key 'defaultItemRoot') -and -not [string]::IsNullOrWhiteSpace([string]$DatasetPresentation['defaultItemRoot'])) {
        $defaultItemRoot = [string]$DatasetPresentation['defaultItemRoot']
    }

    if ($null -ne $RenderHint) {
        $renderAs = if (Test-MapHasKey -Map $RenderHint -Key 'renderAs') { [string]$RenderHint['renderAs'] } else { '' }
        $projectionRef = if (Test-MapHasKey -Map $RenderHint -Key 'projectionRef') { [string]$RenderHint['projectionRef'] } else { '' }
        $diagramRef = if (Test-MapHasKey -Map $RenderHint -Key 'diagramRef') { [string]$RenderHint['diagramRef'] } else { '' }
        $view = if (Test-MapHasKey -Map $RenderHint -Key 'view') { [string]$RenderHint['view'] } else { '' }
        if (
            $renderAs -eq 'table' -or
            $renderAs -eq 'diagram' -or
            -not [string]::IsNullOrWhiteSpace($projectionRef) -or
            -not [string]::IsNullOrWhiteSpace($diagramRef) -or
            -not [string]::IsNullOrWhiteSpace($view)
        ) {
            if (-not [string]::IsNullOrWhiteSpace($defaultItemRoot)) {
                return @($defaultItemRoot)
            }
            return @('items')
        }
    }

    return @()
}

function Get-ProjectionDefinitionForMapping {
    param(
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinitions,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionAliases
    )

    if ($null -ne $RenderHint) {
        foreach ($hintKey in @('projectionRef', 'view')) {
            if ((Test-MapHasKey -Map $RenderHint -Key $hintKey) -and -not [string]::IsNullOrWhiteSpace([string]$RenderHint[$hintKey])) {
                $projectionTag = [string]$RenderHint[$hintKey]
                $definition = Get-ProjectionDefinitionForTag -Tag $projectionTag -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases
                if ($null -ne $definition) {
                    return $definition
                }
            }
        }
    }

    return Get-ProjectionDefinitionForTag -Tag $Tag -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases
}

function Test-ProjectionContractJsonArrayShape {
    param([Parameter(Mandatory = $true)][string]$JsonText)

    $projectionContract = $JsonText | ConvertFrom-Json -AsHashtable
    if (-not ($projectionContract -is [System.Collections.IDictionary]) -or -not (Test-MapHasKey -Map $projectionContract -Key 'projections')) {
        return [ordered]@{ isValid = $true; message = $null }
    }

    foreach ($projectionTag in @($projectionContract.projections.Keys)) {
        $projection = $projectionContract.projections[[string]$projectionTag]
        if (-not ($projection -is [System.Collections.IDictionary])) { continue }

        foreach ($propertyName in @('filter', 'columns', 'rowOrder')) {
            if ((Test-MapHasKey -Map $projection -Key $propertyName) -and $null -ne $projection[$propertyName] -and -not ($projection[$propertyName] -is [System.Collections.IList])) {
                return [ordered]@{
                    isValid = $false
                    message = "Projection '$projectionTag' property '$propertyName' must serialize as a JSON array."
                }
            }
        }
    }

    return [ordered]@{ isValid = $true; message = $null }
}


function ConvertTo-ObjectArray {
    param([Parameter(Mandatory = $false)]$InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Array]) { return @($InputObject) }
    if ($InputObject -is [System.Collections.IList]) { return @($InputObject) }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string]) -and -not ($InputObject -is [System.Collections.IDictionary])) {
        return @($InputObject)
    }

    return @($InputObject)
}

function Normalize-ProjectionDefinition {
    param([Parameter(Mandatory = $false)]$Definition)

    if ($null -eq $Definition) { return $null }
    if (-not ($Definition -is [System.Collections.IDictionary])) {
        throw 'Projection definition must deserialize to an object.'
    }

    $normalized = [ordered]@{}
    foreach ($key in @($Definition.Keys)) {
        switch ([string]$key) {
            'filter' {
                $normalized.filter = @(ConvertTo-ObjectArray -InputObject $Definition[$key] | Where-Object { $null -ne $_ })
            }
            'columns' {
                $normalized.columns = @(ConvertTo-ObjectArray -InputObject $Definition[$key] | Where-Object { $null -ne $_ })
            }
            'rowOrder' {
                $normalized.rowOrder = @(ConvertTo-ObjectArray -InputObject $Definition[$key] | Where-Object { $null -ne $_ })
            }
            default {
                $normalized[[string]$key] = $Definition[$key]
            }
        }
    }

    if (-not $normalized.Contains('filter')) { $normalized.filter = @() }
    if (-not $normalized.Contains('columns')) { $normalized.columns = @() }
    if (-not $normalized.Contains('rowOrder')) { $normalized.rowOrder = @() }
    if (-not $normalized.Contains('renderMode')) {
        if (@($normalized.columns).Count -gt 0) {
            $normalized.renderMode = 'table'
        }
        else {
            $normalized.renderMode = 'scalar'
        }
    }
    return $normalized
}

function Read-ProjectionContractFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Read-JsonFile -Path $Path
    return (ConvertTo-PlainHashtable -InputObject $raw)
}

function Resolve-ProjectionContractPath {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $relativePath = [System.IO.Path]::Combine('tech', $TechId, 'assembler.projections.v1.json').Replace('\', '/')
    $candidate = Join-Path (Join-Path (Join-Path $ContractsRoot 'tech') $TechId) 'assembler.projections.v1.json'

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    throw "Missing required projection contract for tech '$TechId'. Expected synced runtime dependency at '$relativePath' under ContractsRoot '$ContractsRoot'. Contracts sync is incomplete; sync '$relativePath' into .deps/contracts outside this repo and rerun."
}

$script:ProjectionDefinitionsCache = @{}
$script:ProjectionAliasesCache = @{}
$script:DiagramDefinitionsCache = @{}
$script:DiagramAliasesCache = @{}
$script:DiagramInputRowsCache = @{}

function Get-ProjectionDefinitions {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $cacheKey = "$ContractsRoot|$TechId"
    if (Test-MapHasKey -Map $script:ProjectionDefinitionsCache -Key $cacheKey) {
        return $script:ProjectionDefinitionsCache[$cacheKey]
    }

    $projectionContractPath = Resolve-ProjectionContractPath -ContractsRoot $ContractsRoot -TechId $TechId
    $contract = Read-ProjectionContractFile -Path $projectionContractPath
    $definitions = @{}
    $aliases = @{}
    if ($contract -is [System.Collections.IDictionary]) {
        if (Test-MapHasKey -Map $contract -Key 'projections') {
            if ($contract.projections -is [System.Collections.IDictionary]) {
                foreach ($projectionTag in @($contract.projections.Keys)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$projectionTag)) {
                        $definitions[[string]$projectionTag] = Normalize-ProjectionDefinition -Definition $contract.projections[$projectionTag]
                    }
                }
            }
            elseif ($contract.projections -is [System.Collections.IList]) {
                foreach ($projection in @($contract.projections)) {
                    if ($projection -is [System.Collections.IDictionary] -and (Test-MapHasKey -Map $projection -Key 'sdtTag') -and -not [string]::IsNullOrWhiteSpace([string]$projection.sdtTag)) {
                        $definition = @{}
                        foreach ($key in @($projection.Keys)) {
                            if ([string]$key -ne 'sdtTag') {
                                $definition[[string]$key] = $projection[$key]
                            }
                        }
                        $definitions[[string]$projection.sdtTag] = Normalize-ProjectionDefinition -Definition $definition
                    }
                }
            }
        }

        if ((Test-MapHasKey -Map $contract -Key 'aliases') -and $contract.aliases -is [System.Collections.IDictionary]) {
            foreach ($aliasTag in @($contract.aliases.Keys)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$aliasTag)) {
                    $aliases[[string]$aliasTag] = [string]$contract.aliases[$aliasTag]
                }
            }
        }
    }

    $script:ProjectionDefinitionsCache[$cacheKey] = $definitions
    $script:ProjectionAliasesCache[$cacheKey] = $aliases
    return $definitions
}

function Get-ProjectionAliases {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $cacheKey = "$ContractsRoot|$TechId"
    if (-not (Test-MapHasKey -Map $script:ProjectionAliasesCache -Key $cacheKey)) {
        $null = Get-ProjectionDefinitions -ContractsRoot $ContractsRoot -TechId $TechId
    }

    if (Test-MapHasKey -Map $script:ProjectionAliasesCache -Key $cacheKey) {
        return $script:ProjectionAliasesCache[$cacheKey]
    }

    return @{}
}

function Read-DiagramContractFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Read-JsonFile -Path $Path
    return (ConvertTo-PlainHashtable -InputObject $raw)
}

function Resolve-DiagramContractPath {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $candidate = Join-Path (Join-Path (Join-Path $ContractsRoot 'tech') $TechId) 'assembler.diagrams.v1.json'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    return $null
}

function Get-DiagramDefinitions {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $cacheKey = "$ContractsRoot|$TechId"
    if (Test-MapHasKey -Map $script:DiagramDefinitionsCache -Key $cacheKey) {
        return $script:DiagramDefinitionsCache[$cacheKey]
    }

    $definitions = @{}
    $aliases = @{}
    $diagramContractPath = Resolve-DiagramContractPath -ContractsRoot $ContractsRoot -TechId $TechId
    if (-not [string]::IsNullOrWhiteSpace($diagramContractPath)) {
        $contract = Read-DiagramContractFile -Path $diagramContractPath
        if ($contract -is [System.Collections.IDictionary]) {
            if ((Test-MapHasKey -Map $contract -Key 'diagrams') -and $contract.diagrams -is [System.Collections.IDictionary]) {
                foreach ($diagramTag in @($contract.diagrams.Keys)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$diagramTag)) {
                        $definitions[[string]$diagramTag] = $contract.diagrams[$diagramTag]
                    }
                }
            }

            if ((Test-MapHasKey -Map $contract -Key 'aliases') -and $contract.aliases -is [System.Collections.IDictionary]) {
                foreach ($aliasTag in @($contract.aliases.Keys)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$aliasTag)) {
                        $aliases[[string]$aliasTag] = [string]$contract.aliases[$aliasTag]
                    }
                }
            }
        }
    }

    $script:DiagramDefinitionsCache[$cacheKey] = $definitions
    $script:DiagramAliasesCache[$cacheKey] = $aliases
    return $definitions
}

function Get-DiagramAliases {
    param(
        [Parameter(Mandatory = $true)][string]$ContractsRoot,
        [Parameter(Mandatory = $true)][string]$TechId
    )

    $cacheKey = "$ContractsRoot|$TechId"
    if (-not (Test-MapHasKey -Map $script:DiagramAliasesCache -Key $cacheKey)) {
        $null = Get-DiagramDefinitions -ContractsRoot $ContractsRoot -TechId $TechId
    }

    if (Test-MapHasKey -Map $script:DiagramAliasesCache -Key $cacheKey) {
        return $script:DiagramAliasesCache[$cacheKey]
    }

    return @{}
}

function Get-DiagramDefinitionForTag {
    param(
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DiagramDefinitions,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DiagramAliases
    )

    if ($null -eq $DiagramDefinitions -or [string]::IsNullOrWhiteSpace($Tag)) {
        return $null
    }

    if (Test-MapHasKey -Map $DiagramDefinitions -Key $Tag) {
        return $DiagramDefinitions[$Tag]
    }

    if ($null -ne $DiagramAliases -and (Test-MapHasKey -Map $DiagramAliases -Key $Tag)) {
        $resolvedTag = [string]$DiagramAliases[$Tag]
        if (Test-MapHasKey -Map $DiagramDefinitions -Key $resolvedTag) {
            return $DiagramDefinitions[$resolvedTag]
        }
    }

    return $null
}

function Resolve-DiagramDefinitionForMapping {
    param(
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DiagramDefinitions,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DiagramAliases
    )

    if ($null -ne $RenderHint -and (Test-MapHasKey -Map $RenderHint -Key 'diagramRef') -and -not [string]::IsNullOrWhiteSpace([string]$RenderHint.diagramRef)) {
        return Get-DiagramDefinitionForTag -Tag ([string]$RenderHint.diagramRef) -DiagramDefinitions $DiagramDefinitions -DiagramAliases $DiagramAliases
    }

    return Get-DiagramDefinitionForTag -Tag $Tag -DiagramDefinitions $DiagramDefinitions -DiagramAliases $DiagramAliases
}

function Get-DiagramRowFieldValue {
    param(
        [Parameter(Mandatory = $false)]$Row,
        [Parameter(Mandatory = $false)][string]$Field
    )

    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Field)) { return $null }

    $current = $Row
    foreach ($segment in @($Field -split '\.')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        if ($null -eq $current) { return $null }

        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
            continue
        }

        $property = $current.PSObject.Properties[[string]$segment]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }

    return $current
}

function Expand-DiagramTemplate {
    param(
        [Parameter(Mandatory = $false)][string]$Template,
        [Parameter(Mandatory = $false)]$Row
    )

    if ([string]::IsNullOrWhiteSpace($Template)) { return '' }

    return [regex]::Replace($Template, '\{([^{}]+)\}', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $fieldName = [string]$match.Groups[1].Value
        $value = Get-DiagramRowFieldValue -Row $Row -Field $fieldName
        if ($null -eq $value) { return '' }
        return [string]$value
    })
}

function Test-DiagramCondition {
    param(
        [Parameter(Mandatory = $false)]$Row,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$Condition
    )

    if ($null -eq $Condition) { return $true }
    if ((Test-MapHasKey -Map $Condition -Key 'field') -and (Test-MapHasKey -Map $Condition -Key 'equals')) {
        $actual = Get-DiagramRowFieldValue -Row $Row -Field ([string]$Condition.field)
        return ([string]$actual -eq [string]$Condition.equals)
    }

    throw 'Diagram condition supports only field/equals in v1.'
}

function Resolve-DiagramInputRows {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$InputDefinition,
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $false)][string]$CurrentDatasetPath
    )

    $datasetName = if (Test-MapHasKey -Map $InputDefinition -Key 'dataset') { [string]$InputDefinition.dataset } else { '' }
    if ([string]::IsNullOrWhiteSpace($datasetName)) {
        throw 'Diagram input is missing required dataset property.'
    }

    $rootSelector = if ((Test-MapHasKey -Map $InputDefinition -Key 'root') -and -not [string]::IsNullOrWhiteSpace([string]$InputDefinition.root)) { [string]$InputDefinition.root } else { 'items' }
    $currentDatasetDirectory = ''
    if (-not [string]::IsNullOrWhiteSpace($CurrentDatasetPath)) {
        $currentDatasetDirectory = Split-Path -Path $CurrentDatasetPath -Parent
    }

    $cacheKey = "$BundleRoot|$TechId|$currentDatasetDirectory|$datasetName|$rootSelector"
    if (Test-MapHasKey -Map $script:DiagramInputRowsCache -Key $cacheKey) {
        return @($script:DiagramInputRowsCache[$cacheKey])
    }

    $datasetResolution = Resolve-DatasetFilePath -BundleRoot $BundleRoot -DatasetRelativePath $datasetName -TechId $TechId
    $datasetPath = [string]$datasetResolution.path
    if (-not (Test-Path -LiteralPath $datasetPath -PathType Leaf)) {
        $candidatePaths = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($currentDatasetDirectory)) {
            [void]$candidatePaths.Add((Join-Path $currentDatasetDirectory $datasetName))
            [void]$candidatePaths.Add((Join-Path $currentDatasetDirectory ($datasetName + '.json')))
        }
        [void]$candidatePaths.Add((Join-Path $BundleRoot ($datasetName + '.json')))
        [void]$candidatePaths.Add((Join-Path (Join-Path $BundleRoot 'datasets') ($datasetName + '.json')))
        $resolvedCandidate = @($candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
        if (@($resolvedCandidate).Count -gt 0) {
            $datasetPath = [string]$resolvedCandidate[0]
        }
        else {
            throw "Diagram input dataset '$datasetName' was not found at '$datasetPath'."
        }
    }

    $dataset = Read-JsonFile -Path $datasetPath
    $selection = Resolve-SelectorWithSummaryCompatibility -Dataset $dataset -Selectors @($rootSelector) -DatasetPath $datasetPath
    if ([bool]$selection.selectorFailed) {
        throw "Diagram input selector '$rootSelector' did not resolve for dataset '$datasetName'."
    }

    $rows = @(ConvertTo-ObjectArray -InputObject $selection.value)
    $script:DiagramInputRowsCache[$cacheKey] = @($rows)
    return @($rows)
}

function Resolve-DiagramInputs {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$DiagramDefinition,
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $false)][string]$CurrentDatasetPath
    )

    $resolvedInputs = @{}
    if (-not ((Test-MapHasKey -Map $DiagramDefinition -Key 'inputs') -and $DiagramDefinition.inputs -is [System.Collections.IDictionary])) {
        throw 'Diagram definition is missing required inputs object.'
    }

    foreach ($inputName in @($DiagramDefinition.inputs.Keys)) {
        $inputDefinition = $DiagramDefinition.inputs[$inputName]
        if (-not ($inputDefinition -is [System.Collections.IDictionary])) { continue }

        $required = if (Test-MapHasKey -Map $inputDefinition -Key 'required') { [bool]$inputDefinition.required } else { $true }
        try {
            $resolvedInputs[[string]$inputName] = @(Resolve-DiagramInputRows -InputDefinition $inputDefinition -BundleRoot $BundleRoot -TechId $TechId -CurrentDatasetPath $CurrentDatasetPath)
        }
        catch {
            if ($required) {
                throw
            }
            $resolvedInputs[[string]$inputName] = @()
        }
    }

    return $resolvedInputs
}

function ConvertTo-DiagramNodeModel {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$NodeSet,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Inputs
    )

    $inputName = if (Test-MapHasKey -Map $NodeSet -Key 'input') { [string]$NodeSet.input } else { '' }
    if ([string]::IsNullOrWhiteSpace($inputName) -or -not (Test-MapHasKey -Map $Inputs -Key $inputName)) {
        throw "Diagram node set '$([string]$NodeSet.name)' references unknown input '$inputName'."
    }

    $nodes = @()
    foreach ($row in @($Inputs[$inputName])) {
        if ((Test-MapHasKey -Map $NodeSet -Key 'where') -and -not (Test-DiagramCondition -Row $row -Condition $NodeSet.where)) {
            continue
        }

        $id = Expand-DiagramTemplate -Template ([string]$NodeSet.id) -Row $row
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $label = Expand-DiagramTemplate -Template ([string]$NodeSet.label) -Row $row
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $id }

        $fieldLines = @()
        foreach ($fieldDefinition in @(ConvertTo-ObjectArray -InputObject $NodeSet.fields)) {
            if (-not ($fieldDefinition -is [System.Collections.IDictionary])) { continue }
            $fieldLabel = if (Test-MapHasKey -Map $fieldDefinition -Key 'label') { [string]$fieldDefinition.label } else { [string]$fieldDefinition.field }
            $fieldValue = if (Test-MapHasKey -Map $fieldDefinition -Key 'value') {
                Expand-DiagramTemplate -Template ([string]$fieldDefinition.value) -Row $row
            }
            else {
                [string](Get-DiagramRowFieldValue -Row $row -Field ([string]$fieldDefinition.field))
            }
            if ([string]::IsNullOrWhiteSpace($fieldValue)) { continue }
            $fieldLines += ("{0}: {1}" -f $fieldLabel, $fieldValue)
        }

        $groupValue = ''
        if ((Test-MapHasKey -Map $NodeSet -Key 'groupBy') -and -not [string]::IsNullOrWhiteSpace([string]$NodeSet.groupBy)) {
            $groupValue = [string](Get-DiagramRowFieldValue -Row $row -Field ([string]$NodeSet.groupBy))
        }

        $nodes += [pscustomobject]@{
            id = $id
            label = $label
            fields = @($fieldLines)
            group = $groupValue
            shape = if (Test-MapHasKey -Map $NodeSet -Key 'shape') { [string]$NodeSet.shape } else { 'rectangle' }
            fillColor = if (Test-MapHasKey -Map $NodeSet -Key 'fillColor') { [string]$NodeSet.fillColor } else { '#EAF2F8' }
        }
    }

    return @($nodes)
}

function ConvertTo-DiagramEdgeModel {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$EdgeSet,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Inputs
    )

    $inputName = if (Test-MapHasKey -Map $EdgeSet -Key 'input') { [string]$EdgeSet.input } else { '' }
    if ([string]::IsNullOrWhiteSpace($inputName) -or -not (Test-MapHasKey -Map $Inputs -Key $inputName)) {
        throw "Diagram edge set references unknown input '$inputName'."
    }

    $edges = @()
    foreach ($row in @($Inputs[$inputName])) {
        if ((Test-MapHasKey -Map $EdgeSet -Key 'where') -and -not (Test-DiagramCondition -Row $row -Condition $EdgeSet.where)) {
            continue
        }

        $from = Expand-DiagramTemplate -Template ([string]$EdgeSet.from) -Row $row
        $to = Expand-DiagramTemplate -Template ([string]$EdgeSet.to) -Row $row
        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }

        $edges += [pscustomobject]@{
            from = $from
            to = $to
            label = if (Test-MapHasKey -Map $EdgeSet -Key 'label') { Expand-DiagramTemplate -Template ([string]$EdgeSet.label) -Row $row } else { '' }
        }
    }

    return @($edges)
}

function ConvertTo-SvgEscapedText {
    param([Parameter(Mandatory = $false)]$Value)

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-DiagramNodeFieldMap {
    param([Parameter(Mandatory = $true)]$Node)

    $fieldMap = @{}
    foreach ($fieldLine in @($Node.fields)) {
        $line = [string]$fieldLine
        $separatorIndex = $line.IndexOf(':')
        if ($separatorIndex -lt 0) { continue }
        $name = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $fieldMap[$name] = $value
        }
    }
    return $fieldMap
}

function Get-DiagramSpeedLabel {
    param([Parameter(Mandatory = $false)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value -replace '^speed', '') -replace 'gig', 'G' -replace 'Unknown', 'Unknown')
}

function Get-DiagramStatusColor {
    param([Parameter(Mandatory = $false)][string]$Value)

    switch ([string]$Value) {
        'up' { return '#157347' }
        'optimal' { return '#157347' }
        'down' { return '#B42318' }
        default { return '#59636E' }
    }
}

function New-DiagramSvgStatusPill {
    param(
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $false)][string]$Status
    )

    $color = Get-DiagramStatusColor -Value $Status
    $escapedStatus = ConvertTo-SvgEscapedText -Value $Status
    return "<rect x='$X' y='$Y' width='52' height='18' rx='9' fill='$color'/><text x='$($X + 26)' y='$($Y + 13)' text-anchor='middle' class='pillText'>$escapedStatus</text>"
}

function New-DenseControllerRowsSvgImage {
    param(
        [Parameter(Mandatory = $true)][object[]]$Nodes,
        [Parameter(Mandatory = $true)][object[]]$Edges,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $edgeSourceIds = @{}
    foreach ($edge in @($Edges)) {
        $edgeSourceIds[[string]$edge.from] = $true
    }

    $style = @"
<style>
  .bg { fill: #ffffff; }
  .title { font: 700 22px Segoe UI, Arial, sans-serif; fill: #111827; }
  .subtitle { font: 12px Segoe UI, Arial, sans-serif; fill: #6B7280; }
  .cardTitle { font: 700 18px Segoe UI, Arial, sans-serif; fill: #111827; }
  .value { font: 13px Segoe UI, Arial, sans-serif; fill: #111827; }
  .cell { font: 12px Segoe UI, Arial, sans-serif; fill: #111827; }
  .mono { font-family: Consolas, 'Segoe UI Mono', monospace; }
  .strong { font-weight: 700; }
  .pillText { font: 700 10px Segoe UI, Arial, sans-serif; fill: #fff; }
</style>
"@

    $rowGroups = [System.Collections.Generic.List[string]]::new()
    $y = 92
    foreach ($group in @($Nodes | Group-Object -Property group | Sort-Object Name)) {
        $groupName = if ([string]::IsNullOrWhiteSpace([string]$group.Name)) { 'Controller' } else { [string]$group.Name }
        $groupNodes = @($group.Group)
        $controllerNode = @($groupNodes | Where-Object { Test-MapHasKey -Map $edgeSourceIds -Key ([string]$_.id) } | Select-Object -First 1)
        $interfaceNodes = @($groupNodes | Where-Object { -not (Test-MapHasKey -Map $edgeSourceIds -Key ([string]$_.id)) })
        $controllerFields = if ($null -ne $controllerNode) { Get-DiagramNodeFieldMap -Node $controllerNode } else { @{} }
        $model = if (Test-MapHasKey -Map $controllerFields -Key 'Model') { [string]$controllerFields.Model } else { '' }
        $tray = if (Test-MapHasKey -Map $controllerFields -Key 'Tray') { [string]$controllerFields.Tray } else { '' }
        $serial = if (Test-MapHasKey -Map $controllerFields -Key 'Serial') { [string]$controllerFields.Serial } else { '' }
        $status = if (Test-MapHasKey -Map $controllerFields -Key 'Status') { [string]$controllerFields.Status } else { '' }

        [void]$rowGroups.Add("<g transform='translate(56,$y)'>")
        [void]$rowGroups.Add("<rect x='0' y='0' width='1088' height='166' rx='10' fill='#F8FAFC' stroke='#CBD5E1'/>")
        [void]$rowGroups.Add("<rect x='0' y='0' width='180' height='166' rx='10' fill='#E8F1FF' stroke='#CBD5E1'/>")
        [void]$rowGroups.Add("<text x='22' y='34' class='cardTitle'>Controller $(ConvertTo-SvgEscapedText -Value $groupName)</text>")
        [void]$rowGroups.Add("<text x='22' y='62' class='value'>$(ConvertTo-SvgEscapedText -Value $model) / Tray $(ConvertTo-SvgEscapedText -Value $tray)</text>")
        [void]$rowGroups.Add("<text x='22' y='86' class='value mono'>$(ConvertTo-SvgEscapedText -Value $serial)</text>")
        [void]$rowGroups.Add("<text x='22' y='118' class='value' fill='$(Get-DiagramStatusColor -Value $status)'>$(ConvertTo-SvgEscapedText -Value $status)</text>")

        $px = 210
        $py = 24
        foreach ($interfaceNode in @($interfaceNodes | Sort-Object -Property label)) {
            $fields = Get-DiagramNodeFieldMap -Node $interfaceNode
            $transport = if (Test-MapHasKey -Map $fields -Key 'Transport') { [string]$fields.Transport } else { '' }
            $link = if (Test-MapHasKey -Map $fields -Key 'Link') { [string]$fields.Link } else { '' }
            $address = if (Test-MapHasKey -Map $fields -Key 'IPv4') { [string]$fields['IPv4'] } else { '' }
            $speed = if (Test-MapHasKey -Map $fields -Key 'Speed') { Get-DiagramSpeedLabel -Value ([string]$fields.Speed) } else { '' }
            $isManagement = Test-MapHasKey -Map $fields -Key 'Port'
            if ($isManagement) { continue }

            [void]$rowGroups.Add("<rect x='$px' y='$py' width='132' height='52' rx='8' fill='#ECFDF3' stroke='#86EFAC'/>")
            [void]$rowGroups.Add("<text x='$($px + 10)' y='$($py + 18)' class='cell strong'>$(ConvertTo-SvgEscapedText -Value $interfaceNode.label)</text>")
            [void]$rowGroups.Add("<text x='$($px + 10)' y='$($py + 36)' class='cell mono'>$(ConvertTo-SvgEscapedText -Value $address)</text>")
            [void]$rowGroups.Add((New-DiagramSvgStatusPill -X ($px + 72) -Y ($py + 6) -Status $link))
            $px += 142
            if ($px -gt 980) {
                $px = 210
                $py += 64
            }
        }

        foreach ($interfaceNode in @($interfaceNodes | Sort-Object -Property label)) {
            $fields = Get-DiagramNodeFieldMap -Node $interfaceNode
            if (-not (Test-MapHasKey -Map $fields -Key 'Port')) { continue }
            $address = if (Test-MapHasKey -Map $fields -Key 'IPv4') { [string]$fields['IPv4'] } else { '' }
            [void]$rowGroups.Add("<rect x='920' y='96' width='142' height='46' rx='8' fill='#FFF7ED' stroke='#FDBA74'/>")
            [void]$rowGroups.Add("<text x='932' y='116' class='cell strong'>Mgmt $(ConvertTo-SvgEscapedText -Value $interfaceNode.label)</text>")
            [void]$rowGroups.Add("<text x='932' y='134' class='cell mono'>$(ConvertTo-SvgEscapedText -Value $address)</text>")
        }

        [void]$rowGroups.Add('</g>')
        $y += 194
    }

    $height = [Math]::Max(510, $y + 32)
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="$height" viewBox="0 0 1200 $height">
$style
<rect class="bg" width="1200" height="$height"/>
<text x="56" y="46" class="title">Host Port Topology</text>
<text x="56" y="68" class="subtitle">Dense controller rows intended for DOCX page width</text>
$(@($rowGroups) -join "`n")
</svg>
"@

    $svgBytes = [System.Text.Encoding]::UTF8.GetBytes($svg)
    return [ordered]@{
        imageBase64 = [Convert]::ToBase64String($svgBytes)
        imageFormat = 'svg'
        width = 1200
        height = $height
    }
}

function New-DiagrammerCoreTopologyImage {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$DiagramDefinition,
        [Parameter(Mandatory = $true)][object[]]$Nodes,
        [Parameter(Mandatory = $true)][object[]]$Edges,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    if ($env:ASSEMBLER_DISABLE_DIAGRAMMER_CORE -eq '1') {
        throw 'Diagrammer.Core has been disabled for this process.'
    }

    $module = Get-Module -ListAvailable -Name Diagrammer.Core | Select-Object -First 1
    if ($null -eq $module) {
        throw 'Diagrammer.Core PowerShell module is not installed.'
    }

    Import-Module Diagrammer.Core -ErrorAction Stop | Out-Null

    $layout = if ((Test-MapHasKey -Map $DiagramDefinition -Key 'layout') -and $DiagramDefinition.layout -is [System.Collections.IDictionary]) { $DiagramDefinition.layout } else { @{} }
    $title = if ((Test-MapHasKey -Map $layout -Key 'title') -and -not [string]::IsNullOrWhiteSpace([string]$layout.title)) { [string]$layout.title } else { [string]$Tag }
    $direction = if ((Test-MapHasKey -Map $layout -Key 'direction') -and [string]$layout.direction -eq 'left-to-right') { 'left-to-right' } else { 'top-to-bottom' }
    $mainGraphSize = if ((Test-MapHasKey -Map $layout -Key 'size') -and -not [string]::IsNullOrWhiteSpace([string]$layout.size)) { [string]$layout.size } else { $null }
    $layoutStyle = if ((Test-MapHasKey -Map $layout -Key 'style') -and -not [string]::IsNullOrWhiteSpace([string]$layout.style)) { [string]$layout.style } else { 'node-link' }

    $safeNodeNames = @{}
    $nodeIndex = 1
    foreach ($node in @($Nodes)) {
        $sourceNodeId = [string]$node.id
        if ([string]::IsNullOrWhiteSpace($sourceNodeId) -or (Test-MapHasKey -Map $safeNodeNames -Key $sourceNodeId)) { continue }
        $safeNodeNames[$sourceNodeId] = "diagram_node_$nodeIndex"
        $nodeIndex++
    }

    $graphInput = & {
        if ($layoutStyle -eq 'group-summary') {
            $edgeSourceIds = @{}
            foreach ($edge in @($Edges)) {
                $edgeSourceIds[[string]$edge.from] = $true
            }

            $summaryIndex = 1
            $summaryNodeNames = [System.Collections.Generic.List[string]]::new()
            foreach ($group in @($Nodes | Group-Object -Property group)) {
                $groupName = [string]$group.Name
                if ([string]::IsNullOrWhiteSpace($groupName)) { $groupName = "Group $summaryIndex" }
                $groupNodes = @($group.Group)
                $sourceNodes = @($groupNodes | Where-Object { Test-MapHasKey -Map $edgeSourceIds -Key ([string]$_.id) })
                $detailNodes = @($groupNodes | Where-Object { -not (Test-MapHasKey -Map $edgeSourceIds -Key ([string]$_.id)) })

                $labelLines = [System.Collections.Generic.List[string]]::new()
                [void]$labelLines.Add($groupName)
                foreach ($node in @($sourceNodes)) {
                    [void]$labelLines.Add('')
                    [void]$labelLines.Add([string]$node.label)
                    foreach ($fieldLine in @($node.fields)) {
                        [void]$labelLines.Add("  $fieldLine")
                    }
                }
                if (@($detailNodes).Count -gt 0) {
                    [void]$labelLines.Add('')
                    [void]$labelLines.Add('Interfaces')
                    foreach ($node in @($detailNodes | Sort-Object -Property label)) {
                        $fieldSummary = @($node.fields | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' | '
                        if ([string]::IsNullOrWhiteSpace($fieldSummary)) {
                            [void]$labelLines.Add("  $([string]$node.label)")
                        }
                        else {
                            [void]$labelLines.Add("  $([string]$node.label): $fieldSummary")
                        }
                    }
                }

                $summaryNodeName = "diagram_group_$summaryIndex"
                Node -Name $summaryNodeName -Attributes @{ Label = (@($labelLines) -join "`n"); shape = 'rectangle'; fillColor = '#F8FAFC'; style = 'filled,rounded'; fontsize = 12 }
                [void]$summaryNodeNames.Add($summaryNodeName)
                $summaryIndex++
            }
            if ($direction -eq 'left-to-right' -and $summaryNodeNames.Count -gt 1) {
                for ($index = 0; $index -lt ($summaryNodeNames.Count - 1); $index++) {
                    Edge -From $summaryNodeNames[$index] -To $summaryNodeNames[$index + 1] -Attributes @{ style = 'invis'; weight = 10 }
                }
            }
            return
        }

        $emittedNodeIds = @{}
        foreach ($group in @($Nodes | Group-Object -Property group)) {
            $groupName = [string]$group.Name
            $groupNodes = @($group.Group)
            if ([string]::IsNullOrWhiteSpace($groupName)) {
                foreach ($node in @($groupNodes)) {
                    $nodeLabel = ([string]$node.label)
                    if (@($node.fields).Count -gt 0) { $nodeLabel = "$nodeLabel`n$(@($node.fields) -join "`n")" }
                    Node -Name ([string]$safeNodeNames[[string]$node.id]) -Attributes @{ Label = $nodeLabel; shape = [string]$node.shape; fillColor = [string]$node.fillColor; style = 'filled,rounded'; fontsize = 12 }
                    $emittedNodeIds[[string]$node.id] = $true
                }
                continue
            }

            $subgraphName = ('cluster_' + ([regex]::Replace($groupName, '[^A-Za-z0-9_]', '_')))
            SubGraph $subgraphName -Attributes @{ Label = $groupName; fontsize = 14; penwidth = 1.2; labelloc = 't'; style = 'dashed,rounded'; color = '#9AA4B2' } {
                foreach ($node in @($groupNodes)) {
                    $nodeLabel = ([string]$node.label)
                    if (@($node.fields).Count -gt 0) { $nodeLabel = "$nodeLabel`n$(@($node.fields) -join "`n")" }
                    Node -Name ([string]$safeNodeNames[[string]$node.id]) -Attributes @{ Label = $nodeLabel; shape = [string]$node.shape; fillColor = [string]$node.fillColor; style = 'filled,rounded'; fontsize = 12 }
                    $emittedNodeIds[[string]$node.id] = $true
                }
            }
        }

        foreach ($edge in @($Edges)) {
            if (-not (Test-MapHasKey -Map $safeNodeNames -Key ([string]$edge.from))) { continue }
            if (-not (Test-MapHasKey -Map $safeNodeNames -Key ([string]$edge.to))) { continue }
            $attributes = @{ fontsize = 10 }
            if (-not [string]::IsNullOrWhiteSpace([string]$edge.label)) { $attributes.Label = [string]$edge.label }
            Edge -From ([string]$safeNodeNames[[string]$edge.from]) -To ([string]$safeNodeNames[[string]$edge.to]) -Attributes $attributes
        }
    }

    $outputFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('assembler-diagram-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $outputFolder -ItemType Directory -Force
    try {
        $fileName = 'diagram'

        $diagrammerParameters = @{
            InputObject = $graphInput
            OutputFolderPath = $outputFolder
            Format = @('png')
            MainDiagramLabel = $title
            Filename = $fileName
            Direction = $direction
            DisableMainDiagramLogo = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($mainGraphSize)) {
            $diagrammerParameters.MainGraphSize = $mainGraphSize
        }

        New-Diagrammer @diagrammerParameters | Out-Null
        $pngPath = Join-Path $outputFolder "$fileName.png"
        if (-not (Test-Path -LiteralPath $pngPath -PathType Leaf)) {
            throw "Diagrammer.Core did not produce expected PNG '$pngPath'."
        }

        return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pngPath))
    }
    finally {
        if (Test-Path -LiteralPath $outputFolder -PathType Container) {
            Remove-Item -LiteralPath $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-DiagramRender {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DiagramDefinitions,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$DiagramAliases,
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$TechId,
        [Parameter(Mandatory = $false)][string]$CurrentDatasetPath
    )

    $diagramDefinition = Resolve-DiagramDefinitionForMapping -Tag $Tag -RenderHint $RenderHint -DiagramDefinitions $DiagramDefinitions -DiagramAliases $DiagramAliases
    $diagramRef = if ((Test-MapHasKey -Map $RenderHint -Key 'diagramRef') -and -not [string]::IsNullOrWhiteSpace([string]$RenderHint.diagramRef)) { [string]$RenderHint.diagramRef } else { [string]$Tag }
    if (-not $EnableDiagramRendering.IsPresent) {
        return [ordered]@{ placeholder = "[diagram disabled: $diagramRef]"; imageBase64 = ''; nodeCount = 0; edgeCount = 0; diagramRef = $diagramRef }
    }

    if ($null -eq $diagramDefinition) {
        Add-RenderIssue -Code 'ASB-ASM-SDT-DIAGRAM-UNKNOWN' -Severity 'ERROR' -Message "Tag '$Tag' declared diagram render mode but diagramRef '$diagramRef' was not found." -PathValue $script:currentDatasetPath
        return [ordered]@{ placeholder = "[diagram unavailable: $diagramRef]"; imageBase64 = ''; nodeCount = 0; edgeCount = 0; diagramRef = $diagramRef }
    }

    try {
        if ((Test-MapHasKey -Map $diagramDefinition -Key 'engine') -and [string]$diagramDefinition.engine -ne 'diagrammer.core') {
            throw "Unsupported diagram engine '$([string]$diagramDefinition.engine)'."
        }
        if ((Test-MapHasKey -Map $diagramDefinition -Key 'kind') -and [string]$diagramDefinition.kind -ne 'topology') {
            throw "Unsupported diagram kind '$([string]$diagramDefinition.kind)'."
        }
        if ($env:ASSEMBLER_DISABLE_DIAGRAMMER_CORE -eq '1') {
            throw 'Diagrammer.Core has been disabled for this process.'
        }
        $diagrammerCoreModule = Get-Module -ListAvailable -Name Diagrammer.Core | Select-Object -First 1
        if ($null -eq $diagrammerCoreModule) {
            throw 'Diagrammer.Core PowerShell module is not installed.'
        }

        $inputs = Resolve-DiagramInputs -DiagramDefinition $diagramDefinition -BundleRoot $BundleRoot -TechId $TechId -CurrentDatasetPath $CurrentDatasetPath
        $nodes = @()
        foreach ($nodeSet in @(ConvertTo-ObjectArray -InputObject $diagramDefinition.nodes)) {
            if ($nodeSet -is [System.Collections.IDictionary]) {
                $nodes += @(ConvertTo-DiagramNodeModel -NodeSet $nodeSet -Inputs $inputs)
            }
        }

        $edges = @()
        foreach ($edgeSet in @(ConvertTo-ObjectArray -InputObject $diagramDefinition.edges)) {
            if ($edgeSet -is [System.Collections.IDictionary]) {
                $edges += @(ConvertTo-DiagramEdgeModel -EdgeSet $edgeSet -Inputs $inputs)
            }
        }

        $nodeIds = @{}
        $dedupedNodes = @()
        foreach ($node in @($nodes)) {
            if (Test-MapHasKey -Map $nodeIds -Key ([string]$node.id)) { continue }
            $nodeIds[[string]$node.id] = $true
            $dedupedNodes += $node
        }

        $dedupedEdges = @()
        $edgeIds = @{}
        foreach ($edge in @($edges)) {
            if (-not (Test-MapHasKey -Map $nodeIds -Key ([string]$edge.from))) { continue }
            if (-not (Test-MapHasKey -Map $nodeIds -Key ([string]$edge.to))) { continue }
            $edgeId = "$($edge.from)|$($edge.to)|$($edge.label)"
            if (Test-MapHasKey -Map $edgeIds -Key $edgeId) { continue }
            $edgeIds[$edgeId] = $true
            $dedupedEdges += $edge
        }

        if (@($dedupedNodes).Count -eq 0) {
            throw "Diagram '$diagramRef' produced no nodes."
        }

        $layout = if ((Test-MapHasKey -Map $diagramDefinition -Key 'layout') -and $diagramDefinition.layout -is [System.Collections.IDictionary]) { $diagramDefinition.layout } else { @{} }
        $layoutStyle = if ((Test-MapHasKey -Map $layout -Key 'style') -and -not [string]::IsNullOrWhiteSpace([string]$layout.style)) { [string]$layout.style } else { 'node-link' }
        $diagramImage = if ($layoutStyle -eq 'dense-controller-rows') {
            New-DenseControllerRowsSvgImage -Nodes $dedupedNodes -Edges $dedupedEdges -Tag $Tag
        }
        else {
            [ordered]@{
                imageBase64 = (New-DiagrammerCoreTopologyImage -DiagramDefinition $diagramDefinition -Nodes $dedupedNodes -Edges $dedupedEdges -Tag $Tag)
                imageFormat = 'png'
                width = 0
                height = 0
            }
        }
        return [ordered]@{
            placeholder = "[diagram: $diagramRef; nodes=$(@($dedupedNodes).Count); edges=$(@($dedupedEdges).Count)]"
            imageBase64 = [string]$diagramImage.imageBase64
            imageFormat = [string]$diagramImage.imageFormat
            imageWidth = [int]$diagramImage.width
            imageHeight = [int]$diagramImage.height
            nodeCount = @($dedupedNodes).Count
            edgeCount = @($dedupedEdges).Count
            diagramRef = $diagramRef
        }
    }
    catch {
        Add-RenderIssue -Code 'ASB-ASM-SDT-DIAGRAM-RENDER-FAILED' -Severity 'ERROR' -Message "Diagram '$diagramRef' failed for tag '$Tag': $($_.Exception.Message)" -PathValue $script:currentDatasetPath
        return [ordered]@{ placeholder = "[diagram unavailable: $diagramRef]"; imageBase64 = ''; nodeCount = 0; edgeCount = 0; diagramRef = $diagramRef }
    }
}

function Get-ProjectionDefinitionForTag {
    param(
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinitions,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionAliases
    )

    if ($null -eq $ProjectionDefinitions -or [string]::IsNullOrWhiteSpace($Tag)) {
        return $null
    }

    if (Test-MapHasKey -Map $ProjectionDefinitions -Key $Tag) {
        return $ProjectionDefinitions[$Tag]
    }

    if ($null -ne $ProjectionAliases -and (Test-MapHasKey -Map $ProjectionAliases -Key $Tag)) {
        $projectionTag = [string]$ProjectionAliases[$Tag]
        if (Test-MapHasKey -Map $ProjectionDefinitions -Key $projectionTag) {
            return $ProjectionDefinitions[$projectionTag]
        }
    }

    return $null
}

function Test-ProjectionCondition {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Condition
    )

    if ((Test-MapHasKey -Map $Condition -Key 'anyOf') -and $Condition.anyOf -is [System.Collections.IList]) {
        foreach ($nested in @($Condition.anyOf)) {
            if (Test-ProjectionCondition -Row $Row -Condition $nested) { return $true }
        }
        return $false
    }

    if ((Test-MapHasKey -Map $Condition -Key 'allOf') -and $Condition.allOf -is [System.Collections.IList]) {
        foreach ($nested in @($Condition.allOf)) {
            if (-not (Test-ProjectionCondition -Row $Row -Condition $nested)) { return $false }
        }
        return $true
    }

    if (-not (Test-MapHasKey -Map $Condition -Key 'field')) {
        throw 'Projection condition is missing required field property.'
    }

    $actual = $Row.([string]$Condition.field)
    if (Test-MapHasKey -Map $Condition -Key 'equals') {
        return ([string]$actual -eq [string]$Condition.equals)
    }
    if (Test-MapHasKey -Map $Condition -Key 'notEquals') {
        return ([string]$actual -ne [string]$Condition.notEquals)
    }
    if (Test-MapHasKey -Map $Condition -Key 'isNull') {
        return (($null -eq $actual) -eq [bool]$Condition.isNull)
    }

    throw "Unsupported projection condition for field '$($Condition.field)'."
}

$script:ProjectionLookupRowsCache = @{}

function Resolve-ProjectionLookupDatasetPath {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Lookup,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    $lookupDataset = [string]$Lookup.dataset
    if ([string]::IsNullOrWhiteSpace($lookupDataset)) {
        throw 'Projection lookup is missing required dataset property.'
    }

    if ([System.IO.Path]::IsPathRooted($lookupDataset)) {
        return $lookupDataset
    }

    if ([string]::IsNullOrWhiteSpace($DatasetPath)) {
        throw "Projection lookup dataset '$lookupDataset' could not be resolved because the current dataset path is unavailable."
    }

    $datasetDirectory = Split-Path -Parent $DatasetPath
    if ([string]::IsNullOrWhiteSpace($datasetDirectory)) {
        throw "Projection lookup dataset '$lookupDataset' could not be resolved relative to '$DatasetPath'."
    }

    return (Join-Path $datasetDirectory $lookupDataset)
}

function Get-ProjectionLookupRows {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Lookup,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    $lookupDatasetPath = Resolve-ProjectionLookupDatasetPath -Lookup $Lookup -DatasetPath $DatasetPath
    $lookupSelector = if ((Test-MapHasKey -Map $Lookup -Key 'selector') -and -not [string]::IsNullOrWhiteSpace([string]$Lookup.selector)) { [string]$Lookup.selector } else { 'items' }
    $cacheKey = "$lookupDatasetPath|$lookupSelector"
    if (Test-MapHasKey -Map $script:ProjectionLookupRowsCache -Key $cacheKey) {
        return @($script:ProjectionLookupRowsCache[$cacheKey])
    }

    if (-not (Test-Path -LiteralPath $lookupDatasetPath -PathType Leaf)) {
        throw "Projection lookup dataset '$lookupDatasetPath' was not found."
    }

    $lookupDataset = Read-JsonFile -Path $lookupDatasetPath
    $lookupSelection = Resolve-Selector -InputObject $lookupDataset -Selector $lookupSelector
    if (-not [bool]$lookupSelection.found) {
        throw "Projection lookup selector '$lookupSelector' did not resolve for dataset '$lookupDatasetPath'."
    }

    $lookupRows = @(ConvertTo-ObjectArray -InputObject $lookupSelection.value)
    $script:ProjectionLookupRowsCache[$cacheKey] = @($lookupRows)
    return @($lookupRows)
}

function Resolve-ProjectionLookupValue {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Lookup,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    if ($null -eq $Value) { return $null }

    $lookupKeyField = [string]$Lookup.key
    $lookupValueField = [string]$Lookup.value
    if ([string]::IsNullOrWhiteSpace($lookupKeyField) -or [string]::IsNullOrWhiteSpace($lookupValueField)) {
        throw 'Projection lookup requires non-empty key and value properties.'
    }

    foreach ($lookupRow in @(Get-ProjectionLookupRows -Lookup $Lookup -DatasetPath $DatasetPath)) {
        $candidateKey = Get-ProjectionRowFieldValue -Row $lookupRow -Field $lookupKeyField
        if ($null -eq $candidateKey) { continue }

        if ([string]$candidateKey -eq [string]$Value) {
            $resolvedValue = Get-ProjectionRowFieldValue -Row $lookupRow -Field $lookupValueField
            if ($null -ne $resolvedValue -and -not [string]::IsNullOrWhiteSpace([string]$resolvedValue)) {
                return $resolvedValue
            }

            return $Value
        }
    }

    return $Value
}

function Resolve-ProjectionColumnValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Column,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    $value = $null
    if (Test-MapHasKey -Map $Column -Key 'source') {
        $sourceField = [string]$Column.source
        if ($Row -is [System.Collections.IDictionary]) {
            if ($Row.Contains($sourceField)) {
                $value = $Row[$sourceField]
            }
        }
        else {
            $property = $Row.PSObject.Properties[$sourceField]
            if ($null -ne $property) {
                $value = $property.Value
            }
        }
    }

    if ((Test-MapHasKey -Map $Column -Key 'lookup') -and $Column.lookup -is [System.Collections.IDictionary]) {
        $value = Resolve-ProjectionLookupValue -Value $value -Lookup $Column.lookup -DatasetPath $DatasetPath
    }

    if (Test-MapHasKey -Map $Column -Key 'format') {
        switch ([string]$Column.format) {
            'bytesHuman' { return (Format-SizeHuman -Bytes $value) }
            'percent' {
                if ($null -eq $value) { return '' }
                $text = [string]$value
                if ([string]::IsNullOrWhiteSpace($text)) { return '' }
                if ($text.Trim().EndsWith('%')) { return $text.Trim() }
                return ("$($text.Trim())%")
            }
            'join' {
                if ($null -eq $value) { return '' }
                $delimiter = if (Test-MapHasKey -Map $Column -Key 'delimiter') { [string]$Column.delimiter } else { ', ' }
                return (@($value) -join $delimiter)
            }
            default { throw "Unsupported projection column format '$([string]$Column.format)'." }
        }
    }

    return $value
}

function Get-ProjectionSortValue {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [datetime]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        return ((@($Value) | ForEach-Object { [string]$_ }) -join ', ')
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $text }

    [int64]$int64Value = 0
    if ([int64]::TryParse($text, [ref]$int64Value)) {
        return $int64Value
    }

    [double]$doubleValue = 0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) {
        return $doubleValue
    }

    [datetime]$dateValue = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dateValue)) {
        return $dateValue
    }

    return $text
}

function Get-ProjectionRowFieldValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string]$Field
    )

    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Field)) {
            return $Row[$Field]
        }
    }

    $property = $Row.PSObject.Properties[$Field]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-ProjectionRowOrder {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Definition)

    $rowOrder = @()
    if ((Test-MapHasKey -Map $Definition -Key 'rowOrder') -and @($Definition.rowOrder).Count -gt 0) {
        foreach ($entry in @($Definition.rowOrder)) {
            if ($entry -is [System.Collections.IDictionary]) {
                $fieldName = if (Test-MapHasKey -Map $entry -Key 'by') { [string]$entry.by } else { '' }
                if ([string]::IsNullOrWhiteSpace($fieldName)) { continue }

                $direction = if (Test-MapHasKey -Map $entry -Key 'direction') { [string]$entry.direction } else { '' }
                $directionNormalized = $direction.Trim().ToLowerInvariant()
                $rowOrder += [ordered]@{
                    by = $fieldName
                    descending = ($directionNormalized -eq 'desc' -or $directionNormalized -eq 'descending')
                }
                continue
            }

            $fieldName = [string]$entry
            if ([string]::IsNullOrWhiteSpace($fieldName)) { continue }
            $rowOrder += [ordered]@{
                by = $fieldName
                descending = $false
            }
        }
    }

    if (@($rowOrder).Count -gt 0) {
        return @($rowOrder)
    }

    if ((Test-MapHasKey -Map $Definition -Key 'sortBy') -and -not [string]::IsNullOrWhiteSpace([string]$Definition.sortBy)) {
        return @([ordered]@{
            by = [string]$Definition.sortBy
            descending = $false
        })
    }

    return @()
}

function Sort-ProjectionRows {
    param(
        [Parameter(Mandatory = $false)][object[]]$Rows,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Definition
    )

    $rowOrder = @(Get-ProjectionRowOrder -Definition $Definition)
    if (@($rowOrder).Count -eq 0) {
        return @($Rows)
    }

    $decoratedRows = @()
    $sortProperties = @()
    $sortFieldNames = @()
    $sortIndex = 0
    foreach ($sortEntry in @($rowOrder)) {
        $fieldName = [string]$sortEntry.by
        if ([string]::IsNullOrWhiteSpace($fieldName)) { continue }

        $descending = [bool]$sortEntry.descending
        $sortFieldName = "__sort$sortIndex"
        $sortFieldNames += $fieldName
        $sortProperties += @{
            Expression = $sortFieldName
            Descending = $descending
        }
        $sortIndex++
    }

    if (@($sortProperties).Count -eq 0) {
        return @($Rows)
    }

    foreach ($row in @($Rows)) {
        $decoratedRow = [ordered]@{
            __row = $row
        }

        for ($fieldIndex = 0; $fieldIndex -lt @($sortFieldNames).Count; $fieldIndex++) {
            $fieldName = [string]$sortFieldNames[$fieldIndex]
            $decoratedRow["__sort$fieldIndex"] = Get-ProjectionSortValue -Value (Get-ProjectionRowFieldValue -Row $row -Field $fieldName)
        }

        $decoratedRows += [pscustomobject]$decoratedRow
    }

    return @(
        $decoratedRows |
            Sort-Object -Stable -Property $sortProperties |
            ForEach-Object { $_.__row }
    )
}

function Invoke-TableProjection {
    param(
        [Parameter(Mandatory = $false)][object[]]$Rows,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Definition,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    $normalizedRows = @(ConvertTo-ObjectArray -InputObject $Rows)
    $normalizedDefinition = Normalize-ProjectionDefinition -Definition $Definition
    $projectedRows = @($normalizedRows)
    if (@($normalizedDefinition.filter).Count -gt 0) {
        foreach ($condition in @($normalizedDefinition.filter)) {
            $projectedRows = @($projectedRows | Where-Object { Test-ProjectionCondition -Row $_ -Condition $condition })
        }
    }
    $projectedRows = @(Sort-ProjectionRows -Rows $projectedRows -Definition $normalizedDefinition)

    if (@($normalizedDefinition.columns).Count -eq 0) {
        return @($projectedRows)
    }

    return @(
        $projectedRows | ForEach-Object {
            $row = $_
            $projected = [ordered]@{}
            foreach ($column in @($normalizedDefinition.columns)) {
                if (-not ($column -is [System.Collections.IDictionary]) -or -not (Test-MapHasKey -Map $column -Key 'name')) {
                    throw 'Projection column is missing required name property.'
                }
                $projected[[string]$column.name] = Convert-CellValueToString -Value (Resolve-ProjectionColumnValue -Row $row -Column $column -DatasetPath $DatasetPath)
            }
            [pscustomobject]$projected
        }
    )
}

function Convert-TableRowsForTag {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $false)][object[]]$Rows,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinitions,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    $normalizedRows = @(ConvertTo-ObjectArray -InputObject $Rows)
    $projectionDefinition = Get-ProjectionDefinitionForMapping -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases
    if ($null -ne $projectionDefinition) {
        return @(ConvertTo-ObjectArray -InputObject (Invoke-TableProjection -Rows $normalizedRows -Definition $projectionDefinition -DatasetPath $DatasetPath))
    }

    return @($normalizedRows)
}

function Convert-ValueToTableRow {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $row = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $row[[string]$key] = $Value[$key]
        }
        return [pscustomobject]$row
    }

    $propertyNames = @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' } | ForEach-Object { [string]$_.Name })
    if (@($propertyNames).Count -gt 0) {
        $row = [ordered]@{}
        foreach ($propertyName in @($propertyNames)) {
            $row[$propertyName] = $Value.PSObject.Properties[$propertyName].Value
        }
        return [pscustomobject]$row
    }

    return [pscustomobject]([ordered]@{ value = $Value })
}

function Convert-TableRowsToDisplayRows {
    param([Parameter(Mandatory = $false)][object[]]$Rows)

    $displayRows = @()
    foreach ($row in @(ConvertTo-ObjectArray -InputObject $Rows)) {
        if ($null -eq $row) { continue }

        $displayRow = [ordered]@{}
        foreach ($property in @($row.PSObject.Properties)) {
            $displayRow[[string]$property.Name] = Convert-CellValueToString -Value $property.Value
        }
        $displayRows += [pscustomobject]$displayRow
    }

    return @($displayRows)
}

function Get-DisplayColumnsForTable {
    param([Parameter(Mandatory = $true)][string[]]$Columns)

    $excluded = @(
        'systemid',
        'controllerref',
        'driveref',
        'volumeref',
        'poolref',
        'trayref',
        'storagesystemref',
        'id'
    )

    $filtered = @(
        $Columns |
            Where-Object {
                $name = [string]$_
                if ([string]::IsNullOrWhiteSpace($name)) { return $false }

                $lower = $name.ToLowerInvariant()
                if ($excluded -contains $lower) { return $false }
                if ($lower.EndsWith('ref')) { return $false }
                if ($lower.EndsWith('id')) { return $false }

                return $true
            }
    )

    if (@($filtered).Count -gt 0) { return $filtered }
    return $Columns
}

function Convert-ValueToTableModel {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinitions,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    if ($null -eq $Value) { return $null }

    $projectionDefinition = Get-ProjectionDefinitionForMapping -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases
    $projectionEmptyBehavior = ''
    if ($null -ne $projectionDefinition -and (Test-MapHasKey -Map $projectionDefinition -Key 'emptyBehavior') -and -not [string]::IsNullOrWhiteSpace([string]$projectionDefinition.emptyBehavior)) {
        $projectionEmptyBehavior = [string]$projectionDefinition.emptyBehavior
    }

    $rows = @()
    if ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) {
            $rows += Convert-ValueToTableRow -Value $item
        }
    }
    elseif ($Value -is [System.Collections.IDictionary] -or @($Value.PSObject.Properties).Count -gt 0) {
        $row = Convert-ValueToTableRow -Value $Value
        if ($null -ne $row) {
            $rows = @($row)
        }
    }
    else {
        return $null
    }

    $rows = @(ConvertTo-ObjectArray -InputObject (Convert-TableRowsForTag -Tag $Tag -Rows $rows -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases -DatasetPath $DatasetPath))
    if (@($rows).Count -eq 0) {
        if ($projectionEmptyBehavior -eq 'placeholder' -and $null -ne $projectionDefinition -and @($projectionDefinition.columns).Count -gt 0) {
            $placeholderRow = [ordered]@{}
            $isFirstColumn = $true
            foreach ($column in @($projectionDefinition.columns)) {
                if (-not ($column -is [System.Collections.IDictionary]) -or -not (Test-MapHasKey -Map $column -Key 'name')) {
                    continue
                }

                $columnName = [string]$column.name
                if ($isFirstColumn) {
                    $placeholderRow[$columnName] = 'Not configured'
                    $isFirstColumn = $false
                }
                else {
                    $placeholderRow[$columnName] = ''
                }
            }

            if (@($placeholderRow.Keys).Count -gt 0) {
                $rows = @([pscustomobject]$placeholderRow)
            }
        }
    }

    if (@($rows).Count -eq 0) { return $null }

    $rows = @(Convert-TableRowsToDisplayRows -Rows $rows)

    $allColumns = @($rows[0].PSObject.Properties.Name)
    $displayColumns = @(Get-DisplayColumnsForTable -Columns $allColumns)
    if (@($displayColumns).Count -eq 0) {
        $displayColumns = $allColumns
    }

    return [ordered]@{
        rows = $rows
        displayColumns = $displayColumns
    }
}

function Convert-ValueToTableString {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinitions,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    $tableModel = Convert-ValueToTableModel -Value $Value -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases -DatasetPath $DatasetPath
    if ($null -eq $tableModel) {
        if (($Value -is [System.Collections.IList]) -or ($Value -is [hashtable])) {
            return ''
        }
        return (Convert-CellValueToString -Value $Value)
    }

    $rows = @($tableModel.rows)
    $displayColumns = @($tableModel.displayColumns)
    return (($rows | Select-Object -Property $displayColumns | Format-Table -AutoSize | Out-String).TrimEnd())
}

function Convert-ValueToString {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $false)][string]$Tag,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinitions,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases,
        [Parameter(Mandatory = $false)][string]$DatasetPath
    )

    if ($null -eq $Value) {
        return ''
    }

    $projectionDefinition = Get-ProjectionDefinitionForMapping -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases
    $renderMode = Get-EffectiveRenderMode -RenderHint $RenderHint -ProjectionDefinition $projectionDefinition -Tag $Tag
    $renderModeExplicit = Test-RenderModeWasExplicitlyDeclared -RenderHint $RenderHint -ProjectionDefinition $projectionDefinition
    $hasProjection = ($null -ne $projectionDefinition)

    if ($renderMode -eq 'table' -or $hasProjection) {
        if (-not $hasProjection) {
            $policy = Get-StructuredValuePolicy -RenderHint $RenderHint -ProjectionDefinition $projectionDefinition -RenderMode $renderMode
            Add-RenderIssue -Code 'ASB-ASM-SDT-TABLE-PROJECTION-MISSING' -Severity 'WARN' -Message "Tag '$Tag' declared renderMode '$renderMode' but no projection definition was found. Structured values will not be serialized as raw JSON." -PathValue $script:currentDatasetPath
            return (Get-StructuredValuePlaceholder -RenderMode $renderMode -Policy $policy)
        }

        return (Convert-ValueToTableString -Value $Value -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases -DatasetPath $DatasetPath)
    }
    if ($renderMode -eq 'diagram') {
        $diagramRef = if ($null -ne $RenderHint -and (Test-MapHasKey -Map $RenderHint -Key 'diagramRef')) { [string]$RenderHint.diagramRef } else { [string]$Tag }
        return "[diagram: $diagramRef]"
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [ValueType]) {
        return [string]$Value
    }

    $isStructured = ($Value -is [System.Collections.IDictionary]) -or (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]))
    if ($isStructured) {
        if ($renderMode -in @('json-evidence', 'json-debug')) {
            $jsonValue = if ($Value -is [System.Collections.IDictionary]) { $Value } else { @($Value) }
            return ([string](ConvertTo-Json -InputObject $jsonValue -Depth 10 -Compress))
        }

        if (-not $renderModeExplicit) {
            $jsonValue = if ($Value -is [System.Collections.IDictionary]) { $Value } else { @($Value) }
            return ([string](ConvertTo-Json -InputObject $jsonValue -Depth 10 -Compress))
        }

        $policy = Get-StructuredValuePolicy -RenderHint $RenderHint -ProjectionDefinition $projectionDefinition -RenderMode $renderMode
        Add-RenderIssue -Code 'ASB-ASM-SDT-STRUCTURED-VALUE-RENDERMODE-REQUIRED' -Severity 'WARN' -Message "Tag '$Tag' resolved to a structured value but renderMode '$renderMode' does not permit raw JSON output. Declare renderMode 'table', 'diagram', 'json-evidence', or 'json-debug'." -PathValue $script:currentDatasetPath
        return (Get-StructuredValuePlaceholder -RenderMode $renderMode -Policy $policy)
    }

    return ([string](ConvertTo-Json -InputObject $Value -Depth 10 -Compress))
}

$startedUtc = Get-UtcTimestamp
$issues = [System.Collections.Generic.List[hashtable]]::new()
$stageList = [System.Collections.Generic.List[object]]::new()
$outputs = [System.Collections.Generic.List[hashtable]]::new()
$matches = [System.Collections.Generic.List[hashtable]]::new()
$status = 'OK'
$bundleId = $null
$currentStageName = $null
$currentTag = $null
$currentDatasetRelativePath = $null
$currentDatasetPath = $null
$currentSelectorChain = ''
$templateExtension = $null
$isDocxTemplate = $false
$templateText = $null

$stageMap = [ordered]@{}
$stageInitializationUtc = Get-UtcTimestamp
foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
    $stage = [ordered]@{ name = $stageName; status = 'SKIPPED'; startedUtc = $stageInitializationUtc; completedUtc = $stageInitializationUtc; details = $null }
    $stageMap[$stageName] = $stage
    $stageList.Add($stage)
}

function Start-RenderStage {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Stage)
    $script:currentStageName = [string]$Stage.name
    $Stage.startedUtc = Get-UtcTimestamp
    $Stage.completedUtc = $null
    $Stage.status = 'OK'
}

function Complete-RenderStage {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$Details
    )
    $Stage.status = $Status
    if ($Status -ne 'ERROR') { $script:currentStageName = $null }
    $Stage.completedUtc = Get-UtcTimestamp
    if ($PSBoundParameters.ContainsKey('Details')) { $Stage.details = $Details }
}

function Add-SchemaValidationIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$PathValue
    )

    $issues.Add([ordered]@{ code = $Code; severity = 'ERROR'; message = $Message; path = $PathValue })
}

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $effectiveContractsRoot = Resolve-AssemblerContractsRoot -ContractsRoot $ContractsRoot -RepoRoot $repoRoot
    $mappingSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards') 'mapping.dataset-to-sdt.schema.v1.json'
    $projectionSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.projections.schema.v1.json'
    $diagramSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.diagrams.schema.v1.json'
    $renderReportSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.render-report.schema.v1.json'

    Start-RenderStage -Stage $stageMap.Load
    $mapping = Read-JsonFile -Path $MappingPath
    $projectionContractPath = Resolve-ProjectionContractPath -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $projectionContract = Read-ProjectionContractFile -Path $projectionContractPath
    $projectionDefinitions = Get-ProjectionDefinitions -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $projectionAliases = Get-ProjectionAliases -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $diagramContractPath = Resolve-DiagramContractPath -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $diagramContract = if ([string]::IsNullOrWhiteSpace($diagramContractPath)) { $null } else { Read-DiagramContractFile -Path $diagramContractPath }
    $diagramDefinitions = Get-DiagramDefinitions -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $diagramAliases = Get-DiagramAliases -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $mappingSchema = Read-JsonFile -Path $mappingSchemaPath
    $templateExtension = [string]([System.IO.Path]::GetExtension($TemplatePath)).ToLowerInvariant()
    $isDocxTemplate = ($templateExtension -eq '.docx')
    if (-not $isDocxTemplate) {
        $templateText = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    }

    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-JsonFile -Path $manifestPath
        $bundleId = $manifest.bundleId
    }
    Complete-RenderStage -Stage $stageMap.Load -Status 'OK' -Details ([ordered]@{ mappingPath = $MappingPath; templatePath = $TemplatePath; templateExtension = $templateExtension; contractsRoot = $effectiveContractsRoot; mappingSchemaPath = $mappingSchemaPath; projectionContractPath = $projectionContractPath; projectionSchemaPath = $projectionSchemaPath; diagramContractPath = $diagramContractPath; diagramSchemaPath = $diagramSchemaPath })

    Start-RenderStage -Stage $stageMap.Validate
    $mappingCompatibility = Resolve-MappingSchemaCompatibleDocument -MappingDocument $mapping -SchemaPath $mappingSchemaPath -DocumentLabel $MappingPath
    if (-not $mappingCompatibility.isValid) {
        Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-MAPPING-INVALID' -Message ([string]$mappingCompatibility.message) -PathValue $MappingPath
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Mapping schema validation failed.'
    }
    if ([string]$mappingCompatibility.mode -ne 'as-is') {
        $issues.Add([ordered]@{
            code = 'ASB-ASM-SDT-MAPPING-COMPAT-SHAPE'
            severity = 'WARN'
            message = "Mapping file '$MappingPath' was adapted to '$($mappingCompatibility.mode)' SDT tag shape for schema compatibility."
            path = $MappingPath
        })
    }
    $mapping = $mappingCompatibility.mapping

    # TODO(contract-handoff): remove this operator guard after all SDT render entrypoints are fully bundle-resolved.
    $placeholderViolations = @(Get-UnresolvedMappingDatasetPlaceholderViolations -Mapping $mapping)
    if (@($placeholderViolations).Count -gt 0) {
        $sample = @($placeholderViolations | Select-Object -First 3 | ForEach-Object {
            $sampleTag = if ([string]::IsNullOrWhiteSpace([string]$_.tag)) { '<missing-tag>' } else { [string]$_.tag }
            "'$([string]$_.dataset)' (tag '$sampleTag')"
        })
        $sampleText = if (@($sample).Count -gt 0) { $sample -join '; ' } else { 'n/a' }
        $issues.Add([ordered]@{
            code = 'ASB-ASM-SDT-PREFLIGHT-UNRESOLVED-MAPPING-PATH'
            severity = 'ERROR'
            message = "Preflight blocked Invoke-AssemblerSdtRender.ps1: mapping '$MappingPath' still contains unresolved runtime placeholders (__TARGET__/__SYSTEM__) in dataset paths ($($placeholderViolations.Count) mapping(s); sample: $sampleText). Use Invoke-AssemblerBundleRender.ps1 so placeholders are expanded before SDT render."
            path = $MappingPath
        })
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Mapping preflight failed due to unresolved runtime placeholders in dataset paths.'
    }

    $projectionContractJson = $projectionContract | ConvertTo-Json -Depth 20
    $projectionContractJsonShape = Test-ProjectionContractJsonArrayShape -JsonText $projectionContractJson
    if (-not $projectionContractJsonShape.isValid) {
        Add-SchemaValidationIssue -Code 'ASB-ASM-PROJECTIONS-ARRAY-SHAPE-INVALID' -Message ([string]$projectionContractJsonShape.message) -PathValue $projectionContractPath
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Projection contract JSON shape validation failed.'
    }

    $projectionValidation = Test-AssemblerSchemaJson -JsonText $projectionContractJson -SchemaPath $projectionSchemaPath -DocumentLabel $projectionContractPath
    if (-not $projectionValidation.isValid) {
        Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-PROJECTIONS-INVALID' -Message ([string]$projectionValidation.message) -PathValue $projectionContractPath
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Projection schema validation failed.'
    }
    if ($null -ne $diagramContract) {
        if (-not (Test-Path -LiteralPath $diagramSchemaPath -PathType Leaf)) {
            Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-DIAGRAMS-MISSING' -Message "Diagram contract '$diagramContractPath' exists but diagram schema '$diagramSchemaPath' was not found." -PathValue $diagramSchemaPath
            Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
            $status = 'ERROR'
            throw 'Diagram schema missing.'
        }

        $diagramContractJson = $diagramContract | ConvertTo-Json -Depth 30
        $diagramValidation = Test-AssemblerSchemaJson -JsonText $diagramContractJson -SchemaPath $diagramSchemaPath -DocumentLabel $diagramContractPath
        if (-not $diagramValidation.isValid) {
            Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-DIAGRAMS-INVALID' -Message ([string]$diagramValidation.message) -PathValue $diagramContractPath
            Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
            $status = 'ERROR'
            throw 'Diagram schema validation failed.'
        }
    }
    Complete-RenderStage -Stage $stageMap.Validate -Status 'OK' -Details ([ordered]@{ mappingCount = @($mapping.mappings).Count; projectionCount = @($projectionDefinitions.Keys).Count; diagramCount = @($diagramDefinitions.Keys).Count })

    Start-RenderStage -Stage $stageMap.Transform
    $replaceByTag = @{}
    $docxTableByTag = @{}
    $docxImageByTag = @{}
    foreach ($entry in @($mapping.mappings)) {
        $currentDatasetRelativePath = [string]$entry.dataset
        $currentDatasetPath = $null
        $currentSelectorChain = ''
        $tag = if (Test-MapHasKey -Map $entry -Key 'sdtTag') { [string]$entry['sdtTag'] } elseif ((Test-MapHasKey -Map $entry -Key 'target') -and $entry['target'] -is [System.Collections.IDictionary] -and (Test-MapHasKey -Map $entry['target'] -Key 'sdtTag')) { [string]$entry['target']['sdtTag'] } else { '' }
        $currentTag = $tag
        if ([string]::IsNullOrWhiteSpace($tag)) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-MAPPING-NOTAG'; severity = 'WARN'; message = "Skipping mapping with missing sdtTag for dataset '$($entry.dataset)'"; path = $MappingPath })
            continue
        }

        $datasetResolution = Resolve-DatasetFilePath -BundleRoot $BundleRoot -DatasetRelativePath ([string]$entry.dataset) -TechId ([string]$mapping.techId)
        $datasetPath = [string]$datasetResolution.path
        $currentDatasetPath = $datasetPath
        if (-not (Test-Path -LiteralPath $datasetPath -PathType Leaf)) {
            $severity = if ($entry.required) { 'ERROR' } else { 'WARN' }
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-DATASET-MISSING'; severity = $severity; message = "Dataset '$($entry.dataset)' not found for tag '$tag'"; path = $datasetPath })
            if ($severity -eq 'ERROR') { $status = 'ERROR' }
            continue
        }
        if ($datasetResolution.autoResolved) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-DATASET-AUTORESOLVED'; severity = 'WARN'; message = [string]$datasetResolution.reason; path = $datasetPath })
        }

        $dataset = Read-JsonFile -Path $datasetPath
        $envelopeErrors = @(Test-DatasetEnvelope -Dataset $dataset -DatasetPath $datasetPath)
        if (@($envelopeErrors).Count -gt 0) {
            if (Test-LegacySummaryCompatibilityDataset -Dataset $dataset -DatasetPath $datasetPath) {
                $issues.Add([ordered]@{
                    code = 'ASB-ASM-SDT-DATASET-COMPAT'
                    severity = 'WARN'
                    message = "Dataset '$($entry.dataset)' uses legacy run_summary.json compatibility for tag '$tag'; update the collector/Core output to emit a full lnv.collector.dataset.v1 envelope."
                    path = $datasetPath
                })
            }
            else {
                $severity = if ($entry.required) { 'ERROR' } else { 'WARN' }
                foreach ($envelopeError in $envelopeErrors) {
                    $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-DATASET-ENVELOPE'; severity = $severity; message = "Dataset '$($entry.dataset)' failed envelope validation for tag '$tag': $envelopeError"; path = $datasetPath })
                }
                if ($severity -eq 'ERROR') { $status = 'ERROR' }
                continue
            }
        }

        $resolved = $null
        $datasetContractKey = Get-DatasetContractKey -DatasetRelativePath ([string]$entry.dataset) -Dataset $dataset
        $datasetPresentation = Get-DatasetPresentationMetadata -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId) -DatasetContractKey $datasetContractKey
        $renderHint = Get-MappingRenderHint -MappingEntry $entry -DatasetPresentation $datasetPresentation -Tag $tag
        $preSelectorRenderMode = Get-EffectiveRenderMode -RenderHint $renderHint -ProjectionDefinition $null -Tag $tag
        if ($preSelectorRenderMode -eq 'diagram') {
            $diagramRender = Invoke-DiagramRender -Tag $tag -RenderHint $renderHint -DiagramDefinitions $diagramDefinitions -DiagramAliases $diagramAliases -BundleRoot $BundleRoot -TechId ([string]$mapping.techId) -CurrentDatasetPath $datasetPath
            $resolvedText = [string]$diagramRender.placeholder
            $replaceByTag[$tag] = $resolvedText
            if ($isDocxTemplate -and -not [string]::IsNullOrWhiteSpace([string]$diagramRender.imageBase64)) {
                $imageFormat = if ((Test-MapHasKey -Map $diagramRender -Key 'imageFormat') -and [string]$diagramRender.imageFormat -eq 'svg') { 'svg' } else { 'png' }
                $diagramImageSize = if ($imageFormat -eq 'svg' -and (Test-MapHasKey -Map $diagramRender -Key 'imageWidth') -and (Test-MapHasKey -Map $diagramRender -Key 'imageHeight')) {
                    New-DocxImageSizeFromPixelDimensions -Width ([int]$diagramRender.imageWidth) -Height ([int]$diagramRender.imageHeight)
                }
                else {
                    New-DocxImageSizeFromPngBase64 -ImageBase64 ([string]$diagramRender.imageBase64)
                }
                $docxImageByTag[$tag] = [ordered]@{
                    imageBase64 = [string]$diagramRender.imageBase64
                    imageFormat = $imageFormat
                    name = [string]$diagramRender.diagramRef
                    widthEmu = [int64]$diagramImageSize.WidthEmu
                    heightEmu = [int64]$diagramImageSize.HeightEmu
                }
            }
            $matches.Add([ordered]@{ tag = $tag; dataset = [string]$entry.dataset; selector = ''; valuePreview = $resolvedText })
            $currentTag = $null
            $currentDatasetRelativePath = $null
            $currentDatasetPath = $null
            $currentSelectorChain = ''
            continue
        }

        $selectors = @(Get-EffectiveSelectorsForMapping -MappingEntry $entry -RenderHint $renderHint -DatasetPresentation $datasetPresentation)
        $currentSelectorChain = if (@($selectors).Count -gt 0) { (($selectors | ForEach-Object { [string]$_ }) -join ' -> ') } else { '' }
        if (@($selectors).Count -gt 0) {
            $selectorResult = Resolve-SelectorWithSummaryCompatibility -Dataset $dataset -Selectors @($selectors | ForEach-Object { [string]$_ }) -DatasetPath $datasetPath
            $resolved = $selectorResult.value
            $selectorFailed = [bool]$selectorResult.selectorFailed

            if ($selectorFailed) {
                $selectorChain = $currentSelectorChain
                $severity = if ($entry.required) { 'ERROR' } else { 'WARN' }
                $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-SELECTOR-NOMATCH'; severity = $severity; message = "Selector chain '$selectorChain' did not resolve for tag '$tag'"; path = $datasetPath })
                if ($severity -eq 'ERROR') { $status = 'ERROR' }
                continue
            }
        }
        else {
            $resolved = $dataset
        }

        if ($null -eq $resolved -and $entry.required) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-SELECTOR-NOMATCH'; severity = 'ERROR'; message = "No selector match found for required tag '$tag'"; path = $datasetPath })
            $status = 'ERROR'
            continue
        }

        $resolvedText = [string](Convert-ValueToString -Value $resolved -Tag $tag -RenderHint $renderHint -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases -DatasetPath $datasetPath)
        $replaceByTag[$tag] = $resolvedText
        if ($isDocxTemplate) {
            $projectionDefinition = Get-ProjectionDefinitionForMapping -Tag $tag -RenderHint $renderHint -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases
            $renderMode = Get-EffectiveRenderMode -RenderHint $renderHint -ProjectionDefinition $projectionDefinition -Tag $tag
            if ($null -ne $projectionDefinition) {
                $tableModel = Convert-ValueToTableModel -Value $resolved -Tag $tag -RenderHint $renderHint -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases -DatasetPath $datasetPath
                if ($null -ne $tableModel) {
                    $docxTableByTag[$tag] = $tableModel
                }
            }
        }
        $resolvedTextLength = if ($null -eq $resolvedText) { 0 } else { $resolvedText.Length }
        $valuePreview = if ($resolvedTextLength -gt 80) { $resolvedText.Substring(0, 80) + '...' } else { $resolvedText }
        $matches.Add([ordered]@{ tag = $tag; dataset = [string]$entry.dataset; selector = $currentSelectorChain; valuePreview = $valuePreview })
        $currentTag = $null
        $currentDatasetRelativePath = $null
        $currentDatasetPath = $null
        $currentSelectorChain = ''
    }

    $transformStatus = if ($status -eq 'ERROR') { 'ERROR' } elseif (@($issues | Where-Object { $_.severity -eq 'WARN' }).Count -gt 0) { 'WARN' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Transform -Status $transformStatus -Details ([ordered]@{ tagsResolved = $replaceByTag.Count; matches = $matches.Count })

    Start-RenderStage -Stage $stageMap.Render
    $rendered = $null
    $unresolvedByTag = @{}
    $renderDetails = [ordered]@{}
    $resolvedTemplatePath = $null
    $templateMetadata = $null
    $templateByteHashSha256 = $null
    if ($isDocxTemplate) {
        $resolvedTemplatePath = (Resolve-Path -LiteralPath $TemplatePath).Path
        $templateItem = Get-Item -LiteralPath $resolvedTemplatePath
        $templateBytes = [System.IO.File]::ReadAllBytes($resolvedTemplatePath)
        $templateByteHashSha256 = Get-FileSha256Hex -Bytes $templateBytes
        $templateMetadata = [ordered]@{
            path = $resolvedTemplatePath
            length = [int64]$templateItem.Length
            lastWriteTimeUtc = $templateItem.LastWriteTimeUtc.ToString('o')
            sha256 = $templateByteHashSha256
        }
        Write-Verbose "[docx-render] template path: $($templateMetadata.path)"
        Write-Verbose "[docx-render] template sha256: $($templateMetadata.sha256)"
        Write-Verbose "[docx-render] template length bytes: $($templateMetadata.length)"
        Write-Verbose "[docx-render] template lastWriteUtc: $($templateMetadata.lastWriteTimeUtc)"

        $outputDir = Split-Path -Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
        $docxRender = Render-DocxTemplate -TemplatePath $resolvedTemplatePath -OutputPath $OutputPath -ReplaceByTag $replaceByTag -TableByTag $docxTableByTag -ImageByTag $docxImageByTag -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment -DocDocumentReference $DocDocumentReference -DocVersion $DocVersion -DocConfigSnapDate $DocConfigSnapDate -DocReferenceId $DocReferenceId -DocClassification $DocClassification -DocSupportRegion $DocSupportRegion -DocSupportTier $DocSupportTier -SupportRegionSidecarPath $SupportRegionSidecarPath -DocxMatchMode $DocxMatchMode -UnresolvedTokenPolicy $UnresolvedTokenPolicy
        $docxUnresolvedLiteralByTag = $docxRender.unresolvedLiteralByTag
        $unresolvedByTag = $docxUnresolvedLiteralByTag
        $renderDetails.templatePathResolved = [string]$templateMetadata.path
        $renderDetails.outputPathResolved = [string]$docxRender.outputPathResolved
        $renderDetails.templateBytesSha256 = [string]$templateMetadata.sha256
        $renderDetails.templateLengthBytes = [int64]$templateMetadata.length
        $renderDetails.templateLastWriteUtc = [string]$templateMetadata.lastWriteTimeUtc
        $renderDetails.partsUpdated = [int]$docxRender.partsUpdated
        $renderDetails.literalDatasetTokensExpected = [int]$docxRender.literalDatasetTokensExpected
        $renderDetails.literalDatasetTokensDiscovered = [int]$docxRender.literalDatasetTokensDiscovered
        $renderDetails.literalDatasetTagsDiscovered = [int]$docxRender.literalDatasetTagsDiscovered
        $renderDetails.literalDatasetFragmentHintTags = @($docxRender.literalDatasetFragmentHintTags)
        $renderDetails.literalDatasetTagStatus = @($docxRender.literalDatasetTagStatus)
        $renderDetails.literalDatasetTokensPopulated = [int]$docxRender.literalDatasetTokensPopulated
        $renderDetails.controlsDiscovered = [int]$docxRender.controlsDiscovered
        $renderDetails.literalTokensMatched = [int]$docxRender.literalTokensMatched
        $renderDetails.literalTokensMatchedScalar = [int]$docxRender.literalTokensMatchedScalar
        $renderDetails.literalTokensMatchedTable = [int]$docxRender.literalTokensMatchedTable
        $renderDetails.literalTokensMatchedImage = [int]$docxRender.literalTokensMatchedImage
        $renderDetails.docPropertyLiteralTokensMatched = [int]$docxRender.docPropertyLiteralTokensMatched
        $renderDetails.docPropControlsExpected = [int]$docxRender.docPropControlsExpected
        $renderDetails.docPropControlsMatched = [int]$docxRender.docPropControlsMatched
        $renderDetails.docPropControlsPopulated = [int]$docxRender.docPropControlsPopulated
        $renderDetails.controlsDiscoveredMapped = [int]$docxRender.controlsDiscoveredMapped
        $renderDetails.controlsDiscoveredUnmapped = [int]$docxRender.controlsDiscoveredUnmapped
        $renderDetails.docPropertyFieldsDiscovered = [int]$docxRender.docPropertyFieldsDiscovered
        $renderDetails.docPropertyFieldsPopulated = [int]$docxRender.docPropertyFieldsPopulated
        $renderDetails.taggedControlsMatched = [int]$docxRender.taggedControlsMatched
        $renderDetails.controlsPopulated = [int]$docxRender.controlsPopulated
        $renderDetails.discoveredTaggedControls = @($docxRender.discoveredTaggedControls)
        $renderDetails.discoveredUnmappedTaggedControls = @($docxRender.discoveredUnmappedTaggedControls)
        $renderDetails.unmatchedTaggedControls = @($docxRender.unmatchedTaggedControls)
        $renderDetails.docPropMappedTags = @($docxRender.docPropMappedTags)
        $renderDetails.contentControlMappedTags = @($docxRender.contentControlMappedTags)
        $renderDetails.supportRegion = $docxRender.supportRegion
        $renderDetails.partErrors = @($docxRender.partErrors)
        $renderDetails.literalTagDiagnostics = $docxRender.literalTagDiagnostics
        $renderDetails.literalTagDiagnosticsSummary = Get-LiteralTagDiagnosticsSummary -Diagnostics $docxRender.literalTagDiagnostics -TopEntries 25 -TopZeroHitTags 8 -TopInspectedPartsPerTag 4
        $renderDetails.literalTagHitSummary = @($docxRender.literalTagHitSummary)
        $renderDetails.literalPartHitSummary = @($docxRender.literalPartHitSummary)
        $renderDetails.unresolvedLiteralTokens = @($docxUnresolvedLiteralByTag.Keys | Sort-Object)
        $renderDetails.docxMatchMode = [string]$DocxMatchMode
        $renderDetails.updateFieldsOnOpenEnabled = $(if (Test-MapHasKey -Map $docxRender -Key 'updateFieldsOnOpenEnabled') { [bool]$docxRender.updateFieldsOnOpenEnabled } else { $false })
        $renderDetails.updateFieldsOnOpenReason = $(if (Test-MapHasKey -Map $docxRender -Key 'updateFieldsOnOpenReason') { [string]$docxRender.updateFieldsOnOpenReason } else { '' })
        $renderDetails.updateFieldsOnOpenPreparation = $(if (Test-MapHasKey -Map $docxRender -Key 'updateFieldsOnOpenPreparation') { $docxRender.updateFieldsOnOpenPreparation } else { [ordered]@{} })
        $renderDetails.updateFieldsOnOpenFinal = $(if (Test-MapHasKey -Map $docxRender -Key 'updateFieldsOnOpenFinal') { $docxRender.updateFieldsOnOpenFinal } else { [ordered]@{} })
        $renderDetails.tocRefreshStatus = $(if (Test-MapHasKey -Map $docxRender -Key 'tocRefreshStatus') { [string]$docxRender.tocRefreshStatus } else { '' })
        $renderDetails.tocRefreshMethod = $(if (Test-MapHasKey -Map $docxRender -Key 'tocRefreshMethod') { [string]$docxRender.tocRefreshMethod } else { '' })
        $renderDetails.tocRefreshMessage = $(if (Test-MapHasKey -Map $docxRender -Key 'tocRefreshMessage') { [string]$docxRender.tocRefreshMessage } else { '' })
        $renderDetails.tocRefreshDiagnostics = $(if (Test-MapHasKey -Map $docxRender -Key 'tocRefreshDiagnostics') { $docxRender.tocRefreshDiagnostics } else { [ordered]@{} })
        if ([bool]$renderDetails.updateFieldsOnOpenEnabled) {
            $issues.Add([ordered]@{
                code = 'ASB-ASM-DOCX-UPDATEFIELDS-REMAINS'
                severity = 'WARN'
                message = "Final DOCX still contains enabled w:updateFields after render. Word may prompt to update fields or links on open. tocRefreshStatus='$($renderDetails.tocRefreshStatus)'; tocRefreshMethod='$($renderDetails.tocRefreshMethod)'; reason='$($renderDetails.updateFieldsOnOpenReason)'"
                path = [string]$renderDetails.outputPathResolved
            })
            if ($status -eq 'OK') { $status = 'PARTIAL' }
        }
        if ([string]$renderDetails.tocRefreshStatus -eq 'deferred') {
            $issues.Add([ordered]@{
                code = 'ASB-ASM-DOCX-TOC-REFRESH-DEFERRED'
                severity = 'WARN'
                message = "DOCX TOC refresh was deferred because Word automation did not complete. The renderer did not enable Word open-time field updates by default. message='$($renderDetails.tocRefreshMessage)'"
                path = [string]$renderDetails.outputPathResolved
            })
            if ($status -eq 'OK') { $status = 'PARTIAL' }
        }
        $expectedDocPropertyControlCount = [int]$renderDetails.docPropControlsExpected
        $controlsPopulatedCount = [int]$renderDetails.docPropControlsPopulated
        $docPropertyFieldPopulatedCount = [int]$renderDetails.docPropertyFieldsPopulated
        $docPropertyLiteralTokenPopulatedCount = [int]$renderDetails.docPropertyLiteralTokensMatched
        $docPropertyPopulationCount = $controlsPopulatedCount + $docPropertyFieldPopulatedCount + $docPropertyLiteralTokenPopulatedCount
        $docPropValuesSupplied = $expectedDocPropertyControlCount -gt 0
        $docPropNoPopulationSeverity = Resolve-DocPropNoPopulationSeverity
        if ((-not (Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'literal-token')) -and [int]$renderDetails.literalDatasetTokensExpected -gt 0 -and [int]$renderDetails.literalDatasetTokensDiscovered -gt 0) {
            $sampleFoundTags = @(
                @($renderDetails.literalDatasetTagStatus | Where-Object { [int]$_.contiguousLiteralHits -gt 0 } | Select-Object -First 5 | ForEach-Object { [string]$_.tag })
            )
            $sampleFoundTagsText = if ($sampleFoundTags.Count -gt 0) { $sampleFoundTags -join ', ' } else { 'n/a' }
            $status = 'ERROR'
            $issues.Add([ordered]@{
                code = 'ASB-ASM-SDT-DOCX-MATCH-MODE-CONFLICT'
                severity = 'ERROR'
                message = "DOCX template contains literal dataset SDT tokens but docxMatchMode='$DocxMatchMode' excludes literal-token replacement. literalDatasetTokensExpected=$($renderDetails.literalDatasetTokensExpected); literalDatasetTokensDiscovered=$($renderDetails.literalDatasetTokensDiscovered); literalDatasetTagsDiscovered=$($renderDetails.literalDatasetTagsDiscovered); resolvedTemplatePath='$($renderDetails.templatePathResolved)'; sampleLiteralTags=$sampleFoundTagsText"
                path = $TemplatePath
            })
        }
        if ((Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'literal-token') -and [int]$renderDetails.literalDatasetTokensExpected -gt 0 -and [int]$renderDetails.literalDatasetTokensPopulated -eq 0) {
            $zeroHitSamplesText = 'n/a'
            $zeroHitSamples = @($renderDetails.literalTagDiagnosticsSummary.zeroHitTagSamples)
            if ($zeroHitSamples.Count -gt 0) {
                $zeroHitSamplesText = @(
                    $zeroHitSamples |
                        Select-Object -First 3 |
                        ForEach-Object {
                            $inspectedPartsText = if (@($_.inspectedParts).Count -gt 0) { @($_.inspectedParts) -join '|' } else { 'none' }
                            "$($_.tag)[$($_.mode)]=>parts{$inspectedPartsText}"
                        }
                ) -join '; '
            }
            $fragmentHintTagsSample = if (@($renderDetails.literalDatasetFragmentHintTags).Count -gt 0) { (@($renderDetails.literalDatasetFragmentHintTags | Select-Object -First 5) -join ', ') } else { 'n/a' }
            $status = 'ERROR'
            $issues.Add([ordered]@{
                code = 'ASB-ASM-SDT-DOCX-NO-POPULATION'
                severity = 'ERROR'
                message = "DOCX literal-token render expected dataset mapping replacement but found no matching tokens to populate. docxMatchMode='$DocxMatchMode'; literalDatasetTokensExpected=$($renderDetails.literalDatasetTokensExpected); literalDatasetTokensDiscovered=$($renderDetails.literalDatasetTokensDiscovered); literalDatasetTokensPopulated=$($renderDetails.literalDatasetTokensPopulated); literalTokensMatched=$($renderDetails.literalTokensMatched); literalTokensMatchedScalar=$($renderDetails.literalTokensMatchedScalar); literalTokensMatchedTable=$($renderDetails.literalTokensMatchedTable); literalTagDiagnosticsTotal=$($renderDetails.literalTagDiagnosticsSummary.totalEntries); zeroHitTagsSample=$zeroHitSamplesText; fragmentHintTagsSample=$fragmentHintTagsSample"
                path = $TemplatePath
            })
        }
        if ((Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'content-control-tag') -and $docPropValuesSupplied -and $docPropertyPopulationCount -eq 0) {
            if ($docPropNoPopulationSeverity -eq 'ERROR') {
                $status = 'ERROR'
            }
            $sampleMatchedTags = @(
                @($renderDetails.docPropMappedTags | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique -First 5)
            )
            $sampleMatchedTagsText = if ($sampleMatchedTags.Count -gt 0) { $sampleMatchedTags -join ', ' } else { 'n/a' }
            $issues.Add([ordered]@{
                code = 'ASB-ASM-DOCPROP-DOCX-NO-POPULATION'
                severity = $docPropNoPopulationSeverity
                message = "DOCX document-property render expected document placeholders but none were populated. docxMatchMode='$DocxMatchMode'; discoveredControls=$($renderDetails.controlsDiscovered); discoveredMappedControls=$($renderDetails.controlsDiscoveredMapped); discoveredUnmappedControls=$($renderDetails.controlsDiscoveredUnmapped); discoveredDocPropertyFields=$($renderDetails.docPropertyFieldsDiscovered); partErrorCount=$(@($renderDetails.partErrors).Count); taggedControlsMatched=$($renderDetails.taggedControlsMatched); controlsPopulated=$controlsPopulatedCount; docPropertyFieldsPopulated=$docPropertyFieldPopulatedCount; docPropertyLiteralTokensPopulated=$docPropertyLiteralTokenPopulatedCount; docPropertyPopulated=$docPropertyPopulationCount; docPropertyControlTags=$expectedDocPropertyControlCount; docPropValuesSupplied=$docPropValuesSupplied; sampleDocPropertyTags=$sampleMatchedTagsText; policySeverity=$docPropNoPopulationSeverity"
                path = $TemplatePath
            })
        }
        foreach ($partError in @($docxRender.partErrors)) {
            $partName = if (Test-MapHasKey -Map $partError -Key 'partName') { [string]$partError.partName } else { '' }
            $partErrorMessage = if (Test-MapHasKey -Map $partError -Key 'message') { [string]$partError.message } else { '' }
            $partMatchMode = if (Test-MapHasKey -Map $partError -Key 'matchMode') { [string]$partError.matchMode } else { [string]$DocxMatchMode }
            $partErrorSeverity = if (Test-DocxMatchModeIncludes -DocxMatchMode $partMatchMode -Mode 'content-control-tag') { 'ERROR' } else { 'WARN' }
            if ($partErrorSeverity -eq 'ERROR') {
                $status = 'ERROR'
            }
            $issues.Add([ordered]@{
                code = 'ASB-ASM-SDT-DOCX-PART-REWRITE'
                severity = $partErrorSeverity
                message = "DOCX part '$partName' failed during content-control parsing/replacement (match mode '$partMatchMode'): $partErrorMessage"
                path = $TemplatePath
            })
        }
    }
    else {
        $templateUnresolvedByTag = Get-UnresolvedSdtTagOccurrences -RenderedText $templateText
        $rendered = $templateText
        $annotatedTagCount = 0
        foreach ($tag in $replaceByTag.Keys) {
            $replacementText = [string]$replaceByTag[$tag]
            if ($AnnotateResolvedTags.IsPresent) {
                $traceMarker = "[SDT-TAG:$tag]"
                $tokenCount = [regex]::Matches($rendered, "<<SDT:\s*$([regex]::Escape([string]$tag))\s*>>").Count
                $annotatedTagCount += [int]$tokenCount
                $rendered = Replace-LiteralSdtTokenText -Text $rendered -Tag ([string]$tag) -Replacement "$traceMarker`n$replacementText"
            }
            else {
                $rendered = Replace-LiteralSdtTokenText -Text $rendered -Tag ([string]$tag) -Replacement $replacementText
            }
        }
        if ($AnnotateResolvedTags.IsPresent) {
            Write-Verbose "[text-render] annotate mode enabled (tags annotated: $annotatedTagCount)"
        }
        $renderUnresolvedByTag = Get-UnresolvedSdtTagOccurrences -RenderedText $rendered
        $unresolvedByTag = @{}
        foreach ($unresolvedTag in @($renderUnresolvedByTag.Keys)) {
            if (Test-MapHasKey -Map $templateUnresolvedByTag -Key ([string]$unresolvedTag)) {
                $unresolvedByTag[[string]$unresolvedTag] = $renderUnresolvedByTag[[string]$unresolvedTag]
            }
        }
        if ([string]$UnresolvedTokenPolicy -eq 'remove') {
            $rendered = Remove-UnresolvedSdtTokensFromText -Text $rendered
            $unresolvedByTag = @{}
        }
    }
    $unresolvedSummary = [ordered]@{
        unresolvedTagCount = @($unresolvedByTag.Keys).Count
        unresolvedOccurrences = 0
        tags = @()
    }
    $requiredTagLookup = @{}
    foreach ($entry in @($mapping.mappings)) {
        $requiredTag = if (Test-MapHasKey -Map $entry -Key 'sdtTag') { [string]$entry['sdtTag'] } elseif ((Test-MapHasKey -Map $entry -Key 'target') -and $entry['target'] -is [System.Collections.IDictionary] -and (Test-MapHasKey -Map $entry['target'] -Key 'sdtTag')) { [string]$entry['target']['sdtTag'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($requiredTag)) { continue }
        if ((Test-MapHasKey -Map $entry -Key 'required') -and [bool]$entry.required) {
            $requiredTagLookup[$requiredTag] = $true
        }
    }

    foreach ($tag in @($unresolvedByTag.Keys | Sort-Object)) {
        $occurrence = $unresolvedByTag[$tag]
        $sampleLocations = @($occurrence.locations | Select-Object -First 3 | ForEach-Object { "L$($_.line):C$($_.column)" })
        $sampleLocationsText = if (@($sampleLocations).Count -gt 0) { $sampleLocations -join ', ' } else { 'n/a' }
        $isRequiredTag = Test-MapHasKey -Map $requiredTagLookup -Key $tag
        $isKnownOptionalTag = (-not $isRequiredTag) -and (Test-MapHasKey -Map $replaceByTag -Key $tag)
        $severity = if ($isKnownOptionalTag) { 'WARN' } else { 'ERROR' }
        if ($severity -eq 'ERROR') {
            $status = 'ERROR'
        }

        $unresolvedIssueCode = 'ASB-ASM-SDT-UNRESOLVED-TAG'
        $unresolvedIssueSubject = 'SDT tag'
        if ($isDocxTemplate -and (Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'content-control-tag')) {
            $unresolvedIssueCode = 'ASB-ASM-SDT-UNRESOLVED-LITERAL-TOKEN'
            $unresolvedIssueSubject = 'literal SDT token'
        }

        $issues.Add([ordered]@{
            code = $unresolvedIssueCode
            severity = $severity
            message = "Unresolved $unresolvedIssueSubject '$tag' remained after rendering ($($occurrence.count) occurrence(s); sample locations: $sampleLocationsText)."
            path = $TemplatePath
        })

        $unresolvedSummary.unresolvedOccurrences = [int]$unresolvedSummary.unresolvedOccurrences + [int]$occurrence.count
        $unresolvedSummary.tags += [ordered]@{
            tag = $tag
            count = [int]$occurrence.count
            severity = $severity
            required = $isRequiredTag
            sampleLocations = @($occurrence.locations | Select-Object -First 3)
        }
    }

    $renderStatus = if ($status -eq 'ERROR') { 'ERROR' } elseif (@($issues | Where-Object { $_.severity -eq 'WARN' }).Count -gt 0) { 'WARN' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Render -Status $renderStatus -Details ([ordered]@{
        tagsPopulated = $replaceByTag.Count
        templateKind = $(if ($isDocxTemplate) { 'docx' } else { 'text' })
        docxTemplatePathResolved = $(if ($isDocxTemplate) { [string]$renderDetails.templatePathResolved } else { '' })
        docxOutputPathResolved = $(if ($isDocxTemplate) { [string]$renderDetails.outputPathResolved } else { '' })
        docxTemplateBytesSha256 = $(if ($isDocxTemplate) { [string]$renderDetails.templateBytesSha256 } else { '' })
        docxTemplateLengthBytes = $(if ($isDocxTemplate) { [int64]$renderDetails.templateLengthBytes } else { 0 })
        docxTemplateLastWriteUtc = $(if ($isDocxTemplate) { [string]$renderDetails.templateLastWriteUtc } else { '' })
        docxPartsUpdated = $(if ($isDocxTemplate) { [int]$renderDetails.partsUpdated } else { 0 })
        docxLiteralDatasetTokensExpected = $(if ($isDocxTemplate) { [int]$renderDetails.literalDatasetTokensExpected } else { 0 })
        docxLiteralDatasetTokensDiscovered = $(if ($isDocxTemplate) { [int]$renderDetails.literalDatasetTokensDiscovered } else { 0 })
        docxLiteralDatasetTagsDiscovered = $(if ($isDocxTemplate) { [int]$renderDetails.literalDatasetTagsDiscovered } else { 0 })
        docxLiteralDatasetFragmentHintTags = $(if ($isDocxTemplate) { @($renderDetails.literalDatasetFragmentHintTags) } else { @() })
        docxLiteralDatasetTagStatus = $(if ($isDocxTemplate) { @($renderDetails.literalDatasetTagStatus) } else { @() })
        docxLiteralDatasetTokensPopulated = $(if ($isDocxTemplate) { [int]$renderDetails.literalDatasetTokensPopulated } else { 0 })
        docxLiteralTokensMatched = $(if ($isDocxTemplate) { [int]$renderDetails.literalTokensMatched } else { 0 })
        docxLiteralTokensMatchedScalar = $(if ($isDocxTemplate) { [int]$renderDetails.literalTokensMatchedScalar } else { 0 })
        docxLiteralTokensMatchedTable = $(if ($isDocxTemplate) { [int]$renderDetails.literalTokensMatchedTable } else { 0 })
        docxLiteralTokensMatchedImage = $(if ($isDocxTemplate) { [int]$renderDetails.literalTokensMatchedImage } else { 0 })
        docxDocPropertyLiteralTokensMatched = $(if ($isDocxTemplate) { [int]$renderDetails.docPropertyLiteralTokensMatched } else { 0 })
        docxDocPropControlsExpected = $(if ($isDocxTemplate) { [int]$renderDetails.docPropControlsExpected } else { 0 })
        docxDocPropControlsMatched = $(if ($isDocxTemplate) { [int]$renderDetails.docPropControlsMatched } else { 0 })
        docxDocPropControlsPopulated = $(if ($isDocxTemplate) { [int]$renderDetails.docPropControlsPopulated } else { 0 })
        docxDocPropertyFieldsDiscovered = $(if ($isDocxTemplate) { [int]$renderDetails.docPropertyFieldsDiscovered } else { 0 })
        docxDocPropertyFieldsPopulated = $(if ($isDocxTemplate) { [int]$renderDetails.docPropertyFieldsPopulated } else { 0 })
        docxControlsDiscovered = $(if ($isDocxTemplate) { [int]$renderDetails.controlsDiscovered } else { 0 })
        docxControlsDiscoveredMapped = $(if ($isDocxTemplate) { [int]$renderDetails.controlsDiscoveredMapped } else { 0 })
        docxControlsDiscoveredUnmapped = $(if ($isDocxTemplate) { [int]$renderDetails.controlsDiscoveredUnmapped } else { 0 })
        docxTaggedControlsMatched = $(if ($isDocxTemplate) { [int]$renderDetails.taggedControlsMatched } else { 0 })
        docxControlsPopulated = $(if ($isDocxTemplate) { [int]$renderDetails.controlsPopulated } else { 0 })
        docxDiscoveredTaggedControls = $(if ($isDocxTemplate) { @($renderDetails.discoveredTaggedControls) } else { @() })
        docxDiscoveredUnmappedTaggedControls = $(if ($isDocxTemplate) { @($renderDetails.discoveredUnmappedTaggedControls) } else { @() })
        docxUnmatchedTaggedControls = $(if ($isDocxTemplate) { @($renderDetails.unmatchedTaggedControls) } else { @() })
        docxDocPropMappedTags = $(if ($isDocxTemplate) { @($renderDetails.docPropMappedTags) } else { @() })
        docxSupportRegion = $(if ($isDocxTemplate -and $null -ne $renderDetails.supportRegion) { $renderDetails.supportRegion } else { [ordered]@{ id = ''; label = ''; displayName = ''; tierId = ''; tier = ''; workingHours = ''; sidecarPath = '' } })
        docxPartErrors = $(if ($isDocxTemplate) { @($renderDetails.partErrors) } else { @() })
        docxUnresolvedLiteralTokens = $(if ($isDocxTemplate) { @($renderDetails.unresolvedLiteralTokens) } else { @() })
        docxLiteralTagDiagnosticsSummary = $(if ($isDocxTemplate) { $renderDetails.literalTagDiagnosticsSummary } else { [ordered]@{ totalEntries = 0; hitEntries = 0; zeroHitEntries = 0; distinctTagCount = 0; distinctPartCount = 0; topEntryLimit = 0; topEntries = @(); zeroHitTagSampleLimit = 0; zeroHitTagSamples = @() } })
        docxLiteralTagDiagnosticsCount = $(if ($isDocxTemplate) { [int]$renderDetails.literalTagDiagnosticsSummary.totalEntries } else { 0 })
        docxLiteralTagDiagnosticsHitCount = $(if ($isDocxTemplate) { [int]$renderDetails.literalTagDiagnosticsSummary.hitEntries } else { 0 })
        docxLiteralTagHitSummary = $(if ($isDocxTemplate) { @($renderDetails.literalTagHitSummary) } else { @() })
        docxLiteralPartHitSummary = $(if ($isDocxTemplate) { @($renderDetails.literalPartHitSummary) } else { @() })
        docxMatchMode = $(if ($isDocxTemplate) { [string]$renderDetails.docxMatchMode } else { '' })
        docxUpdateFieldsOnOpenEnabled = $(if ($isDocxTemplate) { [bool]$renderDetails.updateFieldsOnOpenEnabled } else { $false })
        docxUpdateFieldsOnOpenReason = $(if ($isDocxTemplate) { [string]$renderDetails.updateFieldsOnOpenReason } else { '' })
        docxUpdateFieldsOnOpenPreparation = $(if ($isDocxTemplate) { $renderDetails.updateFieldsOnOpenPreparation } else { [ordered]@{} })
        docxUpdateFieldsOnOpenFinal = $(if ($isDocxTemplate) { $renderDetails.updateFieldsOnOpenFinal } else { [ordered]@{} })
        docxTocRefreshStatus = $(if ($isDocxTemplate) { [string]$renderDetails.tocRefreshStatus } else { '' })
        docxTocRefreshMethod = $(if ($isDocxTemplate) { [string]$renderDetails.tocRefreshMethod } else { '' })
        docxTocRefreshMessage = $(if ($isDocxTemplate) { [string]$renderDetails.tocRefreshMessage } else { '' })
        docxTocRefreshDiagnostics = $(if ($isDocxTemplate) { $renderDetails.tocRefreshDiagnostics } else { [ordered]@{} })
        unresolvedTokenPolicy = [string]$UnresolvedTokenPolicy
        unresolved = $unresolvedSummary
        unresolvedPolicy = [ordered]@{
            requiredOrUnknown = 'ERROR'
            optionalMapped = 'WARN'
        }
    })

    Start-RenderStage -Stage $stageMap.Finalize
    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }
    if (-not $isDocxTemplate) {
        Set-Content -LiteralPath $OutputPath -Value $rendered -Encoding UTF8
    }
    $outputs.Add([ordered]@{ path = $OutputPath; type = $(if ($isDocxTemplate) { 'docx/template-rendered' } else { 'text/template-rendered' }) })
    $finalizeStatus = if ($status -eq 'ERROR') { 'ERROR' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Finalize -Status $finalizeStatus -Details ([ordered]@{ outputPath = $OutputPath })
}
catch {
    $status = 'ERROR'
    $exception = $_
    $diagnostics = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$exception.Exception.Message)) { $diagnostics.Add("message=$([string]$exception.Exception.Message)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$exception.InvocationInfo.PositionMessage)) { $diagnostics.Add("position=$([string]$exception.InvocationInfo.PositionMessage)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$exception.ScriptStackTrace)) { $diagnostics.Add("stack=$([string]$exception.ScriptStackTrace)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentStageName)) { $diagnostics.Add("stage=$currentStageName") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentTag)) { $diagnostics.Add("tag=$currentTag") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentDatasetRelativePath)) { $diagnostics.Add("dataset=$currentDatasetRelativePath") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentDatasetPath)) { $diagnostics.Add("datasetPath=$currentDatasetPath") }
    if (-not [string]::IsNullOrWhiteSpace([string]$currentSelectorChain)) { $diagnostics.Add("selectors=$currentSelectorChain") }
    $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-UNHANDLED'; severity = 'ERROR'; message = ($diagnostics -join ' | '); path = $(if (-not [string]::IsNullOrWhiteSpace([string]$currentDatasetPath)) { $currentDatasetPath } else { $null }) })

    foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
        $stage = $stageMap[$stageName]
        if ($null -ne $stage.startedUtc -and $null -eq $stage.completedUtc) {
            Complete-RenderStage -Stage $stage -Status 'ERROR'
            break
        }
    }
}

if ($status -ne 'ERROR' -and @($issues | Where-Object { $_.severity -eq 'WARN' }).Count -gt 0) {
    $status = 'PARTIAL'
}

$report = [ordered]@{
    schemaVersion = 1
    status = $status
    startedUtc = $startedUtc
    completedUtc = Get-UtcTimestamp
    bundleId = $bundleId
    stages = $stageList
    issues = $issues
    matches = $matches
    outputs = $outputs
}

$reportJson = $report | ConvertTo-Json -Depth 10
$renderReportValidation = Test-AssemblerSchemaJson -JsonText $reportJson -SchemaPath $renderReportSchemaPath -DocumentLabel 'assembler-sdt-render-report'
if (-not $renderReportValidation.isValid) {
    Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-RENDERREPORT-INVALID' -Message ([string]$renderReportValidation.message) -PathValue $(if ($ReportPath) { $ReportPath } else { '<stdout>' })
    foreach ($stageName in @('Finalize','Render','Transform','Validate','Load')) {
        $stage = $stageMap[$stageName]
        if ($stage.status -ne 'SKIPPED') {
            $stage.status = 'ERROR'
            break
        }
    }
    $status = 'ERROR'
    $report.status = $status
    $report.issues = $issues
    $report.completedUtc = Get-UtcTimestamp
    $reportJson = $report | ConvertTo-Json -Depth 10
}
if ($ReportPath) {
    $reportDir = Split-Path -Path $ReportPath -Parent
    if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }
    Set-Content -LiteralPath $ReportPath -Value $reportJson -Encoding UTF8
}

$reportJson
if ($status -eq 'ERROR') {
    exit 1
}






