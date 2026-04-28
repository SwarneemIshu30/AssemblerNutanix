Describe 'Invoke-AssemblerBundleRender DOCX match mode forwarding' {
    BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot

    function New-MinimalContractsRoot {
        param(
            [Parameter(Mandatory = $true)][string]$Root
        )

        $sourceContractsRoot = Join-Path $script:repoRoot '.deps/contracts'
        $contractsRoot = Join-Path $Root 'contracts'
        $null = New-Item -Path $contractsRoot -ItemType Directory -Force

        $schemaRelativePaths = @(
            'standards/mapping.dataset-to-sdt.schema.v1.json',
            'standards/assembler/assembler.projections.schema.v1.json',
            'standards/assembler/assembler.render-report.schema.v1.json',
            'standards/assembler/assembler.template-catalog.schema.v1.json',
            'standards/assembler/assembler.bundle-render-report.schema.v1.json'
        )

        foreach ($schemaRelativePath in $schemaRelativePaths) {
            $sourcePath = Join-Path $sourceContractsRoot $schemaRelativePath
            $targetPath = Join-Path $contractsRoot $schemaRelativePath
            $targetDir = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                $null = New-Item -Path $targetDir -ItemType Directory -Force
            }
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
        }

        $techRoot = Join-Path $contractsRoot 'tech/Test.Tech'
        $null = New-Item -Path $techRoot -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $techRoot 'assembler.projections.v1.json') -Encoding UTF8 -Value (@{
            schema = 'assembler.projections'
            schemaVersion = 1
            techId = 'Test.Tech'
            displayName = 'Test.Tech projection definitions'
            projections = @{ 'LNV.Test.Tech.Placeholder' = @{ renderMode = 'scalar'; renderAs = 'scalar' } }
        } | ConvertTo-Json -Depth 10)

        return $contractsRoot
    }

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

    It 'forwards DocxMatchMode to nested SDT render diagnostics' {
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('assembler-bundle-docx-mode-test-' + [guid]::NewGuid().ToString())
        $bundleRoot = Join-Path $tempRoot 'bundle'
        $catalogRoot = Join-Path $tempRoot 'catalog'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            $null = New-Item -ItemType Directory -Path $bundleRoot -Force
            $null = New-Item -ItemType Directory -Path $catalogRoot -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $bundleRoot 'config') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $bundleRoot 'datasets') -Force

            Set-Content -LiteralPath (Join-Path $bundleRoot 'manifest.json') -Encoding UTF8 -Value (@{ bundleId = 'bundle-test' } | ConvertTo-Json -Depth 5)
            Set-Content -LiteralPath (Join-Path $bundleRoot 'objectIndex.json') -Encoding UTF8 -Value (@{ objects = @(@{ techId = 'Test.Tech' }) } | ConvertTo-Json -Depth 5)
            Set-Content -LiteralPath (Join-Path $bundleRoot 'config/solution.plan.json') -Encoding UTF8 -Value (@{ collectors = @(@{ techId = 'Test.Tech'; targetKeys = @() }) } | ConvertTo-Json -Depth 5)
            Set-Content -LiteralPath (Join-Path $bundleRoot 'datasets/transport.json') -Encoding UTF8 -Value (@{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'transport'
                item_count = 1
                items = @(@{ status = 'Ready' })
            } | ConvertTo-Json -Depth 10)

            $mappingPath = Join-Path $catalogRoot 'forwarding.mapping.json'
            Set-Content -LiteralPath $mappingPath -Encoding UTF8 -Value (@{
                schema = 'mapping.dataset-to-sdt'
                schemaVersion = 1
                techId = 'Test.Tech'
                displayName = 'forwarding mapping'
                compatibility = @{ contracts = @{ version = 'v1' } }
                strictContracts = @{ enabled = $true; requireAllMappings = $true }
                mappings = @(
                    @{
                        dataset = 'datasets/transport.json'
                        required = $true
                        selectors = @('items', '0', 'status')
                        target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus' }
                    }
                )
            } | ConvertTo-Json -Depth 10)

            $templatePath = Join-Path $catalogRoot 'forwarding-template.docx'
            New-TestDocxTemplate -Path $templatePath -Tag 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus'
            $catalogPath = Join-Path $catalogRoot 'forwarding.catalog.json'
            Set-Content -LiteralPath $catalogPath -Encoding UTF8 -Value (@{
                schema = 'assembler.template-catalog'
                schemaVersion = 1
                displayName = 'forwarding catalog'
                entries = @(
                    @{
                        id = 'docx-forwarding'
                        techId = 'Test.Tech'
                        displayName = 'DOCX forwarding test'
                        docType = 'test'
                        mappingPath = 'forwarding.mapping.json'
                        templatePath = 'forwarding-template.docx'
                        outputFileName = 'forwarding-rendered.docx'
                        enabled = $true
                        priority = 100
                    }
                )
            } | ConvertTo-Json -Depth 10)

            $contractsRoot = New-MinimalContractsRoot -Root $tempRoot
            $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1'
            $json = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -CatalogPath $catalogPath -OutputRoot $outputRoot -ContractsRoot $contractsRoot -TechId 'Test.Tech' -DocTitle 'My Title' -DocCustomer 'Acme Customer' -DocxMatchMode 'literal-token'
            if ($LASTEXITCODE -ne 0) {
                throw "Expected successful bundle render exit code, got $LASTEXITCODE. Output: $json"
            }

            $report = $json | ConvertFrom-Json -AsHashtable
            if ([string]$report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }

            $run = @($report.runs)[0]
            $variant = @($run.variants)[0]
            if ([System.IO.Path]::GetFileName([string]$variant.outputPath) -ne 'My Title - Acme Customer.docx') {
                throw "Expected preferred output filename, got '$([System.IO.Path]::GetFileName([string]$variant.outputPath))'"
            }
            $renderStage = @($variant.rendererOutput.stages | Where-Object { $_.name -eq 'Render' }) | Select-Object -First 1
            if ($null -eq $renderStage) { throw 'Expected nested renderer render stage diagnostics.' }
            if ($null -ne $renderStage.details -and -not [string]::IsNullOrWhiteSpace([string]$renderStage.details.docxMatchMode)) {
                if ([string]$renderStage.details.docxMatchMode -ne 'literal-token') {
                    throw "Expected nested renderer docxMatchMode=literal-token, got '$($renderStage.details.docxMatchMode)'"
                }
            }
            if ([string]$variant.rendererOutput.status -ne 'OK') {
                throw "Expected nested renderer status OK, got '$($variant.rendererOutput.status)'"
            }
            $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$variant.outputPath)
            try {
                $entry = $zip.GetEntry('word/document.xml')
                if ($null -eq $entry) { throw 'Expected rendered DOCX to contain word/document.xml.' }
                $reader = [System.IO.StreamReader]::new($entry.Open())
                try {
                    $documentXml = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }
            }
            finally {
                $zip.Dispose()
            }
            try {
                [xml]$null = $documentXml
            }
            catch {
                throw "Expected bundle-rendered DOCX document.xml to be well-formed XML, got '$($_.Exception.Message)'"
            }
            if ($documentXml -notmatch '<w:t(?: xml:space="preserve")?>Ready</w:t>') {
                throw "Expected bundle-rendered DOCX to contain the literal-token replacement, got '$documentXml'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}



