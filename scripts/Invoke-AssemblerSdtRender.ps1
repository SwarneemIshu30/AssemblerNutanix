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
    [Parameter(Mandatory = $false)][switch]$AnnotateResolvedTags,
    [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'content-control-tag',
    [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerSchemaValidation.psm1') -Force
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
        $Archive.Entries | Where-Object {
            $fullName = [string]$_.FullName
            $fullName -eq 'word/document.xml' -or
            $fullName -match '^word/header\d*\.xml$' -or
            $fullName -match '^word/footer\d*\.xml$'
        }
    )
}

function Set-ZipEntryText {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchiveEntry]$Entry,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $stream = $Entry.Open()
    try {
        $stream.SetLength(0)
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
        [Parameter(Mandatory = $false)][string]$Environment
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
        Set-ZipEntryText -Entry $coreEntry -Text $coreXml.OuterXml
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

    Set-ZipEntryText -Entry $customEntry -Text $customXml.OuterXml
}

function Get-WordTableStyleId {
    param(
        [Parameter(Mandatory = $false)][string]$StylesXmlText,
        [Parameter(Mandatory = $true)][string]$StyleName
    )

    if ([string]::IsNullOrWhiteSpace($StylesXmlText)) { return '' }
    try {
        $doc = [xml]$StylesXmlText
        $nsMgr = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
        $nsMgr.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $styleNode = $doc.SelectSingleNode("//w:style[@w:type='table'][w:name[@w:val='$StyleName']]", $nsMgr)
        if ($null -eq $styleNode) { return '' }

        $idAttr = $styleNode.Attributes.GetNamedItem('styleId', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        if ($null -eq $idAttr) { return '' }
        return [string]$idAttr.Value
    }
    catch {
        return ''
    }
}

function ConvertTo-WordXmlEscapedText {
    param([Parameter(Mandatory = $false)][string]$Text)
    return [System.Security.SecurityElement]::Escape([string]$Text)
}

function Convert-TableModelToWordTableXml {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$TableModel,
        [Parameter(Mandatory = $false)][string]$TableStyleId
    )

    $displayColumns = @($TableModel.displayColumns | ForEach-Object { [string]$_ })
    $rows = @($TableModel.rows)
    if (@($displayColumns).Count -eq 0 -or @($rows).Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<w:tbl>')
    [void]$sb.Append('<w:tblPr>')
    if (-not [string]::IsNullOrWhiteSpace($TableStyleId)) {
        [void]$sb.Append("<w:tblStyle w:val=""$(ConvertTo-WordXmlEscapedText -Text $TableStyleId)""/>")
    }
    [void]$sb.Append('<w:tblW w:w="0" w:type="auto"/>')
    [void]$sb.Append('<w:tblLook w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="1" w:val="04A0"/>')
    [void]$sb.Append('</w:tblPr>')

    [void]$sb.Append('<w:tr>')
    foreach ($columnName in $displayColumns) {
        [void]$sb.Append('<w:tc><w:p><w:r><w:t>')
        [void]$sb.Append((ConvertTo-WordXmlEscapedText -Text $columnName))
        [void]$sb.Append('</w:t></w:r></w:p></w:tc>')
    }
    [void]$sb.Append('</w:tr>')

    foreach ($row in $rows) {
        [void]$sb.Append('<w:tr>')
        foreach ($columnName in $displayColumns) {
            $cellValue = ''
            $property = $row.PSObject.Properties[$columnName]
            if ($null -ne $property -and $null -ne $property.Value) {
                $cellValue = [string]$property.Value
            }
            [void]$sb.Append('<w:tc><w:p><w:r><w:t xml:space="preserve">')
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

    $escapedTag = [regex]::Escape([string]$Tag)
    $rawToken = "<<SDT:\\s*$escapedTag\\s*>>"
    $escapedToken = "&lt;&lt;SDT:\\s*$escapedTag\\s*&gt;&gt;"
    $paragraphPattern = "(?s)<w:p\b[^>]*>.*?($rawToken|$escapedToken).*?</w:p>"
    return ([regex]::Replace($XmlText, $paragraphPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $BlockXml }))
}

function Replace-LiteralSdtTokenText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    $escapedTag = [regex]::Escape([string]$Tag)
    $pattern = "<<SDT:\\s*$escapedTag\\s*>>"
    return [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement })
}

function Replace-LiteralSdtTokenXmlText {
    param(
        [Parameter(Mandatory = $true)][string]$XmlText,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    $updated = Replace-LiteralSdtTokenText -Text $XmlText -Tag $Tag -Replacement $Replacement
    $escapedTag = [regex]::Escape([string]$Tag)
    $escapedPattern = "&lt;&lt;SDT:\\s*$escapedTag\\s*&gt;&gt;"
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
        [Parameter(Mandatory = $false)][string]$DocEnvironment
    )

    $map = [ordered]@{}
    $propertyAliases = [ordered]@{
        Title = @('Title', 'DocTitle', 'DocumentTitle')
        Customer = @('Customer', 'DocCustomer')
        CustomerAbbr = @('CustomerAbbr', 'DocCustomerAbbr')
        Location = @('Location', 'DocLocation')
        Subsidiary = @('Subsidiary', 'DocSubsidiary')
        Environment = @('Environment', 'DocEnvironment')
    }
    $propertyValues = [ordered]@{
        Title = $DocTitle
        Customer = $DocCustomer
        CustomerAbbr = $DocCustomerAbbr
        Location = $DocLocation
        Subsidiary = $DocSubsidiary
        Environment = $DocEnvironment
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
        [Parameter(Mandatory = $false)][ValidateSet('content-control-tag','literal-token','both')][string]$DocxMatchMode = 'content-control-tag',
        [Parameter(Mandatory = $false)][ValidateSet('retain','remove')][string]$UnresolvedTokenPolicy = 'retain'
    )

    Copy-Item -LiteralPath $TemplatePath -Destination $OutputPath -Force

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
        $literalTokensMatched = 0
        $literalTokensMatchedScalar = 0
        $literalTokensMatchedTable = 0
        $controlsDiscovered = 0
        $taggedControlsMatched = 0
        $controlsPopulated = 0
        $controlsDiscoveredMapped = 0
        $controlsDiscoveredUnmapped = 0
        $discoveredTaggedControls = [System.Collections.Generic.List[string]]::new()
        $discoveredUnmappedTaggedControls = [System.Collections.Generic.List[string]]::new()
        $partErrors = [System.Collections.Generic.List[hashtable]]::new()
        $literalTagDiagnostics = [System.Collections.Generic.List[hashtable]]::new()
        # Contract: document-property replacement is the content-control-tag engine only.
        # Get-DocxContentControlReplacementMap builds the tag->value map for tagged content controls
        # (for example DocumentTitle/DocumentCustomer* tags), and is not used for literal-token paths.
        $contentControlReplaceByTag = Get-DocxContentControlReplacementMap -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment
        $tableStyleId = ''
        if ($null -ne $TableByTag -and @($TableByTag.Keys).Count -gt 0) {
            $stylesEntry = $archive.GetEntry('word/styles.xml')
            if ($null -ne $stylesEntry) {
                $stylesReader = [System.IO.StreamReader]::new($stylesEntry.Open())
                try {
                    $stylesXmlText = $stylesReader.ReadToEnd()
                    $tableStyleId = Get-WordTableStyleId -StylesXmlText $stylesXmlText -StyleName 'LNV Table 1 - 9pt Head Banded Grid'
                }
                finally {
                    $stylesReader.Dispose()
                }
            }
        }
        foreach ($entry in @(Get-WordXmlPartEntries -Archive $archive)) {
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                $xmlText = $reader.ReadToEnd()
                $originalXmlText = $xmlText
            }
            finally {
                $reader.Dispose()
            }

            $selectionContextNode = $null
            $xmlDocTyped = $null
            $nsMgrTyped = $null

            # Contract: dataset mapping replacement uses the literal-token engine only.
            # It consumes ReplaceByTag (scalar <<SDT:...>> tokens) and TableByTag (table block tokens)
            # via Replace-LiteralSdtTokenXmlText + Replace-DocxParagraphTokenWithBlockXml.
            #
            # Mode behavior:
            # - DocxMatchMode='literal-token' -> run only this branch.
            # - DocxMatchMode='both'          -> run this branch and the content-control branch below.
            # Run literal-token replacement first because XML parsing can normalize/split runs and make
            # later regex token matching less reliable.
            if (Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'literal-token') {
                if ($null -ne $TableByTag) {
                    foreach ($tag in @($TableByTag.Keys)) {
                        $tagText = [string]$tag
                        $tableXml = Convert-TableModelToWordTableXml -TableModel $TableByTag[$tag] -TableStyleId $tableStyleId
                        $tableTokenCount = 0
                        $tableXmlGenerated = -not [string]::IsNullOrWhiteSpace($tableXml)
                        if (-not [string]::IsNullOrWhiteSpace($tableXml)) {
                            $escapedTag = [regex]::Escape($tagText)
                            $rawTokenPattern = "<<SDT:\\s*$escapedTag\\s*>>"
                            $escapedTokenPattern = "&lt;&lt;SDT:\\s*$escapedTag\\s*&gt;&gt;"
                            $tableTokenCount = [regex]::Matches($xmlText, "$rawTokenPattern|$escapedTokenPattern").Count
                            $literalTokensMatched += [int]$tableTokenCount
                            $literalTokensMatchedTable += [int]$tableTokenCount
                            $xmlText = Replace-DocxParagraphTokenWithBlockXml -XmlText $xmlText -Tag $tagText -BlockXml $tableXml
                        }

                        $literalTagDiagnostics.Add([ordered]@{
                            partName = [string]$entry.FullName
                            tag = $tagText
                            mode = 'table'
                            tableXmlGenerated = [bool]$tableXmlGenerated
                            contiguousTokenHits = [int]$tableTokenCount
                        })
                    }
                }

                foreach ($tag in @($ReplaceByTag.Keys)) {
                    $tagText = [string]$tag
                    $escapedTag = [regex]::Escape($tagText)
                    $rawTokenPattern = "<<SDT:\\s*$escapedTag\\s*>>"
                    $escapedTokenPattern = "&lt;&lt;SDT:\\s*$escapedTag\\s*&gt;&gt;"
                    $scalarTokenCount = [regex]::Matches($xmlText, "$rawTokenPattern|$escapedTokenPattern").Count
                    $literalTokensMatched += [int]$scalarTokenCount
                    $literalTokensMatchedScalar += [int]$scalarTokenCount
                    $xmlText = Replace-LiteralSdtTokenXmlText -XmlText $xmlText -Tag $tagText -Replacement ([string]$ReplaceByTag[$tag])

                    $literalTagDiagnostics.Add([ordered]@{
                        partName = [string]$entry.FullName
                        tag = $tagText
                        mode = 'scalar'
                        contiguousTokenHits = [int]$scalarTokenCount
                    })
                }
            }

            try {
                # Contract: document-property replacement uses tagged content controls only.
                # Mode behavior:
                # - DocxMatchMode='content-control-tag' -> run only this branch.
                # - DocxMatchMode='both'                -> run this branch after literal-token branch.
                if (Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'content-control-tag') {
                    [System.Xml.XmlDocument]$xmlDocTyped = [xml]$xmlText
                    $selectionContextNode = [System.Xml.XmlNode]$xmlDocTyped.DocumentElement
                    if ($null -eq $selectionContextNode) {
                        throw 'Unable to discover content controls because XML document element was null.'
                    }
                    $sdtNodes = @($selectionContextNode.SelectNodes("//*[local-name()='sdt'][*[local-name()='sdtPr']/*[local-name()='tag'][@*[local-name()='val']]]"))
                    $controlsDiscovered += @($sdtNodes).Count
                    foreach ($sdtNode in $sdtNodes) {
                        $tagAttr = $sdtNode.SelectSingleNode("./*[local-name()='sdtPr']/*[local-name()='tag']/@*[local-name()='val']")
                        if ($null -eq $tagAttr) { continue }

                        $tag = [string]$tagAttr.Value
                        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
                        $discoveredTaggedControls.Add($tag)

                        $tagHasMapping = (Test-MapHasKey -Map $contentControlReplaceByTag -Key $tag)
                        if ($tagHasMapping) {
                            $controlsDiscoveredMapped++
                        }
                        else {
                            $controlsDiscoveredUnmapped++
                            $discoveredUnmappedTaggedControls.Add($tag)
                        }

                        $sdtContent = $sdtNode.SelectSingleNode("./*[local-name()='sdtContent']")
                        if ($null -eq $sdtContent) { continue }

                        if (Test-MapHasKey -Map $contentControlReplaceByTag -Key $tag) {
                            $taggedControlsMatched++
                            $paragraphNodes = Convert-TextToWordParagraphNodes -XmlDocument $xmlDocTyped -Text ([string]$contentControlReplaceByTag[$tag])
                            Set-WordSdtContentNodes -SdtContentNode $sdtContent -Nodes $paragraphNodes
                            $controlsPopulated++
                        }
                    }
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

            Set-ZipEntryText -Entry $entry -Text $xmlText
            $partsUpdated++

            $partUnresolved = Get-UnresolvedSdtTagOccurrences -RenderedText $xmlText
            Merge-UnresolvedSdtTagOccurrences -Target $unresolvedLiteralByTag -Source $partUnresolved
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

        Update-DocxMetadataProperties -Archive $archive -Title $DocTitle -Customer $DocCustomer -CustomerAbbr $DocCustomerAbbr -Location $DocLocation -Subsidiary $DocSubsidiary -Environment $DocEnvironment

        return [ordered]@{
            unresolvedLiteralByTag = $unresolvedLiteralByTag
            partsUpdated = $partsUpdated
            literalDatasetTokensExpected = [int]$literalDatasetTokensExpected
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
            taggedControlsMatched = $taggedControlsMatched
            controlsPopulated = $controlsPopulated
            discoveredTaggedControls = @($discoveredTaggedControls | Sort-Object -Unique)
            discoveredUnmappedTaggedControls = @($discoveredUnmappedTaggedControls | Sort-Object -Unique)
            unmatchedTaggedControls = @($mappedTagsNotDiscovered | Sort-Object -Unique)
            docPropMappedTags = @($contentControlReplaceByTag.Keys | Sort-Object -Unique)
            contentControlMappedTags = @($contentControlReplaceByTag.Keys | Sort-Object -Unique)
            partErrors = @($partErrors)
            literalTagDiagnostics = @($literalTagDiagnostics)
        }
    }
    finally {
        $archive.Dispose()
    }
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

        foreach ($propertyName in @('filter', 'columns')) {
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
            default {
                $normalized[[string]$key] = $Definition[$key]
            }
        }
    }

    if (-not $normalized.Contains('filter')) { $normalized.filter = @() }
    if (-not $normalized.Contains('columns')) { $normalized.columns = @() }
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

function Resolve-ProjectionColumnValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Column
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

    if (Test-MapHasKey -Map $Column -Key 'format') {
        switch ([string]$Column.format) {
            'bytesHuman' { return (Format-SizeHuman -Bytes $value) }
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

function Invoke-TableProjection {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Definition
    )

    $normalizedRows = @(ConvertTo-ObjectArray -InputObject $Rows)
    $normalizedDefinition = Normalize-ProjectionDefinition -Definition $Definition
    $projectedRows = @($normalizedRows)
    if (@($normalizedDefinition.filter).Count -gt 0) {
        foreach ($condition in @($normalizedDefinition.filter)) {
            $projectedRows = @($projectedRows | Where-Object { Test-ProjectionCondition -Row $_ -Condition $condition })
        }
    }
    if ((Test-MapHasKey -Map $normalizedDefinition -Key 'sortBy') -and -not [string]::IsNullOrWhiteSpace([string]$normalizedDefinition.sortBy)) {
        $projectedRows = @($projectedRows | Sort-Object -Property ([string]$normalizedDefinition.sortBy))
    }

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
                $projected[[string]$column.name] = Convert-CellValueToString -Value (Resolve-ProjectionColumnValue -Row $row -Column $column)
            }
            [pscustomobject]$projected
        }
    )
}

function Convert-TableRowsForTag {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$RenderHint,
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$ProjectionDefinitions,
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases
    )

    $normalizedRows = @(ConvertTo-ObjectArray -InputObject $Rows)
    $projectionDefinition = Get-ProjectionDefinitionForMapping -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases
    if ($null -ne $projectionDefinition) {
        return @(ConvertTo-ObjectArray -InputObject (Invoke-TableProjection -Rows $normalizedRows -Definition $projectionDefinition))
    }

    return @($normalizedRows)
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
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases
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
    else {
        return $null
    }

    $rows = @(ConvertTo-ObjectArray -InputObject (Convert-TableRowsForTag -Tag $Tag -Rows $rows -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases))
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
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases
    )

    $tableModel = Convert-ValueToTableModel -Value $Value -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases
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
        [Parameter(Mandatory = $false)][hashtable]$ProjectionAliases
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

        return (Convert-ValueToTableString -Value $Value -Tag $Tag -RenderHint $RenderHint -ProjectionDefinitions $ProjectionDefinitions -ProjectionAliases $ProjectionAliases)
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
$stageList = [System.Collections.Generic.List[hashtable]]::new()
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
    param([Parameter(Mandatory = $true)][hashtable]$Stage)
    $script:currentStageName = [string]$Stage.name
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

        $resolvedText = [string](Convert-ValueToString -Value $resolved -Tag $tag -RenderHint $renderHint -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases)
        $replaceByTag[$tag] = $resolvedText
        if ($isDocxTemplate) {
            $projectionDefinition = Get-ProjectionDefinitionForMapping -Tag $tag -RenderHint $renderHint -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases
            $renderMode = Get-EffectiveRenderMode -RenderHint $renderHint -ProjectionDefinition $projectionDefinition -Tag $tag
            if ($renderMode -eq 'table' -or $null -ne $projectionDefinition) {
                $tableModel = Convert-ValueToTableModel -Value $resolved -Tag $tag -RenderHint $renderHint -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases
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
    if ($isDocxTemplate) {
        $outputDir = Split-Path -Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
        $docxRender = Render-DocxTemplate -TemplatePath $TemplatePath -OutputPath $OutputPath -ReplaceByTag $replaceByTag -TableByTag $docxTableByTag -DocTitle $DocTitle -DocCustomer $DocCustomer -DocCustomerAbbr $DocCustomerAbbr -DocLocation $DocLocation -DocSubsidiary $DocSubsidiary -DocEnvironment $DocEnvironment -DocxMatchMode $DocxMatchMode -UnresolvedTokenPolicy $UnresolvedTokenPolicy
        $docxUnresolvedLiteralByTag = $docxRender.unresolvedLiteralByTag
        $unresolvedByTag = $docxUnresolvedLiteralByTag
        $renderDetails.partsUpdated = [int]$docxRender.partsUpdated
        $renderDetails.literalDatasetTokensExpected = [int]$docxRender.literalDatasetTokensExpected
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
        $renderDetails.taggedControlsMatched = [int]$docxRender.taggedControlsMatched
        $renderDetails.controlsPopulated = [int]$docxRender.controlsPopulated
        $renderDetails.discoveredTaggedControls = @($docxRender.discoveredTaggedControls)
        $renderDetails.discoveredUnmappedTaggedControls = @($docxRender.discoveredUnmappedTaggedControls)
        $renderDetails.unmatchedTaggedControls = @($docxRender.unmatchedTaggedControls)
        $renderDetails.docPropMappedTags = @($docxRender.docPropMappedTags)
        $renderDetails.contentControlMappedTags = @($docxRender.contentControlMappedTags)
        $renderDetails.partErrors = @($docxRender.partErrors)
        $renderDetails.literalTagDiagnostics = @($docxRender.literalTagDiagnostics)
        $renderDetails.unresolvedLiteralTokens = @($docxUnresolvedLiteralByTag.Keys | Sort-Object)
        $renderDetails.docxMatchMode = [string]$DocxMatchMode
        $expectedDocPropertyControlCount = [int]$renderDetails.docPropControlsExpected
        $controlsPopulatedCount = [int]$renderDetails.docPropControlsPopulated
        $docPropValuesSupplied = $expectedDocPropertyControlCount -gt 0
        $docPropNoPopulationSeverity = Resolve-DocPropNoPopulationSeverity
        if ((Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'literal-token') -and [int]$renderDetails.literalDatasetTokensExpected -gt 0 -and [int]$renderDetails.literalDatasetTokensPopulated -eq 0) {
            $status = 'ERROR'
            $issues.Add([ordered]@{
                code = 'ASB-ASM-SDT-DOCX-NO-POPULATION'
                severity = 'ERROR'
                message = "DOCX literal-token render expected dataset mapping replacement but found no matching tokens to populate. docxMatchMode='$DocxMatchMode'; literalDatasetTokensExpected=$($renderDetails.literalDatasetTokensExpected); literalDatasetTokensPopulated=$($renderDetails.literalDatasetTokensPopulated); literalTokensMatched=$($renderDetails.literalTokensMatched); literalTokensMatchedScalar=$($renderDetails.literalTokensMatchedScalar); literalTokensMatchedTable=$($renderDetails.literalTokensMatchedTable)"
                path = $TemplatePath
            })
        }
        if ((Test-DocxMatchModeIncludes -DocxMatchMode $DocxMatchMode -Mode 'content-control-tag') -and $docPropValuesSupplied -and $controlsPopulatedCount -eq 0) {
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
                message = "DOCX document-property render expected tagged content controls but none were populated. docxMatchMode='$DocxMatchMode'; discoveredControls=$($renderDetails.controlsDiscovered); discoveredMappedControls=$($renderDetails.controlsDiscoveredMapped); discoveredUnmappedControls=$($renderDetails.controlsDiscoveredUnmapped); partErrorCount=$(@($renderDetails.partErrors).Count); taggedControlsMatched=$($renderDetails.taggedControlsMatched); controlsPopulated=$controlsPopulatedCount; docPropertyControlTags=$expectedDocPropertyControlCount; docPropValuesSupplied=$docPropValuesSupplied; sampleDocPropertyTags=$sampleMatchedTagsText; policySeverity=$docPropNoPopulationSeverity"
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
        docxPartsUpdated = $(if ($isDocxTemplate) { [int]$renderDetails.partsUpdated } else { 0 })
        docxLiteralDatasetTokensExpected = $(if ($isDocxTemplate) { [int]$renderDetails.literalDatasetTokensExpected } else { 0 })
        docxLiteralDatasetTokensPopulated = $(if ($isDocxTemplate) { [int]$renderDetails.literalDatasetTokensPopulated } else { 0 })
        docxLiteralTokensMatched = $(if ($isDocxTemplate) { [int]$renderDetails.literalTokensMatched } else { 0 })
        docxLiteralTokensMatchedScalar = $(if ($isDocxTemplate) { [int]$renderDetails.literalTokensMatchedScalar } else { 0 })
        docxLiteralTokensMatchedTable = $(if ($isDocxTemplate) { [int]$renderDetails.literalTokensMatchedTable } else { 0 })
        docxDocPropControlsExpected = $(if ($isDocxTemplate) { [int]$renderDetails.docPropControlsExpected } else { 0 })
        docxDocPropControlsMatched = $(if ($isDocxTemplate) { [int]$renderDetails.docPropControlsMatched } else { 0 })
        docxDocPropControlsPopulated = $(if ($isDocxTemplate) { [int]$renderDetails.docPropControlsPopulated } else { 0 })
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
        docxMatchMode = $(if ($isDocxTemplate) { [string]$renderDetails.docxMatchMode } else { '' })
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
