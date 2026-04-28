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
    [Parameter(Mandatory = $false)][switch]$AnnotateResolvedTags,
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
        [Parameter(Mandatory = $false)][string]$Classification
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

function Enable-DocxUpdateFieldsOnOpen {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive
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
        reason = 'word/settings.xml updated with w:updateFields=true'
    }
}

function Try-RefreshDocxTableOfContents {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        return [ordered]@{
            status = 'skipped'
            method = 'none'
            message = "Output DOCX not found: $OutputPath"
        }
    }

    if (-not $IsWindows) {
        return [ordered]@{
            status = 'deferred'
            method = 'updateFieldsOnOpen'
            message = 'Word automation is unavailable on non-Windows platforms.'
        }
    }

    $word = $null
    $document = $null
    try {
        $word = New-Object -ComObject Word.Application -ErrorAction Stop
        $word.Visible = $false
        $word.ScreenUpdating = $false
        $word.DisplayAlerts = 0

        $document = $word.Documents.Open($OutputPath)
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

        return [ordered]@{
            status = 'updated'
            method = 'word-com'
            message = "Updated $tocCount table(s) of contents via Word automation."
        }
    }
    catch {
        return [ordered]@{
            status = 'deferred'
            method = 'updateFieldsOnOpen'
            message = [string]$_.Exception.Message
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
        [Parameter(Mandatory = $false)][string]$DocClassification
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
        [Parameter(Mandatory = $false)][string]$DocClassification
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
        @{ name = 'ClassificationContentMarkingHeaderText'; value = $DocClassification }
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
        $literalDatasetTokensExpected = @($literalDatasetTokenLookup.Keys).Count
        $literalDatasetTokensDiscovered = 0
        $literalDatasetTagsDiscovered = 0
        $literalTokensMatched = 0
        $literalTokensMatchedScalar = 0
        $literalTokensMatchedTable = 0
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
        $contentControlReplaceByTag = Get-DocxContentControlReplacementMap -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment -DocDocumentReference $DocDocumentReference -DocVersion $DocVersion -DocConfigSnapDate $DocConfigSnapDate -DocReferenceId $DocReferenceId -DocClassification $DocClassification
        $docPropertyFieldReplaceByName = Get-DocxDocPropertyFieldReplacementMap -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment -DocDocumentReference $DocDocumentReference -DocVersion $DocVersion -DocConfigSnapDate $DocConfigSnapDate -DocReferenceId $DocReferenceId -DocClassification $DocClassification
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

        Update-DocxMetadataProperties -Archive $archive -Title $DocTitle -Customer $DocCustomer -CustomerAbbr $DocCustomerAbbr -Location $DocLocation -Subsidiary $DocSubsidiary -Environment $DocEnvironment -DocumentReference $DocDocumentReference -Version $DocVersion -ConfigSnapDate $DocConfigSnapDate -ReferenceId $DocReferenceId -Classification $DocClassification
        $updateFieldsOnOpenResult = Enable-DocxUpdateFieldsOnOpen -Archive $archive

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
            partErrors = @($partErrors)
            literalTagDiagnostics = $literalTagDiagnostics.ToArray()
            literalTagHitSummary = @($literalTagHitSummary)
            literalPartHitSummary = @($literalPartHitSummary)
            updateFieldsOnOpenEnabled = [bool]$updateFieldsOnOpenResult.applied
            updateFieldsOnOpenReason = [string]$updateFieldsOnOpenResult.reason
        }
    }
    finally {
        $archive.Dispose()
    }

    if ($null -ne $renderResult) {
        $tocRefreshResult = Try-RefreshDocxTableOfContents -OutputPath $OutputPath
        $renderResult.tocRefreshStatus = [string]$tocRefreshResult.status
        $renderResult.tocRefreshMethod = [string]$tocRefreshResult.method
        $renderResult.tocRefreshMessage = [string]$tocRefreshResult.message
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

    foreach ($legacyKey in @('projectionRef', 'renderAs', 'view', 'renderMode', 'structuredValuePolicy', 'missingProjectionPolicy')) {
        if (-not $hint.Contains($legacyKey) -and (Test-MapHasKey -Map $MappingEntry -Key $legacyKey) -and -not [string]::IsNullOrWhiteSpace([string]$MappingEntry[$legacyKey])) {
            $hint[$legacyKey] = [string]$MappingEntry[$legacyKey]
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
        $view = if (Test-MapHasKey -Map $RenderHint -Key 'view') { [string]$RenderHint['view'] } else { '' }
        if (
            $renderAs -eq 'table' -or
            -not [string]::IsNullOrWhiteSpace($projectionRef) -or
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
        Add-RenderIssue -Code 'ASB-ASM-SDT-STRUCTURED-VALUE-RENDERMODE-REQUIRED' -Severity 'WARN' -Message "Tag '$Tag' resolved to a structured value but renderMode '$renderMode' does not permit raw JSON output. Declare renderMode 'table', 'json-evidence', or 'json-debug'." -PathValue $script:currentDatasetPath
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
    $renderReportSchemaPath = Join-Path (Join-Path $effectiveContractsRoot 'standards/assembler') 'assembler.render-report.schema.v1.json'

    Start-RenderStage -Stage $stageMap.Load
    $mapping = Read-JsonFile -Path $MappingPath
    $projectionContractPath = Resolve-ProjectionContractPath -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $projectionContract = Read-ProjectionContractFile -Path $projectionContractPath
    $projectionDefinitions = Get-ProjectionDefinitions -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
    $projectionAliases = Get-ProjectionAliases -ContractsRoot $effectiveContractsRoot -TechId ([string]$mapping.techId)
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
    Complete-RenderStage -Stage $stageMap.Load -Status 'OK' -Details ([ordered]@{ mappingPath = $MappingPath; templatePath = $TemplatePath; templateExtension = $templateExtension; contractsRoot = $effectiveContractsRoot; mappingSchemaPath = $mappingSchemaPath; projectionContractPath = $projectionContractPath; projectionSchemaPath = $projectionSchemaPath })

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
    Complete-RenderStage -Stage $stageMap.Validate -Status 'OK' -Details ([ordered]@{ mappingCount = @($mapping.mappings).Count; projectionCount = @($projectionDefinitions.Keys).Count })

    Start-RenderStage -Stage $stageMap.Transform
    $replaceByTag = @{}
    $docxTableByTag = @{}
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
        $docxRender = Render-DocxTemplate -TemplatePath $resolvedTemplatePath -OutputPath $OutputPath -ReplaceByTag $replaceByTag -TableByTag $docxTableByTag -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment -DocDocumentReference $DocDocumentReference -DocVersion $DocVersion -DocConfigSnapDate $DocConfigSnapDate -DocReferenceId $DocReferenceId -DocClassification $DocClassification -DocxMatchMode $DocxMatchMode -UnresolvedTokenPolicy $UnresolvedTokenPolicy
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
        $renderDetails.partErrors = @($docxRender.partErrors)
        $renderDetails.literalTagDiagnostics = $docxRender.literalTagDiagnostics
        $renderDetails.literalTagDiagnosticsSummary = Get-LiteralTagDiagnosticsSummary -Diagnostics $docxRender.literalTagDiagnostics -TopEntries 25 -TopZeroHitTags 8 -TopInspectedPartsPerTag 4
        $renderDetails.literalTagHitSummary = @($docxRender.literalTagHitSummary)
        $renderDetails.literalPartHitSummary = @($docxRender.literalPartHitSummary)
        $renderDetails.unresolvedLiteralTokens = @($docxUnresolvedLiteralByTag.Keys | Sort-Object)
        $renderDetails.docxMatchMode = [string]$DocxMatchMode
        $renderDetails.updateFieldsOnOpenEnabled = $(if (Test-MapHasKey -Map $docxRender -Key 'updateFieldsOnOpenEnabled') { [bool]$docxRender.updateFieldsOnOpenEnabled } else { $false })
        $renderDetails.updateFieldsOnOpenReason = $(if (Test-MapHasKey -Map $docxRender -Key 'updateFieldsOnOpenReason') { [string]$docxRender.updateFieldsOnOpenReason } else { '' })
        $renderDetails.tocRefreshStatus = $(if (Test-MapHasKey -Map $docxRender -Key 'tocRefreshStatus') { [string]$docxRender.tocRefreshStatus } else { '' })
        $renderDetails.tocRefreshMethod = $(if (Test-MapHasKey -Map $docxRender -Key 'tocRefreshMethod') { [string]$docxRender.tocRefreshMethod } else { '' })
        $renderDetails.tocRefreshMessage = $(if (Test-MapHasKey -Map $docxRender -Key 'tocRefreshMessage') { [string]$docxRender.tocRefreshMessage } else { '' })
        $expectedDocPropertyControlCount = [int]$renderDetails.docPropControlsExpected
        $controlsPopulatedCount = [int]$renderDetails.docPropControlsPopulated
        $docPropertyFieldPopulatedCount = [int]$renderDetails.docPropertyFieldsPopulated
        $docPropertyPopulationCount = $controlsPopulatedCount + $docPropertyFieldPopulatedCount
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
                message = "DOCX document-property render expected document placeholders but none were populated. docxMatchMode='$DocxMatchMode'; discoveredControls=$($renderDetails.controlsDiscovered); discoveredMappedControls=$($renderDetails.controlsDiscoveredMapped); discoveredUnmappedControls=$($renderDetails.controlsDiscoveredUnmapped); discoveredDocPropertyFields=$($renderDetails.docPropertyFieldsDiscovered); partErrorCount=$(@($renderDetails.partErrors).Count); taggedControlsMatched=$($renderDetails.taggedControlsMatched); controlsPopulated=$controlsPopulatedCount; docPropertyFieldsPopulated=$docPropertyFieldPopulatedCount; docPropertyPopulated=$docPropertyPopulationCount; docPropertyControlTags=$expectedDocPropertyControlCount; docPropValuesSupplied=$docPropValuesSupplied; sampleDocPropertyTags=$sampleMatchedTagsText; policySeverity=$docPropNoPopulationSeverity"
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
        if ([bool]$entry.required) {
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
        docxTocRefreshStatus = $(if ($isDocxTemplate) { [string]$renderDetails.tocRefreshStatus } else { '' })
        docxTocRefreshMethod = $(if ($isDocxTemplate) { [string]$renderDetails.tocRefreshMethod } else { '' })
        docxTocRefreshMessage = $(if ($isDocxTemplate) { [string]$renderDetails.tocRefreshMessage } else { '' })
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






