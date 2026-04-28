Set-StrictMode -Version Latest

function Get-AssemblerSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-AssemblerStableJson {
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)]$InputObject)

    process {
        $json = $InputObject | ConvertTo-Json -Depth 50
        return ($json -replace "`r`n", "`n")
    }
}

function Get-AssemblerBundleHash {
    param([Parameter(Mandatory = $true)][object[]]$FileIndex)

    $stableIndex = @(
        $FileIndex |
            Sort-Object path |
            ForEach-Object {
                [pscustomobject]@{
                    path   = [string]$_.path
                    bytes  = [int64]$_.bytes
                    sha256 = [string]$_.sha256
                }
            }
    )

    $json = $stableIndex | ConvertTo-AssemblerStableJson
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-AssemblerRelativeArchivePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $normalized = ($Path -replace '\\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "$Kind contains an empty path."
    }
    if ([System.IO.Path]::IsPathRooted($Path) -or $normalized -match '(^|/)\.\.(/|$)') {
        return "$Kind contains unsafe path '$Path'."
    }
    return $null
}

function Get-AssemblerArchiveExtractRoot {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $bundleStagingRoot = Join-Path $RepoRoot 'bundle'
    $archiveName = [System.IO.Path]::GetFileName($ArchivePath)
    if ($archiveName.EndsWith('.lnvbundle.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
        $archiveBaseName = $archiveName.Substring(0, $archiveName.Length - '.lnvbundle.zip'.Length)
    }
    else {
        $archiveBaseName = [System.IO.Path]::GetFileNameWithoutExtension($archiveName)
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($char in $invalidChars) {
        $archiveBaseName = $archiveBaseName.Replace([string]$char, '-')
    }
    if ([string]::IsNullOrWhiteSpace($archiveBaseName)) {
        $archiveBaseName = 'bundle-archive'
    }

    Join-Path $bundleStagingRoot ("{0}-{1}" -f $archiveBaseName, [guid]::NewGuid().ToString())
}

function Import-AssemblerBundleArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $archivePathAbs = $null
    $archiveSha256 = $null
    $extractRoot = $null
    $manifest = $null
    $bundleId = $null
    $bundleHash = $null

    try {
        $archivePathAbs = (Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop).Path
        $repoRootAbs = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
        $archiveSha256 = Get-AssemblerSha256 -Path $archivePathAbs
        $extractRoot = Get-AssemblerArchiveExtractRoot -ArchivePath $archivePathAbs -RepoRoot $repoRootAbs

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $destinationFull = [System.IO.Path]::GetFullPath($extractRoot).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $targetPaths = @{}

        $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePathAbs)
        try {
            foreach ($entry in @($zip.Entries)) {
                $entryName = [string]$entry.FullName
                $normalizedName = ($entryName -replace '\\', '/')
                $entryIssue = Test-AssemblerRelativeArchivePath -Path $entryName -Kind 'Archive'
                if ($entryIssue) {
                    $errors.Add($entryIssue)
                    continue
                }

                $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destinationFull ($normalizedName -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
                if (-not $targetPath.StartsWith($destinationFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
                    -not [string]::Equals($targetPath, $destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $errors.Add("Archive entry '$entryName' resolves outside the extraction directory.")
                    continue
                }

                if (-not $normalizedName.EndsWith('/')) {
                    $targetKey = $targetPath.ToLowerInvariant()
                    if ($targetPaths.ContainsKey($targetKey)) {
                        $errors.Add("Archive contains duplicate file target '$entryName'.")
                    }
                    else {
                        $targetPaths[$targetKey] = $true
                    }
                }
            }

            if ($errors.Count -eq 0) {
                New-Item -Path $destinationFull -ItemType Directory -Force | Out-Null
                foreach ($entry in @($zip.Entries)) {
                    $entryName = [string]$entry.FullName
                    $normalizedName = ($entryName -replace '\\', '/')
                    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destinationFull ($normalizedName -replace '/', [System.IO.Path]::DirectorySeparatorChar)))

                    if ($normalizedName.EndsWith('/')) {
                        New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
                        continue
                    }

                    $targetDirectory = Split-Path -Path $targetPath -Parent
                    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                        New-Item -Path $targetDirectory -ItemType Directory -Force | Out-Null
                    }

                    $inputStream = $entry.Open()
                    try {
                        $outputStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                        try {
                            $inputStream.CopyTo($outputStream)
                        }
                        finally {
                            $outputStream.Dispose()
                        }
                    }
                    finally {
                        $inputStream.Dispose()
                    }
                }
            }
        }
        finally {
            $zip.Dispose()
        }

        if ($errors.Count -eq 0) {
            $manifestPath = Join-Path $destinationFull 'manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                $errors.Add('manifest.json is missing.')
            }
            else {
                try {
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
                    $bundleId = [string]$manifest.bundleId
                }
                catch {
                    $errors.Add("manifest.json is invalid JSON: $($_.Exception.Message)")
                }
            }
        }

        if ($errors.Count -eq 0 -and $manifest) {
            if (-not ($manifest.PSObject.Properties.Name -contains 'files') -or $null -eq $manifest.files) {
                $errors.Add('manifest.files is required.')
            }

            $expectedByPath = @{}
            foreach ($entry in @($manifest.files)) {
                $relativePath = [string]$entry.path
                $pathIssue = Test-AssemblerRelativeArchivePath -Path $relativePath -Kind 'manifest.files'
                if ($pathIssue) {
                    $errors.Add($pathIssue)
                    continue
                }

                $normalizedPath = ($relativePath -replace '\\', '/')
                if ($normalizedPath -eq 'manifest.json') {
                    $errors.Add('manifest.files must not include manifest.json.')
                    continue
                }
                if ($expectedByPath.ContainsKey($normalizedPath)) {
                    $errors.Add("manifest.files contains duplicate path '$normalizedPath'.")
                    continue
                }

                $expectedByPath[$normalizedPath] = $entry
                $actualPath = Join-Path $destinationFull ($normalizedPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $actualPath -PathType Leaf)) {
                    $errors.Add("Manifest file '$normalizedPath' is missing from bundle.")
                    continue
                }

                $actualItem = Get-Item -LiteralPath $actualPath
                if ([int64]$entry.bytes -ne [int64]$actualItem.Length) {
                    $errors.Add("Manifest file '$normalizedPath' byte count mismatch. Expected $($entry.bytes), got $($actualItem.Length).")
                }

                $actualHash = Get-AssemblerSha256 -Path $actualPath
                if ([string]$entry.sha256 -ne $actualHash) {
                    $errors.Add("Manifest file '$normalizedPath' SHA256 mismatch.")
                }
            }

            $actualFiles = @(
                Get-ChildItem -Path $destinationFull -Recurse -File |
                    ForEach-Object {
                        $relativePath = [System.IO.Path]::GetRelativePath($destinationFull, $_.FullName)
                        $relativePath = ($relativePath -replace '\\', '/')
                        if ($relativePath -ne 'manifest.json') {
                            $relativePath
                        }
                    } |
                    Sort-Object
            )
            foreach ($actual in $actualFiles) {
                if (-not $expectedByPath.ContainsKey([string]$actual)) {
                    $errors.Add("Bundle contains extra file '$actual' not listed in manifest.files.")
                }
            }

            if (-not ($manifest.PSObject.Properties.Name -contains 'integrity') -or -not $manifest.integrity) {
                $errors.Add('manifest.integrity is required.')
            }
            else {
                if ([string]$manifest.integrity.hashAlgorithm -ne 'SHA256') {
                    $errors.Add('manifest.integrity.hashAlgorithm must be SHA256.')
                }

                $bundleHash = Get-AssemblerBundleHash -FileIndex @($manifest.files)
                if ([string]$manifest.integrity.bundleHash -ne $bundleHash) {
                    $errors.Add('manifest.integrity.bundleHash mismatch.')
                }
            }
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    [pscustomobject]@{
        IsValid             = ($errors.Count -eq 0)
        SourceArchivePath   = $archivePathAbs
        ArchiveSha256       = $archiveSha256
        ExtractedBundleRoot = if ($extractRoot) { [System.IO.Path]::GetFullPath($extractRoot) } else { $null }
        BundleId            = $bundleId
        BundleHash          = if ($bundleHash) { $bundleHash } elseif ($manifest -and $manifest.integrity) { [string]$manifest.integrity.bundleHash } else { $null }
        Status              = if ($errors.Count -eq 0) { 'OK' } else { 'ERROR' }
        Errors              = @($errors)
        Warnings            = @($warnings)
    }
}

Export-ModuleMember -Function @(
    'Get-AssemblerSha256',
    'Get-AssemblerBundleHash',
    'Import-AssemblerBundleArchive'
)
