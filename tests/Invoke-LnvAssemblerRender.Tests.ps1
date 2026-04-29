Describe 'Invoke-LnvAssemblerRender wrapper' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-LnvAssemblerRender.ps1'
        $script:archiveModulePath = Join-Path $script:repoRoot 'scripts/internal/AssemblerBundleArchive.psm1'
        Import-Module $script:archiveModulePath -Force
        $script:extractedRootsToRemove = [System.Collections.Generic.List[string]]::new()

        function New-MinimalWrapperInput {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("lnv-wrapper-test-" + [guid]::NewGuid().ToString('n'))
            $bundleRoot = Join-Path $root 'bundle'
            $configRoot = Join-Path $bundleRoot 'config'
            $outRoot = Join-Path $root 'out'
            New-Item -Path $configRoot -ItemType Directory -Force | Out-Null
            New-Item -Path $outRoot -ItemType Directory -Force | Out-Null

            Set-Content -LiteralPath (Join-Path $bundleRoot 'manifest.json') -Value '{"schemaVersion":"direct-v1","bundleId":"test"}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bundleRoot 'objectIndex.json') -Value '{"objects":[]}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $configRoot 'solution.plan.json') -Value '{"solutionId":"test","targets":[],"collectors":[]}' -Encoding UTF8

            $catalogPath = Join-Path $root 'catalog.json'
            Set-Content -LiteralPath $catalogPath -Value '{}' -Encoding UTF8

            [pscustomobject]@{
                Root = $root
                BundleRoot = $bundleRoot
                BundleArchivePath = $null
                CatalogPath = $catalogPath
                OutputRoot = $outRoot
                ProgressPath = Join-Path $outRoot 'progress.jsonl'
                ReportPath = Join-Path $outRoot 'render-report.json'
                CancelSignalPath = Join-Path $outRoot '.assembler-render.cancel'
            }
        }

        function New-ArchiveWrapperInput {
            $inputRoot = New-MinimalWrapperInput
            Set-Content -LiteralPath (Join-Path $inputRoot.BundleRoot 'objectIndex.json') -Value '{"objects":[]}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $inputRoot.BundleRoot 'config/solution.plan.json') -Value '{"solutionId":"test","targets":[],"collectors":[]}' -Encoding UTF8

            $relativeFiles = @('objectIndex.json', 'config/solution.plan.json')
            $fileIndex = @(
                foreach ($relativeFile in $relativeFiles) {
                    $filePath = Join-Path $inputRoot.BundleRoot ($relativeFile -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                    [pscustomobject]@{
                        path = $relativeFile
                        bytes = (Get-Item -LiteralPath $filePath).Length
                        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash.ToLowerInvariant()
                    }
                }
            )
            $bundleHash = Get-AssemblerBundleHash -FileIndex $fileIndex
            $manifest = [ordered]@{
                schemaVersion = 1
                bundleId = 'archive-test'
                createdUtc = '2026-01-01T00:00:00Z'
                completedUtc = '2026-01-01T00:00:01Z'
                files = @($fileIndex)
                results = @()
                integrity = [ordered]@{
                    hashAlgorithm = 'SHA256'
                    bundleHash = $bundleHash
                }
            }
            Set-Content -LiteralPath (Join-Path $inputRoot.BundleRoot 'manifest.json') -Value ($manifest | ConvertTo-Json -Depth 20) -Encoding UTF8

            $archivePath = Join-Path $inputRoot.Root 'archive-test.lnvbundle.zip'
            New-TestBundleArchive -BundleRoot $inputRoot.BundleRoot -ArchivePath $archivePath
            $inputRoot.BundleArchivePath = $archivePath
            $inputRoot
        }

        function New-TestBundleArchive {
            param(
                [Parameter(Mandatory = $true)][string]$BundleRoot,
                [Parameter(Mandatory = $true)][string]$ArchivePath,
                [Parameter(Mandatory = $false)][string]$TamperPath,
                [Parameter(Mandatory = $false)][string]$SkipPath,
                [Parameter(Mandatory = $false)][switch]$AddExtra
            )

            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
                Remove-Item -LiteralPath $ArchivePath -Force
            }

            $manifest = Get-Content -LiteralPath (Join-Path $BundleRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $entries = @('manifest.json') + @($manifest.files | Sort-Object path | ForEach-Object { [string]$_.path })
            $zip = [System.IO.Compression.ZipFile]::Open($ArchivePath, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($entry in $entries) {
                    if ($entry -eq $SkipPath) { continue }
                    if ($entry -eq $TamperPath) {
                        $zipEntry = $zip.CreateEntry($entry)
                        $writer = [System.IO.StreamWriter]::new($zipEntry.Open(), [System.Text.UTF8Encoding]::new($false))
                        try { $writer.Write('tampered') }
                        finally { $writer.Dispose() }
                        continue
                    }

                    $sourcePath = Join-Path $BundleRoot ($entry -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $sourcePath, $entry, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
                }

                if ($AddExtra) {
                    $zipEntry = $zip.CreateEntry('extra.txt')
                    $writer = [System.IO.StreamWriter]::new($zipEntry.Open(), [System.Text.UTF8Encoding]::new($false))
                    try { $writer.Write('extra') }
                    finally { $writer.Dispose() }
                }
            }
            finally {
                $zip.Dispose()
            }
        }

        function New-UnsafeArchive {
            param([Parameter(Mandatory = $true)][string]$ArchivePath)

            Add-Type -AssemblyName System.IO.Compression
            if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
                Remove-Item -LiteralPath $ArchivePath -Force
            }
            $zip = [System.IO.Compression.ZipFile]::Open($ArchivePath, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $zipEntry = $zip.CreateEntry('../evil.txt')
                $writer = [System.IO.StreamWriter]::new($zipEntry.Open(), [System.Text.UTF8Encoding]::new($false))
                try { $writer.Write('evil') }
                finally { $writer.Dispose() }
            }
            finally {
                $zip.Dispose()
            }
        }

        function Invoke-Wrapper {
            param(
                [Parameter(Mandatory = $true)]$InputRoot,
                [Parameter(Mandatory = $false)][switch]$UseArchive,
                [Parameter(Mandatory = $false)][switch]$IncludeBothBundleInputs
            )

            $arguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', $script:scriptPath
            )
            if ($UseArchive) {
                $arguments += @('-BundleArchivePath', $InputRoot.BundleArchivePath)
                if ($IncludeBothBundleInputs) {
                    $arguments += @('-BundleRoot', $InputRoot.BundleRoot)
                }
            }
            else {
                $arguments += @('-BundleRoot', $InputRoot.BundleRoot)
            }
            $arguments += @(
                '-CatalogPath', $InputRoot.CatalogPath,
                '-OutputRoot', $InputRoot.OutputRoot,
                '-ProgressPath', $InputRoot.ProgressPath,
                '-ReportPath', $InputRoot.ReportPath,
                '-CancelSignalPath', $InputRoot.CancelSignalPath
            )

            $output = & pwsh @arguments 2>&1
            if (Test-Path -LiteralPath $InputRoot.ReportPath -PathType Leaf) {
                try {
                    $report = Get-Content -LiteralPath $InputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                    if ($report.ContainsKey('archiveImport') -and $null -ne $report.archiveImport -and -not [string]::IsNullOrWhiteSpace([string]$report.archiveImport.extractedBundleRoot)) {
                        $script:extractedRootsToRemove.Add([string]$report.archiveImport.extractedBundleRoot)
                    }
                }
                catch {
                }
            }

            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = ($output -join [Environment]::NewLine)
            }
        }
    }

    AfterAll {
        $bundleRoot = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'bundle')).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        foreach ($root in @($script:extractedRootsToRemove | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $fullRoot = [System.IO.Path]::GetFullPath($root)
            if ($fullRoot.StartsWith($bundleRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullRoot -PathType Container)) {
                Remove-Item -LiteralPath $fullRoot -Recurse -Force
            }
        }
    }

    It 'returns exit code 2 and writes a wrapper report for input validation failure' {
        $inputRoot = New-MinimalWrapperInput
        Remove-Item -LiteralPath $inputRoot.BundleRoot -Recurse -Force

        $result = Invoke-Wrapper -InputRoot $inputRoot
        if ([int]$result.ExitCode -ne 2) {
            throw "Expected exit code 2, got $($result.ExitCode): $($result.Output)"
        }
        if (-not (Test-Path -LiteralPath $inputRoot.ReportPath -PathType Leaf)) {
            throw 'Expected wrapper report to be written on input failure.'
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.status -ne 'ERROR') {
            throw "Expected ERROR wrapper status, got $($report.status)"
        }
        if ([string]$report.issues[0].code -ne 'ASB-ASM-WRAPPER-INPUT-FAILED') {
            throw "Expected input failure issue code, got $($report.issues[0].code)"
        }
    }

    It 'imports a valid bundle archive under repo bundle staging and calls backend with the extracted folder' {
        $inputRoot = New-ArchiveWrapperInput

        $result = Invoke-Wrapper -InputRoot $inputRoot -UseArchive
        if ([int]$result.ExitCode -ne 1) {
            throw "Expected backend failure exit code 1 after successful archive import, got $($result.ExitCode): $($result.Output)"
        }

        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if (-not $report.ContainsKey('archiveImport') -or [string]$report.archiveImport.status -ne 'OK') {
            throw 'Expected archiveImport status OK.'
        }
        $repoBundleRoot = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'bundle')).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $extractedRoot = [string]$report.archiveImport.extractedBundleRoot
        if (-not $extractedRoot.StartsWith($repoBundleRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Expected extracted root under repo bundle folder, got '$extractedRoot'."
        }
        if (@($report.backend.arguments) -notcontains $extractedRoot) {
            throw 'Expected backend arguments to include extracted bundle root.'
        }
    }

    It 'rejects BundleRoot and BundleArchivePath together with exit code 2' {
        $inputRoot = New-ArchiveWrapperInput

        $result = Invoke-Wrapper -InputRoot $inputRoot -UseArchive -IncludeBothBundleInputs
        if ([int]$result.ExitCode -ne 2) {
            throw "Expected exit code 2, got $($result.ExitCode): $($result.Output)"
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.issues[0].code -ne 'ASB-ASM-WRAPPER-INPUT-FAILED') {
            throw "Expected input failure issue code, got $($report.issues[0].code)"
        }
    }

    It 'rejects an unsafe archive path before extraction' {
        $inputRoot = New-ArchiveWrapperInput
        $unsafeArchive = Join-Path $inputRoot.Root 'unsafe.lnvbundle.zip'
        New-UnsafeArchive -ArchivePath $unsafeArchive
        $inputRoot.BundleArchivePath = $unsafeArchive

        $result = Invoke-Wrapper -InputRoot $inputRoot -UseArchive
        if ([int]$result.ExitCode -ne 2) {
            throw "Expected exit code 2, got $($result.ExitCode): $($result.Output)"
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.issues[0].code -ne 'ASB-ASM-WRAPPER-ARCHIVE-IMPORT-FAILED') {
            throw "Expected archive import failure issue code, got $($report.issues[0].code)"
        }
        if (Test-Path -LiteralPath ([string]$report.archiveImport.extractedBundleRoot) -PathType Container) {
            throw 'Unsafe archive should fail before extraction.'
        }
    }

    It 'rejects a tampered archive file hash before backend render' {
        $inputRoot = New-ArchiveWrapperInput
        $tamperedArchive = Join-Path $inputRoot.Root 'tampered.lnvbundle.zip'
        New-TestBundleArchive -BundleRoot $inputRoot.BundleRoot -ArchivePath $tamperedArchive -TamperPath 'objectIndex.json'
        $inputRoot.BundleArchivePath = $tamperedArchive

        $result = Invoke-Wrapper -InputRoot $inputRoot -UseArchive
        if ([int]$result.ExitCode -ne 2) {
            throw "Expected exit code 2, got $($result.ExitCode): $($result.Output)"
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.issues[0].code -ne 'ASB-ASM-WRAPPER-ARCHIVE-IMPORT-FAILED') {
            throw "Expected archive import failure issue code, got $($report.issues[0].code)"
        }
        if ($null -ne $report.backend.exitCode) {
            throw 'Expected backend not to run for tampered archive.'
        }
    }

    It 'rejects an archive missing a manifest-listed file before backend render' {
        $inputRoot = New-ArchiveWrapperInput
        $missingArchive = Join-Path $inputRoot.Root 'missing.lnvbundle.zip'
        New-TestBundleArchive -BundleRoot $inputRoot.BundleRoot -ArchivePath $missingArchive -SkipPath 'objectIndex.json'
        $inputRoot.BundleArchivePath = $missingArchive

        $result = Invoke-Wrapper -InputRoot $inputRoot -UseArchive
        if ([int]$result.ExitCode -ne 2) {
            throw "Expected exit code 2, got $($result.ExitCode): $($result.Output)"
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.issues[0].code -ne 'ASB-ASM-WRAPPER-ARCHIVE-IMPORT-FAILED') {
            throw "Expected archive import failure issue code, got $($report.issues[0].code)"
        }
        if ([string]::Join(';', @($report.archiveImport.errors)) -notlike '*missing from bundle*') {
            throw "Expected missing file error, got '$([string]::Join(';', @($report.archiveImport.errors)))'."
        }
    }

    It 'rejects an archive with an extra non-manifest file before backend render' {
        $inputRoot = New-ArchiveWrapperInput
        $extraArchive = Join-Path $inputRoot.Root 'extra.lnvbundle.zip'
        New-TestBundleArchive -BundleRoot $inputRoot.BundleRoot -ArchivePath $extraArchive -AddExtra
        $inputRoot.BundleArchivePath = $extraArchive

        $result = Invoke-Wrapper -InputRoot $inputRoot -UseArchive
        if ([int]$result.ExitCode -ne 2) {
            throw "Expected exit code 2, got $($result.ExitCode): $($result.Output)"
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.issues[0].code -ne 'ASB-ASM-WRAPPER-ARCHIVE-IMPORT-FAILED') {
            throw "Expected archive import failure issue code, got $($report.issues[0].code)"
        }
        if ([string]::Join(';', @($report.archiveImport.errors)) -notlike '*extra file*') {
            throw "Expected extra file error, got '$([string]::Join(';', @($report.archiveImport.errors)))'."
        }
    }

    It 'emits progress JSONL and returns exit code 130 when cancelled before backend render' {
        $inputRoot = New-MinimalWrapperInput
        Set-Content -LiteralPath $inputRoot.CancelSignalPath -Value 'cancel' -Encoding UTF8

        $result = Invoke-Wrapper -InputRoot $inputRoot
        if ([int]$result.ExitCode -ne 130) {
            throw "Expected exit code 130, got $($result.ExitCode): $($result.Output)"
        }
        $events = @(Get-Content -LiteralPath $inputRoot.ProgressPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        if (@($events).Count -eq 0) {
            throw 'Expected progress events.'
        }
        foreach ($key in @('timestampUtc','stage','level','status','percent','message','currentItem')) {
            if (-not $events[0].ContainsKey($key)) {
                throw "Expected progress event key '$key'."
            }
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.status -ne 'CANCELLED') {
            throw "Expected CANCELLED wrapper status, got $($report.status)"
        }
    }

    It 'propagates backend failure as exit code 1 without changing backend report naming' {
        $inputRoot = New-MinimalWrapperInput

        $result = Invoke-Wrapper -InputRoot $inputRoot
        if ([int]$result.ExitCode -ne 1) {
            throw "Expected exit code 1, got $($result.ExitCode): $($result.Output)"
        }
        $report = Get-Content -LiteralPath $inputRoot.ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ([string]$report.backend.scriptPath -notmatch 'Invoke-AssemblerBundleRender\.ps1$') {
            throw "Expected backend script path to point at Invoke-AssemblerBundleRender.ps1, got $($report.backend.scriptPath)"
        }
        if (Test-Path -LiteralPath (Join-Path $inputRoot.OutputRoot 'render-report.json') -PathType Leaf) {
            return
        }
        throw 'Expected wrapper render-report.json to be present.'
    }
}
