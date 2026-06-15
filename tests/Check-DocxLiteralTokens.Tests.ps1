Describe 'Check-DocxLiteralTokens script' {
    BeforeAll {
    function New-TestDocxTemplate {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Tag
        )

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $templateDir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $templateDir -PathType Container)) {
            $null = New-Item -Path $templateDir -ItemType Directory -Force
        }

        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                $contentTypes = $archive.CreateEntry('[Content_Types].xml')
                $contentTypesStream = $contentTypes.Open()
                try {
                    $writer = [System.IO.StreamWriter]::new($contentTypesStream, [System.Text.UTF8Encoding]::new($false))
                    $writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>')
                    $writer.Flush()
                    $writer.Dispose()
                }
                finally {
                    $contentTypesStream.Dispose()
                }

                $rels = $archive.CreateEntry('_rels/.rels')
                $relsStream = $rels.Open()
                try {
                    $writer = [System.IO.StreamWriter]::new($relsStream, [System.Text.UTF8Encoding]::new($false))
                    $writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
                    $writer.Flush()
                    $writer.Dispose()
                }
                finally {
                    $relsStream.Dispose()
                }

                $document = $archive.CreateEntry('word/document.xml')
                $docStream = $document.Open()
                try {
                    $writer = [System.IO.StreamWriter]::new($docStream, [System.Text.UTF8Encoding]::new($false))
                    $writer.Write("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:document xmlns:w=`"http://schemas.openxmlformats.org/wordprocessingml/2006/main`"><w:body><w:p><w:r><w:t>&lt;&lt;SDT:$Tag&gt;&gt;</w:t></w:r></w:p></w:body></w:document>")
                    $writer.Flush()
                    $writer.Dispose()
                }
                finally {
                    $docStream.Dispose()
                }

                $styles = $archive.CreateEntry('word/styles.xml')
                $stylesStream = $styles.Open()
                try {
                    $writer = [System.IO.StreamWriter]::new($stylesStream, [System.Text.UTF8Encoding]::new($false))
                    $writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>')
                    $writer.Flush()
                    $writer.Dispose()
                }
                finally {
                    $stylesStream.Dispose()
                }
            }
            finally {
                $archive.Dispose()
            }
        }
        finally {
            $fs.Dispose()
        }
    }

    }

    It 'reports the same OK and MISSING statuses as the shared literal-token discovery helper' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('assembler-check-docx-literal-test-' + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $docxPath = Join-Path $tempRoot 'checker-template.docx'
            $mappingPath = Join-Path $tempRoot 'checker-mapping.json'
            New-TestDocxTemplate -Path $docxPath -Tag 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus'
            Set-Content -LiteralPath $mappingPath -Encoding UTF8 -Value (@{
                schema = 'mapping.dataset-to-sdt'
                schemaVersion = 1
                techId = 'Test.Tech'
                displayName = 'checker mapping'
                compatibility = @{ contracts = @{ version = 'v1' } }
                strictContracts = @{ enabled = $true; requireAllMappings = $true }
                mappings = @(
                    @{ dataset = 'datasets/transport.json'; target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus' } },
                    @{ dataset = 'datasets/transport.json'; target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.MissingStatus' } }
                )
            } | ConvertTo-Json -Depth 10)

            $docxRelative = [System.IO.Path]::GetRelativePath($repoRoot, $docxPath)
            $mappingRelative = [System.IO.Path]::GetRelativePath($repoRoot, $mappingPath)
            $scriptPath = Join-Path $repoRoot 'scripts/Check-DocxLiteralTokens.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -DocxPath $docxRelative -MappingPath $mappingRelative | Out-String
            if ($LASTEXITCODE -ne 0) {
                throw "Expected successful checker exit code, got $LASTEXITCODE. Output: $output"
            }

            if ($output -notmatch 'Summary: .*MISSING=1.*OK=1|Summary: .*OK=1.*MISSING=1') {
                throw "Expected checker summary to report one OK and one MISSING tag, got '$output'"
            }
            if ($output -notmatch 'LegacyStatus\s+OK\s+1') {
                throw "Expected checker output to report LegacyStatus as OK with one contiguous hit, got '$output'"
            }
            if ($output -notmatch 'MissingStatus\s+MISSING\s+0') {
                throw "Expected checker output to report MissingStatus as MISSING with zero hits, got '$output'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
