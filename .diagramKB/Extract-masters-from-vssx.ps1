$StencilPath = "C:\Github\LNV.AsBuiltDoc.Assembler\.diagramKB\vss\Lenovo-ThinkSystem-DS.vssx"
$ExportPath  = "C:\temp\exports\DS"

# Preview/browser convenience only. Assembler should use role-based docWidthIn.
$PreviewWidthPx = 600

if (!(Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath | Out-Null
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)

    $safe = $Name -replace '[\\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', ' '
    return $safe.Trim()
}

function Set-SvgPreviewSize {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$PreviewWidthPx
    )

    [xml]$svgDoc = Get-Content $Path -Raw
    $svgRoot = $svgDoc.DocumentElement

    if (-not $svgRoot -or $svgRoot.LocalName -ne "svg") {
        Write-Warning "Not an SVG root element: $Path"
        return $null
    }

    $viewBox = $svgRoot.GetAttribute("viewBox")

    if ($viewBox -match '^\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*$') {
        $vbW = [double]$Matches[1]
        $vbH = [double]$Matches[2]

        if ($vbW -gt 0 -and $vbH -gt 0) {
            $previewHeightPx = [math]::Round($PreviewWidthPx * ($vbH / $vbW), 0)
            $aspectRatio = [math]::Round($vbW / $vbH, 6)

            $svgRoot.SetAttribute("width", "$PreviewWidthPx")
            $svgRoot.SetAttribute("height", "$previewHeightPx")

            $svgDoc.Save($Path)

            return [pscustomobject]@{
                ViewBox         = $viewBox
                ViewBoxWidth    = $vbW
                ViewBoxHeight   = $vbH
                AspectRatio     = $aspectRatio
                PreviewWidthPx  = $PreviewWidthPx
                PreviewHeightPx = $previewHeightPx
            }
        }
    }

    Write-Warning "Could not parse viewBox for: $Path"
    return $null
}

$ExportRows = New-Object System.Collections.Generic.List[object]

$Visio = $null
$Stencil = $null
$Drawing = $null

try {
    $Visio = New-Object -ComObject Visio.Application
    $Visio.Visible = $false
    $Visio.AlertResponse = 7

    $Stencil = $Visio.Documents.Open($StencilPath)

    $Drawing = $Visio.Documents.Add("")
    $Page = $Drawing.Pages.Item(1)

    foreach ($Master in $Stencil.Masters) {
        $MasterName = $Master.Name
        $MasterNameU = $Master.NameU

        $BaseName = if (![string]::IsNullOrWhiteSpace($MasterNameU)) {
            $MasterNameU
        } else {
            $MasterName
        }

        $SafeName = ConvertTo-SafeFileName -Name $BaseName
        $OutFile = Join-Path $ExportPath "$SafeName.svg"

        foreach ($Shape in @($Page.Shapes)) {
            $Shape.Delete()
        }

        $DroppedShape = $Page.Drop($Master, 0, 0)
        $DroppedShape.Export($OutFile)

        $sizeInfo = Set-SvgPreviewSize -Path $OutFile -PreviewWidthPx $PreviewWidthPx

        $row = [pscustomobject]@{
            MasterId        = $Master.ID
            MasterName      = $MasterName
            MasterNameU     = $MasterNameU
            AssetFile       = Split-Path $OutFile -Leaf
            AssetPath       = $OutFile
            ViewBox         = if ($sizeInfo) { $sizeInfo.ViewBox } else { "" }
            ViewBoxWidth    = if ($sizeInfo) { $sizeInfo.ViewBoxWidth } else { "" }
            ViewBoxHeight   = if ($sizeInfo) { $sizeInfo.ViewBoxHeight } else { "" }
            AspectRatio     = if ($sizeInfo) { $sizeInfo.AspectRatio } else { "" }
            PreviewWidthPx  = if ($sizeInfo) { $sizeInfo.PreviewWidthPx } else { "" }
            PreviewHeightPx = if ($sizeInfo) { $sizeInfo.PreviewHeightPx } else { "" }
            AssetType       = ""
            ProductId       = ""
            View            = ""
            DocWidthIn      = ""
            NeedsReview     = "true"
            Notes           = ""
        }

        $ExportRows.Add($row)

        if ($sizeInfo) {
            Write-Host "Exported: $SafeName -> $($sizeInfo.PreviewWidthPx)x$($sizeInfo.PreviewHeightPx)"
        } else {
            Write-Warning "Exported but size metadata was not normalised: $SafeName"
        }
    }

    $IndexPath = Join-Path $ExportPath "_visio-master-export-index.csv"
    $ExportRows | Export-Csv -Path $IndexPath -NoTypeInformation -Encoding UTF8

    Write-Host "Wrote index: $IndexPath"
}
finally {
    if ($Drawing) {
        try { $Drawing.Close() } catch {}
    }

    if ($Stencil) {
        try { $Stencil.Close() } catch {}
    }

    if ($Visio) {
        try { $Visio.Quit() } catch {}
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Visio) | Out-Null
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}