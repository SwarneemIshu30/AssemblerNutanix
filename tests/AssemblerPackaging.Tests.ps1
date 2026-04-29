Describe 'Assembler package include manifest' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:includePath = Join-Path $script:repoRoot '.packaging/assembler-package.include'
        $script:packageScriptPath = Join-Path $script:repoRoot 'scripts/New-AssemblerPackage.ps1'
    }

    It 'includes runtime assets needed by wrapper, GUI, and pipeline flows' {
        $includeText = Get-Content -LiteralPath $script:includePath -Raw -Encoding UTF8
        foreach ($expected in @(
            'scripts/Invoke-LnvAssemblerRender.ps1',
            'scripts/Restore-WebView2Dependency.ps1',
            'scripts/Test-AssemblerMappingShapeMode.ps1',
            'scripts/internal',
            'gui',
            '.deps/contracts'
        )) {
            if ($includeText -notmatch [regex]::Escape($expected)) {
                throw "Expected package include manifest to contain '$expected'."
            }
        }
    }

    It 'creates a zip that preserves dot-prefixed runtime dependencies' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $outputDir = 'dist/package-test-{0}' -f ([guid]::NewGuid().ToString('N'))
        $outputFullPath = Join-Path $script:repoRoot $outputDir

        try {
            & $script:packageScriptPath -OutputDir $outputDir -BuildChannel dev -PackageVersion '0.0.0-test'

            $manifestPath = Join-Path $outputFullPath 'package.manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $zipPath = Join-Path $script:repoRoot ([string]$manifest.zipPath)

            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                $entryNames = @($zip.Entries | ForEach-Object { $_.FullName })
            }
            finally {
                $zip.Dispose()
            }

            foreach ($expectedEntry in @(
                '.deps/contracts/contracts.snapshot.json',
                '.deps/contracts/standards/mapping.dataset-to-sdt.schema.v1.json',
                '.deps/contracts/standards/assembler/assembler.render-report.schema.v1.json',
                'scripts/Test-AssemblerMappingShapeMode.ps1'
            )) {
                if ($expectedEntry -notin $entryNames) {
                    throw "Expected package zip to contain '$expectedEntry'."
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $outputFullPath) {
                Remove-Item -LiteralPath $outputFullPath -Recurse -Force
            }
        }
    }
}
