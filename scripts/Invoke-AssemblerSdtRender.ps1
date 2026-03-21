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
    [Parameter(Mandatory = $false)][string]$ContractsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerSchemaValidation.psm1') -Force

function Get-UtcTimestamp { (Get-Date).ToUniversalTime().ToString('o') }

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }

    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
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
        (Join-Path $RepoRoot '.deps/contracts'),
        (Join-Path $RepoRoot 'export/repo-ready/contracts')
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
    foreach ($segment in $Selector.Split('.')) {
        if ($null -eq $current) {
            return $null
        }

        if ($current -is [hashtable]) {
            if (-not $current.ContainsKey($segment)) {
                return $null
            }
            $current = $current[$segment]
            continue
        }

        if ($current -is [System.Collections.IList]) {
            [int]$idx = 0
            if (-not [int]::TryParse($segment, [ref]$idx)) {
                return $null
            }
            if ($idx -lt 0 -or $idx -ge $current.Count) {
                return $null
            }
            $current = $current[$idx]
            continue
        }

        return $null
    }

    return $current
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

function Test-DatasetEnvelope {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Dataset,
        [Parameter(Mandatory = $true)][string]$DatasetPath
    )

    # Validation rules are sourced from:
    # export/repo-ready/contracts/standards/architecture.direct-v1.collector-contracts.md
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
        $resolved = Resolve-Selector -InputObject $resolved -Selector ([string]$selector)
        if ($null -eq $resolved) {
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
                $resolved = Resolve-Selector -InputObject $summaryItem -Selector ([string]$selector)
            }

            if ($null -eq $resolved) {
                return [ordered]@{ value = $null; selectorFailed = $true }
            }
        }
    }

    return [ordered]@{ value = $resolved; selectorFailed = $false }
}

function Convert-CellValueToString {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [ValueType]) { return [string]$Value }

    return ($Value | ConvertTo-Json -Depth 10 -Compress)
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

function Convert-TableRowsForTag {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    switch ($Tag) {
        'DE_DRIVES_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Slot = $_.slot
                        'Media Type' = $_.driveMediaType
                        Raw = Format-SizeHuman -Bytes $_.rawCapacityBytes
                        Usable = Format-SizeHuman -Bytes $_.usableCapacityBytes
                        Firmware = $_.firmwareVersion
                        Status = $_.status
                        SerialNumber = $_.serialNumber
                    }
                }
            )
        }
        'DE_STORAGE_CONTAINERS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = $_.name
                        ContainerType = $_.containerType
                        RaidLevel = $_.raidLevel
                        DriveMediaType = $_.driveMediaType
                        Total = Format-SizeHuman -Bytes $_.totalBytes
                        Used = Format-SizeHuman -Bytes $_.usedBytes
                        Free = Format-SizeHuman -Bytes $_.freeBytes
                        State = $_.state
                        Status = $_.status
                    }
                }
            )
        }
        'DE_VOLUMES_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = $_.name
                        Size = Format-SizeHuman -Bytes $_.sizeBytes
                        Status = $_.status
                        RaidLevel = $_.raidLevel
                        Container = $_.containerName
                    }
                }
            )
        }
        'DE_CONTROLLERS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Controller = $_.controllerLabel
                        Slot = $_.controllerSlot
                        Status = $_.status
                        AppVersion = $_.appVersion
                        BootVersion = $_.bootVersion
                        SerialNumber = $_.serialNumber
                    }
                }
            )
        }
        'DE_MANAGEMENT_INTERFACES_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Controller = $_.controllerLabel
                        Slot = $_.controllerSlot
                        Port = $_.portLabel
                        Interface = $_.interfaceName
                        LinkStatus = $_.linkStatus
                        Address = $_.ipv4Address
                        Mask = $_.ipv4SubnetMask
                    }
                }
            )
        }
        'DE_TRANSPORT_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        SystemId = $_.systemId
                        ActiveTransport = $_.activeTransport
                        IscsiIqn = $_.iscsiIqn
                    }
                }
            )
        }
        'DE_HOSTPORTS_ISCSI_TABLE_JSON' {
            return @(
                $Rows |
                    Where-Object { [string]$_.transport -eq 'iscsi' } |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            Controller = $_.controllerLabel
                            Slot = $_.controllerSlot
                            Port = $_.portLabel
                            Channel = $_.channel
                            LinkStatus = $_.linkStatus
                            Address = $_.ipv4Address
                            Mask = $_.ipv4SubnetMask
                            Gateway = $_.ipv4Gateway
                            TcpPort = $_.tcpPort
                            IQN = $_.iqn
                        }
                    }
            )
        }
        'DE_HOSTPORTS_FC_TABLE_JSON' {
            return @(
                $Rows |
                    Where-Object { [string]$_.transport -eq 'fc' } |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            Controller = $_.controllerLabel
                            Slot = $_.controllerSlot
                            Port = $_.portLabel
                            Channel = $_.channel
                            LinkStatus = $_.linkStatus
                            CurrentSpeed = $_.currentSpeed
                            MaxSpeed = $_.maxSpeed
                            PortWWN = $_.portWwn
                            NodeWWN = $_.nodeWwn
                        }
                    }
            )
        }
        'DE_DNS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        SystemId = $_.systemId
                        Acquisition = $_.dnsAcquisitionType
                        DnsServers = ($_.dnsServers -join ', ')
                        DhcpServers = ($_.dhcpAcquiredServers -join ', ')
                    }
                }
            )
        }
        'DE_TIME_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        SystemId = $_.systemId
                        Acquisition = $_.ntpAcquisitionType
                        NtpServers = ($_.ntpServers -join ', ')
                        DhcpServers = ($_.dhcpAcquiredServers -join ', ')
                        DefaultRouter = $_.ipv4DefaultRouter
                    }
                }
            )
        }
        'DE_HOSTS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = $_.name
                        HostId = $_.id
                        HostType = $_.hostTypeName
                        ClusterRef = $_.clusterRef
                    }
                }
            )
        }
        'DE_HOST_GROUPS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = $_.name
                        GroupId = $_.id
                        Members = ($_.memberNames -join ', ')
                    }
                }
            )
        }
        'DE_HOSTS_TO_HOST_GROUPS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Host = $_.hostName
                        HostGroup = $_.hostGroupName
                        HostType = $_.hostType
                        KeyType = $_.hostGroupKeyType
                    }
                }
            )
        }
        'DE_HOST_GROUPS_TO_VOLUMES_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        HostGroup = $_.hostGroupName
                        Volume = $_.volumeName
                        Lun = $_.lun
                        MappingRef = $_.mappingRef
                    }
                }
            )
        }
        'DE_HOSTS_TO_VOLUMES_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Host = $_.hostName
                        Volume = $_.volumeName
                        Lun = $_.lun
                        MappingRef = $_.mappingRef
                    }
                }
            )
        }
        'DE_VOLUME_MAPPINGS_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Volume = $_.volumeName
                        Lun = $_.lun
                        TargetType = $_.mappedToType
                        TargetRef = $_.mappedToRef
                        MappingRef = $_.mappingRef
                    }
                }
            )
        }
        'DE_SYSTEM_ASUP_TABLE_JSON' {
            return @(
                $Rows | ForEach-Object {
                    [pscustomobject][ordered]@{
                        AsupEnabled = $_.asupEnabled
                        OnDemandEnabled = $_.onDemandEnabled
                        RemoteDiags = $_.remoteDiagsEnabled
                        DeliveryMethod = $_.deliveryMethod
                        RoutingType = $_.routingType
                        MaxHttps = Format-SizeHuman -Bytes $_.maxSizeLimitHttps
                        MaxSmtp = Format-SizeHuman -Bytes $_.maxSizeLimitSmtp
                    }
                }
            )
        }
        'DE_CAPABILITIES_SUMMARY_TABLE_JSON' {
            return @(
                $Rows |
                    Where-Object { $_.includeInMainBody -eq $true } |
                    Sort-Object -Property sortOrder |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            Feature = $_.displayName
                            Category = $_.category
                            State = $_.state
                            Compliance = $_.compliance
                            Entitlement = $_.entitlement
                        }
                    }
            )
        }
        'DE_CAPABILITIES_KEY_FEATURES_TABLE_JSON' {
            return @(
                $Rows |
                    Where-Object { $_.includeInMainBody -eq $true } |
                    Sort-Object -Property sortOrder |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            Feature = $_.displayName
                            State = $_.state
                            License = $_.licenseType
                            Notes = $_.notes
                        }
                    }
            )
        }
        'DE_CAPABILITIES_LIMITS_TABLE_JSON' {
            return @(
                $Rows |
                    Where-Object { $_.limit -ne $null -or $_.limitUsed -ne $null -or $_.includeInAppendix -eq $true } |
                    Sort-Object -Property sortOrder |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            Feature = $_.displayName
                            Limit = $_.limit
                            Used = $_.limitUsed
                            LimitState = $_.limitState
                            Entitlement = $_.entitlement
                        }
                    }
            )
        }
        default {
            return $Rows
        }
    }
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

function Convert-ValueToTableString {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $false)][string]$Tag
    )

    if ($null -eq $Value) { return '' }

    $rows = @()
    if ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) {
            if ($item -is [hashtable]) {
                $row = [ordered]@{}
                foreach ($key in $item.Keys) {
                    $row[[string]$key] = Convert-CellValueToString -Value $item[$key]
                }
                $rows += [pscustomobject]$row
            }
            else {
                $rows += [pscustomobject]([ordered]@{ value = Convert-CellValueToString -Value $item })
            }
        }
    }
    elseif ($Value -is [hashtable]) {
        $row = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $row[[string]$key] = Convert-CellValueToString -Value $Value[$key]
        }
        $rows = @([pscustomobject]$row)
    }

    if (@($rows).Count -eq 0) {
        return (Convert-CellValueToString -Value $Value)
    }

    $rows = @(Convert-TableRowsForTag -Tag $Tag -Rows $rows)

    $allColumns = @($rows[0].PSObject.Properties.Name)
    $displayColumns = Get-DisplayColumnsForTable -Columns $allColumns

    if (@($displayColumns).Count -gt 0) {
        return (($rows | Select-Object -Property $displayColumns | Format-Table -AutoSize | Out-String).TrimEnd())
    }

    return (($rows | Format-Table -AutoSize | Out-String).TrimEnd())
}

function Convert-ValueToString {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $false)][string]$Tag
    )

    if ($null -eq $Value) {
        return ''
    }
    if (-not [string]::IsNullOrWhiteSpace($Tag) -and $Tag.EndsWith('_TABLE_JSON')) {
        return (Convert-ValueToTableString -Value $Value -Tag $Tag)
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [ValueType]) {
        return [string]$Value
    }

    return ($Value | ConvertTo-Json -Depth 10 -Compress)
}

$startedUtc = Get-UtcTimestamp
$issues = [System.Collections.Generic.List[hashtable]]::new()
$stageList = [System.Collections.Generic.List[hashtable]]::new()
$outputs = [System.Collections.Generic.List[hashtable]]::new()
$matches = [System.Collections.Generic.List[hashtable]]::new()
$status = 'OK'
$bundleId = $null

$stageMap = [ordered]@{}
foreach ($stageName in @('Load','Validate','Transform','Render','Finalize')) {
    $stage = [ordered]@{ name = $stageName; status = 'SKIPPED'; startedUtc = $null; completedUtc = $null; details = $null }
    $stageMap[$stageName] = $stage
    $stageList.Add($stage)
}

function Start-RenderStage {
    param([Parameter(Mandatory = $true)][hashtable]$Stage)
    $Stage.startedUtc = Get-UtcTimestamp
    $Stage.completedUtc = $null
    $Stage.status = 'OK'
}

function Complete-RenderStage {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][hashtable]$Details
    )
    $Stage.status = $Status
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
    $renderReportSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.render-report.schema.v1.json'

    Start-RenderStage -Stage $stageMap.Load
    $mapping = Read-JsonFile -Path $MappingPath
    $mappingSchema = Read-JsonFile -Path $mappingSchemaPath
    $templateText = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8

    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-JsonFile -Path $manifestPath
        $bundleId = $manifest.bundleId
    }
    Complete-RenderStage -Stage $stageMap.Load -Status 'OK' -Details ([ordered]@{ mappingPath = $MappingPath; templatePath = $TemplatePath; contractsRoot = $effectiveContractsRoot; mappingSchemaPath = $mappingSchemaPath })

    Start-RenderStage -Stage $stageMap.Validate
    $mappingValidation = Test-AssemblerSchemaFile -DocumentPath $MappingPath -SchemaPath $mappingSchemaPath
    if (-not $mappingValidation.isValid) {
        Add-SchemaValidationIssue -Code 'ASB-ASM-SCHEMA-MAPPING-INVALID' -Message ([string]$mappingValidation.message) -PathValue $MappingPath
        Complete-RenderStage -Stage $stageMap.Validate -Status 'ERROR'
        $status = 'ERROR'
        throw 'Mapping schema validation failed.'
    }
    Complete-RenderStage -Stage $stageMap.Validate -Status 'OK' -Details ([ordered]@{ mappingCount = @($mapping.mappings).Count })

    Start-RenderStage -Stage $stageMap.Transform
    $replaceByTag = @{}
    foreach ($entry in @($mapping.mappings)) {
        $tag = if ($entry.ContainsKey('sdtTag')) { [string]$entry.sdtTag } elseif ($entry.ContainsKey('target') -and $entry.target.ContainsKey('sdtTag')) { [string]$entry.target.sdtTag } else { '' }
        if ([string]::IsNullOrWhiteSpace($tag)) {
            $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-MAPPING-NOTAG'; severity = 'WARN'; message = "Skipping mapping with missing sdtTag for dataset '$($entry.dataset)'"; path = $MappingPath })
            continue
        }

        $datasetResolution = Resolve-DatasetFilePath -BundleRoot $BundleRoot -DatasetRelativePath ([string]$entry.dataset) -TechId ([string]$mapping.techId)
        $datasetPath = [string]$datasetResolution.path
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
        $selectors = @($entry.selectors)
        if (@($selectors).Count -gt 0) {
            $selectorResult = Resolve-SelectorWithSummaryCompatibility -Dataset $dataset -Selectors @($selectors | ForEach-Object { [string]$_ }) -DatasetPath $datasetPath
            $resolved = $selectorResult.value
            $selectorFailed = [bool]$selectorResult.selectorFailed

            if ($selectorFailed) {
                $selectorChain = ($selectors | ForEach-Object { [string]$_ }) -join ' -> '
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

        $resolvedText = Convert-ValueToString -Value $resolved -Tag $tag
        $replaceByTag[$tag] = $resolvedText
        $valuePreview = if ($resolvedText.Length -gt 80) { $resolvedText.Substring(0, 80) + '...' } else { $resolvedText }
        $matches.Add([ordered]@{ tag = $tag; dataset = [string]$entry.dataset; selector = if (@($selectors).Count -gt 0) { (($selectors | ForEach-Object { [string]$_ }) -join ' -> ') } else { '' }; valuePreview = $valuePreview })
    }

    $transformStatus = if ($status -eq 'ERROR') { 'ERROR' } elseif (@($issues | Where-Object { $_.severity -eq 'WARN' }).Count -gt 0) { 'WARN' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Transform -Status $transformStatus -Details ([ordered]@{ tagsResolved = $replaceByTag.Count; matches = $matches.Count })

    Start-RenderStage -Stage $stageMap.Render
    $rendered = $templateText
    foreach ($tag in $replaceByTag.Keys) {
        $token = "<<SDT:$tag>>"
        $rendered = $rendered.Replace($token, [string]$replaceByTag[$tag])
    }
    $renderStatus = if ($status -eq 'ERROR') { 'ERROR' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Render -Status $renderStatus -Details ([ordered]@{ tagsPopulated = $replaceByTag.Count })

    Start-RenderStage -Stage $stageMap.Finalize
    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $rendered -Encoding UTF8
    $outputs.Add([ordered]@{ path = $OutputPath; type = 'text/template-rendered' })
    $finalizeStatus = if ($status -eq 'ERROR') { 'ERROR' } else { 'OK' }
    Complete-RenderStage -Stage $stageMap.Finalize -Status $finalizeStatus -Details ([ordered]@{ outputPath = $OutputPath })
}
catch {
    $status = 'ERROR'
    $issues.Add([ordered]@{ code = 'ASB-ASM-SDT-UNHANDLED'; severity = 'ERROR'; message = $_.Exception.Message; path = $null })

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
        if ($null -ne $stage.startedUtc) {
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
