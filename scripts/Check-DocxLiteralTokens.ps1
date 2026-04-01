param(
    [Parameter(Mandatory = $true)][string]$DocxPath,
    [Parameter(Mandatory = $true)][string]$MappingPath
)

$base = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$DocxPath = [System.IO.Path]::GetFullPath((Join-Path $base $DocxPath))
$MappingPath = [System.IO.Path]::GetFullPath((Join-Path $base $MappingPath))

Import-Module (Join-Path $PSScriptRoot 'internal/AssemblerDocxLiteralTokens.psm1') -Force

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

$tags = @(Get-MappingTags -Path $MappingPath)
$diagnostics = @(Get-AssemblerDocxLiteralTokenDiagnostics -DocxPath $DocxPath -Tags $tags)
$results = @(
    Get-AssemblerDocxLiteralTokenTagSummary -Diagnostics $diagnostics |
        Sort-Object -Property @{ Expression = { [string]$_.status }; Descending = $false }, @{ Expression = { [string]$_.tag }; Descending = $false } |
        ForEach-Object {
            [PSCustomObject]@{
                Tag = [string]$_.tag
                Status = [string]$_.status
                ContiguousLiteralHits = [int]$_.contiguousLiteralHits
                FragmentHintParts = (@($_.fragmentHintParts) -join '; ')
            }
        }
)

$summary = $results | Group-Object Status | Sort-Object Name | ForEach-Object {
    "{0}={1}" -f $_.Name, $_.Count
}
"Summary: " + ($summary -join ', ')
$results | Format-Table -AutoSize
