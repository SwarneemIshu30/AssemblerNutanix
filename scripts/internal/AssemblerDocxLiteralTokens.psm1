Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-AssemblerWordXmlPartNames {
    param(
        [Parameter(Mandatory = $false)]
        [System.IO.Compression.ZipArchive]$Archive
    )

    if ($null -eq $Archive) {
        return @()
    }

    return @(
        $Archive.Entries | Where-Object {
            $fullName = [string]$_.FullName
            $fullName -eq 'word/document.xml' -or
            $fullName -match '^word/header\d*\.xml$' -or
            $fullName -match '^word/footer\d*\.xml$'
        } | ForEach-Object { [string]$_.FullName }
    )
}

function Get-AssemblerWordXmlPartsFromArchive {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Archive
    )

    $partsByName = [ordered]@{}
    foreach ($partName in @(Get-AssemblerWordXmlPartNames -Archive $Archive)) {
        $entry = $Archive.GetEntry($partName)
        if ($null -eq $entry) { continue }

        $reader = [System.IO.StreamReader]::new($entry.Open())
        try {
            $partsByName[[string]$partName] = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }

    return $partsByName
}

function Get-AssemblerDocxLiteralTokenDiagnosticsFromXmlParts {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$XmlPartsByName,

        [Parameter(Mandatory = $true)]
        [string[]]$Tags
    )

    $diagnostics = [System.Collections.Generic.List[hashtable]]::new()
    $normalizedTags = @(
        @($Tags) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    foreach ($tag in $normalizedTags) {
        $escapedTag = [regex]::Escape([string]$tag)
        $rawTokenPattern = "<<SDT:\s*$escapedTag\s*>>"
        $escapedTokenPattern = "&lt;&lt;SDT:\s*$escapedTag\s*&gt;&gt;"

        foreach ($partName in @($XmlPartsByName.Keys | Sort-Object)) {
            $xmlText = [string]$XmlPartsByName[$partName]
            $rawTokenHits = [regex]::Matches($xmlText, $rawTokenPattern).Count
            $escapedTokenHits = [regex]::Matches($xmlText, $escapedTokenPattern).Count
            $contiguousTokenHits = [int]$rawTokenHits + [int]$escapedTokenHits
            $containsTagText = -not [string]::IsNullOrWhiteSpace($xmlText) -and ($xmlText -match $escapedTag)
            $fragmentHint = ($contiguousTokenHits -eq 0 -and $containsTagText)

            $diagnostics.Add([ordered]@{
                tag = [string]$tag
                partName = [string]$partName
                rawTokenHits = [int]$rawTokenHits
                escapedTokenHits = [int]$escapedTokenHits
                contiguousTokenHits = [int]$contiguousTokenHits
                containsTagText = [bool]$containsTagText
                fragmentHint = [bool]$fragmentHint
            })
        }
    }

    return @($diagnostics.ToArray())
}

function Get-AssemblerDocxLiteralTokenDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DocxPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Tags
    )

    if (-not (Test-Path -LiteralPath $DocxPath -PathType Leaf)) {
        throw "Required DOCX file not found: $DocxPath"
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead($DocxPath)
    try {
        $partsByName = Get-AssemblerWordXmlPartsFromArchive -Archive $archive
    }
    finally {
        $archive.Dispose()
    }

    return Get-AssemblerDocxLiteralTokenDiagnosticsFromXmlParts -XmlPartsByName $partsByName -Tags $Tags
}

function Get-AssemblerDocxLiteralTokenTagSummary {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Diagnostics
    )

    $summary = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($group in @(@($Diagnostics) | Group-Object -Property tag)) {
        $items = @($group.Group)
        $contiguousHits = [int](($items | Measure-Object -Property contiguousTokenHits -Sum).Sum)
        $fragmentHintParts = @(
            $items |
                Where-Object { [bool]$_.fragmentHint } |
                ForEach-Object { [string]$_.partName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        $status = if ($contiguousHits -gt 0) {
            'OK'
        }
        elseif (@($fragmentHintParts).Count -gt 0) {
            'FRAGMENTED_OR_NON_LITERAL'
        }
        else {
            'MISSING'
        }

        $summary.Add([ordered]@{
            tag = [string]$group.Name
            status = $status
            contiguousLiteralHits = [int]$contiguousHits
            fragmentHintParts = @($fragmentHintParts)
        })
    }

    return @($summary.ToArray())
}

Export-ModuleMember -Function @(
    'Get-AssemblerWordXmlPartNames',
    'Get-AssemblerWordXmlPartsFromArchive',
    'Get-AssemblerDocxLiteralTokenDiagnosticsFromXmlParts',
    'Get-AssemblerDocxLiteralTokenDiagnostics',
    'Get-AssemblerDocxLiteralTokenTagSummary'
)
