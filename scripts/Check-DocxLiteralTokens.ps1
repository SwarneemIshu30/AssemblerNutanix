param(
    [Parameter(Mandatory = $true)][string]$DocxPath,
    [Parameter(Mandatory = $true)][string]$MappingPath
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$base = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path   # repo root if script is in .\scripts
$DocxPath = [System.IO.Path]::GetFullPath((Join-Path $base $DocxPath))
$MappingPath = [System.IO.Path]::GetFullPath((Join-Path $base $MappingPath))

function Get-MappingTags {
    param([string]$Path)
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    $tags = @()
    foreach ($m in @($json.mappings)) {
        $tag = $null
        if ($null -ne $m.sdtTag -and [string]$m.sdtTag -ne '') { $tag = [string]$m.sdtTag }
        elseif ($null -ne $m.target -and $null -ne $m.target.sdtTag -and [string]$m.target.sdtTag -ne '') { $tag = [string]$m.target.sdtTag }
        if (-not [string]::IsNullOrWhiteSpace($tag)) { $tags += $tag }
    }
    $tags | Sort-Object -Unique
}

function Get-WordXmlParts {
    param([string]$DocxPath)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($DocxPath)
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -like 'word/*.xml') {
                $sr = New-Object System.IO.StreamReader($e.Open())
                try {
                    [PSCustomObject]@{
                        Part = $e.FullName
                        Xml  = $sr.ReadToEnd()
                    }
                } finally {
                    $sr.Dispose()
                }
            }
        }
    } finally {
        $zip.Dispose()
    }
}

$tags  = Get-MappingTags -Path $MappingPath
$parts = @(Get-WordXmlParts -DocxPath $DocxPath)

$results = foreach ($tag in $tags) {
    $escTag = [regex]::Escape($tag)
    $rawPattern = "<<SDT:\s*$escTag\s*>>"
    $xmlPattern = "&lt;&lt;SDT:\s*$escTag\s*&gt;&gt;"

    $contiguousHits = 0
    $fragmentHints = @()

    foreach ($p in $parts) {
        $c1 = [regex]::Matches($p.Xml, $rawPattern).Count
        $c2 = [regex]::Matches($p.Xml, $xmlPattern).Count
        $contiguousHits += ($c1 + $c2)

        if ($c1 + $c2 -eq 0 -and $p.Xml -match [regex]::Escape($tag)) {
            $fragmentHints += $p.Part
        }
    }

    $status = if ($contiguousHits -gt 0) { 'OK' }
              elseif ($fragmentHints.Count -gt 0) { 'FRAGMENTED_OR_NON_LITERAL' }
              else { 'MISSING' }

    [PSCustomObject]@{
        Tag = $tag
        Status = $status
        ContiguousLiteralHits = $contiguousHits
        FragmentHintParts = ($fragmentHints | Sort-Object -Unique) -join '; '
    }
}

$summary = $results | Group-Object Status | Sort-Object Name | ForEach-Object {
    "{0}={1}" -f $_.Name, $_.Count
}
"Summary: " + ($summary -join ', ')
$results | Sort-Object Status, Tag | Format-Table -AutoSize