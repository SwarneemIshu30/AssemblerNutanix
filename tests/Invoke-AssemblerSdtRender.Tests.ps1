Describe 'Invoke-AssemblerSdtRender integration' {
    BeforeAll {
        $scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-AssemblerSdtRender.ps1'
        $scriptSource = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
        $functionBlock = [regex]::Match(
            $scriptSource,
            '(?s)function Read-JsonFile \{.*?^}\s*.*?function ConvertTo-PlainHashtable \{.*?^}\s*.*?function Test-ProjectionContractJsonArrayShape \{.*?^}\s*.*?function Read-ProjectionContractFile \{.*?^}',
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        ).Value

        if ([string]::IsNullOrWhiteSpace($functionBlock)) {
            throw 'Failed to load projection contract helper functions from script under test.'
        }

        Invoke-Expression $functionBlock
    }

    function New-TestRenderFixture {
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][object[]]$Mappings,
            [Parameter(Mandatory = $true)][string]$Template,
            [Parameter(Mandatory = $false)][hashtable]$Dataset,
            [Parameter(Mandatory = $false)][string]$DatasetRelativePath = 'datasets/systems.json',
            [Parameter(Mandatory = $false)][string]$TechId = 'Lenovo.DE'
        )

        $bundleRoot = Join-Path $Root 'bundle'
        $datasetsRoot = Join-Path $bundleRoot 'datasets'
        $null = New-Item -Path $datasetsRoot -ItemType Directory -Force

        $manifestPath = Join-Path $bundleRoot 'manifest.json'
        Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value (@{
            bundleId = 'bundle-test'
        } | ConvertTo-Json -Depth 5)

        $datasetPath = Join-Path $bundleRoot $DatasetRelativePath
        $datasetDir = Split-Path -Parent $datasetPath
        if (-not (Test-Path -LiteralPath $datasetDir -PathType Container)) {
            $null = New-Item -Path $datasetDir -ItemType Directory -Force
        }
        $datasetPayload = if ($PSBoundParameters.ContainsKey('Dataset')) {
            $Dataset
        }
        else {
            @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{ name = 'ArrayOne'; status = 'online' }
                )
            }
        }
        Set-Content -LiteralPath $datasetPath -Encoding UTF8 -Value ($datasetPayload | ConvertTo-Json -Depth 10)

        $mappingPath = Join-Path $Root 'mapping.json'
        Set-Content -LiteralPath $mappingPath -Encoding UTF8 -Value (@{
            schema = 'mapping.dataset-to-sdt'
            schemaVersion = 1
            techId = $TechId
            displayName = 'test mapping'
            compatibility = @{ contracts = @{ version = 'v1' } }
            strictContracts = @{ enabled = $true; requireAllMappings = $true }
            mappings = $Mappings
        } | ConvertTo-Json -Depth 10)

        $templatePath = Join-Path $Root 'template.txt'
        Set-Content -LiteralPath $templatePath -Encoding UTF8 -Value $Template

        return @{
            bundleRoot = $bundleRoot
            mappingPath = $mappingPath
            templatePath = $templatePath
            outputPath = (Join-Path $Root 'rendered.txt')
            reportPath = (Join-Path $Root 'report.json')
        }
    }

    function New-MinimalContractsRoot {
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][string]$DatasetName
        )

        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sourceContractsRoot = Join-Path $repoRoot '.deps/contracts'
        $contractsRoot = Join-Path $Root 'contracts'
        $null = New-Item -Path $contractsRoot -ItemType Directory -Force

        $schemaRelativePaths = @(
            'standards/mapping.dataset-to-sdt.schema.v1.json',
            'standards/assembler/assembler.projections.schema.v1.json',
            'standards/assembler/assembler.render-report.schema.v1.json'
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
        $datasetRoot = Join-Path $techRoot 'dataset'
        $null = New-Item -Path $datasetRoot -ItemType Directory -Force

        $projectionRef = 'LNV.Test.Tech.System[ArrayName].Tables.Sample'
        $projectionContractPath = Join-Path $techRoot 'assembler.projections.v1.json'
        Set-Content -LiteralPath $projectionContractPath -Encoding UTF8 -Value (@{
            schema = 'assembler.projections'
            schemaVersion = 1
            techId = 'Test.Tech'
            displayName = 'Test.Tech projection definitions'
            projections = @{
                $projectionRef = @{
                    columns = @(
                        @{ name = 'Controller'; source = 'controllerLabel' },
                        @{ name = 'Address'; source = 'ipv4Address' },
                        @{ name = 'IQN'; source = 'iqn' }
                    )
                    renderMode = 'table'
                    renderAs = 'table'
                    emptyBehavior = 'render-empty'
                    identityKeys = @('controllerLabel')
                    rowOrder = @('controllerLabel')
                }
            }
        } | ConvertTo-Json -Depth 10)

        $datasetMetadataPath = Join-Path $datasetRoot "$DatasetName.assembler.meta.json"
        Set-Content -LiteralPath $datasetMetadataPath -Encoding UTF8 -Value (@{
            schemaVersion = 1
            dataset = $DatasetName
            presentationKind = 'table'
            defaultItemRoot = 'items'
            preferredProjectionViews = @(
                @{
                    name = 'Sample'
                    projectionRef = $projectionRef
                }
            )
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
                    $writer.Write("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:document xmlns:w=`"http://schemas.openxmlformats.org/wordprocessingml/2006/main`"><w:body><w:sdt><w:sdtContent><w:p><w:r><w:t>&lt;&lt;SDT:$Tag&gt;&gt;</w:t></w:r></w:p></w:sdtContent></w:sdt></w:body></w:document>")
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
                    $writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="table" w:styleId="LNVTable1-9ptHeadBandedGrid"><w:name w:val="LNV Table 1 - 9pt Head Banded Grid"/></w:style></w:styles>')
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

    function New-TestTaggedContentControlDocxTemplate {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$ScalarTag,
            [Parameter(Mandatory = $true)][string]$TableTag,
            [Parameter(Mandatory = $false)][string]$LegacyTokenTag,
            [Parameter(Mandatory = $false)][string]$UnmatchedTag
        )

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $templateDir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $templateDir -PathType Container)) {
            $null = New-Item -Path $templateDir -ItemType Directory -Force
        }

        $legacyParagraphXml = ''
        if (-not [string]::IsNullOrWhiteSpace($LegacyTokenTag)) {
            $legacyParagraphXml = "<w:p><w:r><w:t>&lt;&lt;SDT:$LegacyTokenTag&gt;&gt;</w:t></w:r></w:p>"
        }
        $unmatchedSdtXml = ''
        if (-not [string]::IsNullOrWhiteSpace($UnmatchedTag)) {
            $unmatchedSdtXml = @"
    <w:sdt>
      <w:sdtPr>
        <w:tag w:val="$UnmatchedTag"/>
      </w:sdtPr>
      <w:sdtContent>
        <w:p><w:r><w:t>ORIGINAL-UNMATCHED</w:t></w:r></w:p>
      </w:sdtContent>
    </w:sdt>
"@
        }

        $documentXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:sdt>
      <w:sdtPr>
        <w:tag w:val="$ScalarTag"/>
      </w:sdtPr>
      <w:sdtContent>
        <w:p><w:r><w:t>ORIGINAL-SCALAR</w:t></w:r></w:p>
      </w:sdtContent>
    </w:sdt>
    <w:sdt>
      <w:sdtPr>
        <w:tag w:val="$TableTag"/>
      </w:sdtPr>
      <w:sdtContent>
        <w:p><w:r><w:t>ORIGINAL-TABLE</w:t></w:r></w:p>
      </w:sdtContent>
    </w:sdt>
    $unmatchedSdtXml
    $legacyParagraphXml
  </w:body>
</w:document>
"@

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
                    $writer.Write($documentXml)
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
                    $writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="table" w:styleId="LNVTable1-9ptHeadBandedGrid"><w:name w:val="LNV Table 1 - 9pt Head Banded Grid"/></w:style></w:styles>')
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

    function Set-TestDocxEntryText {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$EntryName,
            [Parameter(Mandatory = $true)][string]$Text
        )

        $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry = $archive.GetEntry($EntryName)
            if ($null -eq $entry) {
                throw "Expected DOCX entry '$EntryName' to exist in '$Path'."
            }

            $entry.Delete()
            $updatedEntry = $archive.CreateEntry($EntryName)
            $stream = $updatedEntry.Open()
            try {
                $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
                $writer.Write($Text)
                $writer.Flush()
                $writer.Dispose()
            }
            finally {
                $stream.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }

    It 'keeps successful render reports schema-valid when matches are emitted' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-render-report-schema-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                    target = @{ sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName' }
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw 'Expected successful render exit code' }

            $report = $output | ConvertFrom-Json -AsHashtable
            $schemaIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-RENDERREPORT-INVALID' })
            if ($schemaIssues.Count -ne 0) {
                throw "Expected render report with matches to remain schema-valid, but found: $($schemaIssues[0].message)"
            }

            $match = @($report.matches | Where-Object { $_.tag -eq 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName' }) | Select-Object -First 1
            if ($null -eq $match) {
                throw 'Expected successful render report to include a match entry for the populated tag.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders DOCX table XML for table render mode using the named Word table style' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-docx-table-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'unused' -TechId 'Test.Tech' -DatasetRelativePath 'datasets/transport.json' -Mappings @(
                @{
                    dataset = 'datasets/transport.json'
                    required = $true
                    selectors = @('items')
                    target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Tables.Sample' }
                }
            ) -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'transport'
                item_count = 2
                items = @(
                    @{ controllerLabel = 'A'; ipv4Address = '10.0.0.1'; iqn = 'iqn.1' },
                    @{ controllerLabel = 'B'; ipv4Address = '10.0.0.2'; iqn = 'iqn.2' }
                )
            }
            $contractsRoot = New-MinimalContractsRoot -Root $tempRoot -DatasetName 'transport'
            $templatePath = Join-Path $tempRoot 'template.docx'
            New-TestDocxTemplate -Path $templatePath -Tag 'LNV.Test.Tech.System[ArrayName].Tables.Sample'
            $outputPath = Join-Path $tempRoot 'rendered.docx'
            $reportPath = Join-Path $tempRoot 'report.json'

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw "Expected successful render exit code, got $exitCode. Output: $output" }

            $zip = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
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

            if ($documentXml -notmatch '<w:tbl') { throw "Expected rendered DOCX to include a Word table node, got '$documentXml'" }
            if ($documentXml -notmatch 'w:tblStyle w:val=\"LNVTable1-9ptHeadBandedGrid\"') { throw "Expected rendered DOCX table to apply template styleId, got '$documentXml'" }
            if ($documentXml -notmatch '<w:t>Controller</w:t>') { throw "Expected table header cells from projection columns, got '$documentXml'" }
            if ($documentXml -notmatch '<w:t xml:space=\"preserve\">10.0.0.1</w:t>') { throw "Expected projected body cell values, got '$documentXml'" }
            if ($documentXml -match '&lt;&lt;SDT:LNV\.Test\.Tech\.System\[ArrayName\]\.Tables\.Sample&gt;&gt;') { throw "Expected SDT placeholder token to be replaced, got '$documentXml'" }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses w:sdt tag-based replacement for DOCX controls without implicit literal-token fallback' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-docx-tagged-sdt-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'unused' -TechId 'Test.Tech' -DatasetRelativePath 'datasets/transport.json' -Mappings @(
                @{
                    dataset = 'datasets/transport.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                    target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.Name' }
                },
                @{
                    dataset = 'datasets/transport.json'
                    required = $true
                    selectors = @('items')
                    target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Tables.Sample' }
                },
                @{
                    dataset = 'datasets/transport.json'
                    required = $true
                    selectors = @('items', '0', 'status')
                    target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus' }
                }
            ) -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'transport'
                item_count = 2
                items = @(
                    @{ name = 'Alpha & Beta <Prod>'; status = 'Ready'; controllerLabel = 'A'; ipv4Address = '10.0.0.1'; iqn = 'iqn.1' },
                    @{ name = 'Backup Node'; status = 'Standby'; controllerLabel = 'B'; ipv4Address = '10.0.0.2'; iqn = 'iqn.2' }
                )
            }

            $contractsRoot = New-MinimalContractsRoot -Root $tempRoot -DatasetName 'transport'
            $templatePath = Join-Path $tempRoot 'tagged-template.docx'
            New-TestTaggedContentControlDocxTemplate -Path $templatePath -ScalarTag 'LNV.Test.Tech.System[ArrayName].Summary.Name' -TableTag 'LNV.Test.Tech.System[ArrayName].Tables.Sample' -LegacyTokenTag 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus' -UnmatchedTag 'LNV.Test.Tech.System[ArrayName].Summary.Unmatched'
            $outputPath = Join-Path $tempRoot 'tagged-rendered.docx'
            $reportPath = Join-Path $tempRoot 'report.json'

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot -DocxMatchMode 'content-control-tag'
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw "Expected successful render exit code, got $exitCode. Output: $output" }
            $report = $output | ConvertFrom-Json -AsHashtable

            $zip = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
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

            if ($documentXml -notmatch 'Alpha &amp; Beta &lt;Prod&gt;') { throw "Expected scalar SDT content to be XML-escaped replacement text, got '$documentXml'" }
            if ($documentXml -notmatch '<w:tag w:val=\"LNV\.Test\.Tech\.System\[ArrayName\]\.Summary\.Name\"/>') { throw "Expected scalar SDT tag to remain in document, got '$documentXml'" }
            if ($documentXml -notmatch '<w:tbl') { throw "Expected table SDT content to include a Word table node, got '$documentXml'" }
            if ($documentXml -notmatch 'w:tblStyle w:val=\"LNVTable1-9ptHeadBandedGrid\"') { throw "Expected table SDT content to apply template styleId, got '$documentXml'" }
            if ($documentXml -notmatch '&lt;&lt;SDT:LNV\.Test\.Tech\.System\[ArrayName\]\.Summary\.LegacyStatus&gt;&gt;') { throw "Expected legacy literal placeholder token to remain when DocxMatchMode=content-control-tag, got '$documentXml'" }
            if ($documentXml -match 'ORIGINAL-SCALAR|ORIGINAL-TABLE') { throw "Expected original SDT placeholder content to be replaced, got '$documentXml'" }
            if ($documentXml -notmatch 'ORIGINAL-UNMATCHED') { throw "Expected unmatched tagged SDT content to remain unchanged, got '$documentXml'" }

            $renderStage = @($report.stages | Where-Object { $_.name -eq 'Render' }) | Select-Object -First 1
            if ($null -eq $renderStage) { throw 'Expected render stage diagnostics in report.' }
            if ([int]$renderStage.details.docxControlsDiscovered -ne 3) { throw "Expected docxControlsDiscovered=3, got '$($renderStage.details.docxControlsDiscovered)'" }
            if ([int]$renderStage.details.docxTaggedControlsMatched -ne 2) { throw "Expected docxTaggedControlsMatched=2, got '$($renderStage.details.docxTaggedControlsMatched)'" }
            if ([int]$renderStage.details.docxControlsPopulated -ne 2) { throw "Expected docxControlsPopulated=2, got '$($renderStage.details.docxControlsPopulated)'" }
            if ([string]$renderStage.details.docxMatchMode -ne 'content-control-tag') { throw "Expected docxMatchMode=content-control-tag, got '$($renderStage.details.docxMatchMode)'" }
            $unmatchedTags = @($renderStage.details.docxUnmatchedTaggedControls)
            if (@($unmatchedTags | Where-Object { $_ -eq 'LNV.Test.Tech.System[ArrayName].Summary.Unmatched' }).Count -ne 1) {
                throw "Expected unmatched tagged controls to include LNV.Test.Tech.System[ArrayName].Summary.Unmatched, got '$($unmatchedTags -join ',')'"
            }
            $docxUnresolvedLiteralTokens = @($renderStage.details.docxUnresolvedLiteralTokens)
            if (@($docxUnresolvedLiteralTokens | Where-Object { $_ -eq 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus' }).Count -ne 1) {
                throw "Expected unresolved literal token diagnostics to include LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus, got '$($docxUnresolvedLiteralTokens -join ',')'"
            }
            if (@($docxUnresolvedLiteralTokens | Where-Object { $_ -eq 'LNV.Test.Tech.System[ArrayName].Summary.Unmatched' }).Count -ne 0) {
                throw "Expected unresolved literal token diagnostics to exclude unmatched tagged controls, got '$($docxUnresolvedLiteralTokens -join ',')'"
            }
            $literalIssue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-UNRESOLVED-LITERAL-TOKEN' -and $_.message -match "LegacyStatus" }) | Select-Object -First 1
            if ($null -eq $literalIssue) {
                throw 'Expected unresolved literal token issue in content-control-tag mode'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'discovers and matches tagged controls for the Lenovo template fixture in content-control-tag mode' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-docx-lenovo-template-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'unused' -DatasetRelativePath 'datasets/systems.json' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                    target = @{ sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Summary' }
                }
            ) -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{ name = 'Lenovo Fixture System' }
                )
            }

            $templatePath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/SK_Lenovo_DE_DRAFT_v0.1.docx'
            $outputPath = Join-Path $tempRoot 'lenovo-template-rendered.docx'
            $reportPath = Join-Path $tempRoot 'report.json'

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot -DocxMatchMode 'content-control-tag'
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw "Expected successful render exit code, got $exitCode. Output: $output" }

            $report = $output | ConvertFrom-Json -AsHashtable
            $renderStage = @($report.stages | Where-Object { $_.name -eq 'Render' }) | Select-Object -First 1
            if ($null -eq $renderStage) { throw 'Expected render stage diagnostics in report.' }
            if ([int]$renderStage.details.docxControlsDiscovered -le 0) { throw "Expected docxControlsDiscovered>0, got '$($renderStage.details.docxControlsDiscovered)'" }
            if ([int]$renderStage.details.docxTaggedControlsMatched -le 0) { throw "Expected docxTaggedControlsMatched>0, got '$($renderStage.details.docxTaggedControlsMatched)'" }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses literal-token DOCX replacement only when DocxMatchMode is explicitly literal-token' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-docx-literal-mode-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'unused' -TechId 'Test.Tech' -DatasetRelativePath 'datasets/transport.json' -Mappings @(
                @{
                    dataset = 'datasets/transport.json'
                    required = $true
                    selectors = @('items', '0', 'status')
                    target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus' }
                }
            ) -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'transport'
                item_count = 1
                items = @(
                    @{ status = 'Ready' }
                )
            }

            $contractsRoot = New-MinimalContractsRoot -Root $tempRoot -DatasetName 'transport'
            $templatePath = Join-Path $tempRoot 'literal-template.docx'
            New-TestTaggedContentControlDocxTemplate -Path $templatePath -ScalarTag 'LNV.Test.Tech.System[ArrayName].Summary.Name' -TableTag 'LNV.Test.Tech.System[ArrayName].Tables.Sample' -LegacyTokenTag 'LNV.Test.Tech.System[ArrayName].Summary.LegacyStatus'
            $outputPath = Join-Path $tempRoot 'literal-rendered.docx'
            $reportPath = Join-Path $tempRoot 'report.json'

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot -DocxMatchMode 'literal-token'
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw "Expected successful render exit code, got $exitCode. Output: $output" }
            $report = $output | ConvertFrom-Json -AsHashtable

            $zip = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
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

            if ($documentXml -notmatch '<w:t xml:space=\"preserve\">Ready</w:t>') { throw "Expected literal-token DOCX replacement when DocxMatchMode=literal-token, got '$documentXml'" }
            if ($documentXml -match '&lt;&lt;SDT:LNV\.Test\.Tech\.System\[ArrayName\]\.Summary\.LegacyStatus&gt;&gt;') { throw "Expected legacy token to be removed in literal-token mode, got '$documentXml'" }

            $renderStage = @($report.stages | Where-Object { $_.name -eq 'Render' }) | Select-Object -First 1
            if ($null -eq $renderStage) { throw 'Expected render stage diagnostics in report.' }
            if ([string]$renderStage.details.docxMatchMode -ne 'literal-token') { throw "Expected docxMatchMode=literal-token, got '$($renderStage.details.docxMatchMode)'" }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails closed when mappings resolve but DOCX content-control mode populates zero controls' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-docx-no-population-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'unused' -TechId 'Test.Tech' -DatasetRelativePath 'datasets/transport.json' -Mappings @(
                @{
                    dataset = 'datasets/transport.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                    target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.Name' }
                }
            ) -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'transport'
                item_count = 1
                items = @(
                    @{ name = 'Alpha Node' }
                )
            }

            $contractsRoot = New-MinimalContractsRoot -Root $tempRoot -DatasetName 'transport'
            $templatePath = Join-Path $tempRoot 'mismatch-template.docx'
            New-TestTaggedContentControlDocxTemplate -Path $templatePath -ScalarTag 'LNV.Test.Tech.System[ArrayName].Summary.Other' -TableTag 'LNV.Test.Tech.System[ArrayName].Tables.Other'

            $outputPath = Join-Path $tempRoot 'mismatch-rendered.docx'
            $reportPath = Join-Path $tempRoot 'report.json'
            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot -DocxMatchMode 'content-control-tag'
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) { throw "Expected non-zero exit code when no tagged controls are populated. Output: $output" }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ([string]$report.status -ne 'ERROR') { throw "Expected report.status ERROR, got '$($report.status)'" }

            $noPopulationIssue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DOCX-NO-POPULATION' }) | Select-Object -First 1
            if ($null -eq $noPopulationIssue) { throw 'Expected ASB-ASM-SDT-DOCX-NO-POPULATION issue when controlsPopulated is zero despite mapping matches.' }
            if ([string]$noPopulationIssue.severity -ne 'ERROR') { throw "Expected ASB-ASM-SDT-DOCX-NO-POPULATION severity ERROR, got '$($noPopulationIssue.severity)'" }
            if ([string]$noPopulationIssue.message -notmatch 'docxMatchMode=''content-control-tag''') { throw "Expected no-population issue to include docxMatchMode context, got '$($noPopulationIssue.message)'" }
            if ([string]$noPopulationIssue.message -notmatch 'controlsDiscovered=2') { throw "Expected no-population issue to include controlsDiscovered, got '$($noPopulationIssue.message)'" }
            if ([string]$noPopulationIssue.message -notmatch 'taggedControlsMatched=0') { throw "Expected no-population issue to include taggedControlsMatched, got '$($noPopulationIssue.message)'" }
            if ([string]$noPopulationIssue.message -notmatch 'controlsPopulated=0') { throw "Expected no-population issue to include controlsPopulated, got '$($noPopulationIssue.message)'" }
            if ([string]$noPopulationIssue.message -notmatch 'sampleMatchedTags=LNV\.Test\.Tech\.System\[ArrayName\]\.Summary\.Name') { throw "Expected no-population issue to include sample matched tag, got '$($noPopulationIssue.message)'" }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'surfaces DOCX content-control parse failures as renderer issues instead of silently ignoring them' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-docx-part-error-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'unused' -TechId 'Test.Tech' -DatasetRelativePath 'datasets/transport.json' -Mappings @(
                @{
                    dataset = 'datasets/transport.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                    target = @{ sdtTag = 'LNV.Test.Tech.System[ArrayName].Summary.Name' }
                }
            ) -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'transport'
                item_count = 1
                items = @(
                    @{ name = 'Alpha Node' }
                )
            }

            $contractsRoot = New-MinimalContractsRoot -Root $tempRoot -DatasetName 'transport'
            $templatePath = Join-Path $tempRoot 'malformed-template.docx'
            New-TestTaggedContentControlDocxTemplate -Path $templatePath -ScalarTag 'LNV.Test.Tech.System[ArrayName].Summary.Name' -TableTag 'LNV.Test.Tech.System[ArrayName].Tables.Sample'
            Set-TestDocxEntryText -Path $templatePath -EntryName 'word/document.xml' -Text '<w:document><w:body><w:sdt></w:body>'

            $outputPath = Join-Path $tempRoot 'malformed-rendered.docx'
            $reportPath = Join-Path $tempRoot 'report.json'
            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $templatePath -OutputPath $outputPath -ReportPath $reportPath -ContractsRoot $contractsRoot -DocxMatchMode 'content-control-tag'
            $report = $output | ConvertFrom-Json -AsHashtable

            if ($report.status -ne 'ERROR') { throw "Expected report.status ERROR, got '$($report.status)'" }

            $partIssue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DOCX-PART-REWRITE' }) | Select-Object -First 1
            if ($null -eq $partIssue) { throw 'Expected ASB-ASM-SDT-DOCX-PART-REWRITE issue for malformed DOCX part.' }
            if ([string]$partIssue.severity -ne 'ERROR') { throw "Expected part rewrite issue severity ERROR, got '$($partIssue.severity)'" }
            if ([string]$partIssue.message -notmatch "word/document.xml") { throw "Expected part rewrite issue to include part name, got '$($partIssue.message)'" }
            if ([string]$partIssue.message -notmatch "content-control-tag") { throw "Expected part rewrite issue to include match mode, got '$($partIssue.message)'" }

            $renderStage = @($report.stages | Where-Object { $_.name -eq 'Render' }) | Select-Object -First 1
            if ($null -eq $renderStage) { throw 'Expected Render stage diagnostics.' }
            $partErrors = @($renderStage.details.docxPartErrors)
            if ($partErrors.Count -lt 1) { throw 'Expected render stage docxPartErrors diagnostics to include malformed part details.' }
            $firstPartError = $partErrors[0]
            if ([string]$firstPartError.partName -ne 'word/document.xml') { throw "Expected docxPartErrors[0].partName to be word/document.xml, got '$($firstPartError.partName)'" }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'assigns valid timestamps to skipped stages when execution stops during validation' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-skipped-stage-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @()

            Set-Content -LiteralPath $fixture.mappingPath -Encoding UTF8 -Value (@{
                schema = 'mapping.dataset-to-sdt'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'invalid mapping'
                strictContracts = @{ enabled = $true; requireAllMappings = $true }
            } | ConvertTo-Json -Depth 10)

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to invalid mapping schema' }

            $report = $output | ConvertFrom-Json -AsHashtable
            foreach ($stage in @($report.stages | Where-Object { $_.status -eq 'SKIPPED' })) {
                if ([string]::IsNullOrWhiteSpace([string]$stage.startedUtc)) {
                    throw "Expected skipped stage '$($stage.name)' to include startedUtc"
                }
                if ([string]::IsNullOrWhiteSpace([string]$stage.completedUtc)) {
                    throw "Expected skipped stage '$($stage.name)' to include completedUtc"
                }
            }

            if ((@($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-RENDERREPORT-INVALID' }).Count) -ne 0) {
                throw 'Expected skipped-stage timestamps to keep render report schema-valid'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'normalizes projection contracts with nested strings without raising Count exceptions' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-projection-normalization-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $projectionContractPath = Join-Path $tempRoot 'assembler.projections.v1.json'
            Set-Content -LiteralPath $projectionContractPath -Encoding UTF8 -Value (@{
                schema = 'assembler.projections'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'nested string projection contract'
                projections = @{
                    TEST_TAG = @{
                        filter = @(
                            @{
                                field = 'items.0.name'
                                equals = 'ArrayOne'
                            }
                        )
                        columns = @(
                            @{
                                name = 'summary'
                                value = @{
                                    text = 'alpha'
                                    nested = @{
                                        label = 'beta'
                                    }
                                }
                            }
                        )
                    }
                }
            } | ConvertTo-Json -Depth 10)

            try {
                $result = Read-ProjectionContractFile -Path $projectionContractPath
            }
            catch {
                if ($_.Exception.Message -match 'Count') {
                    throw "Unexpected Count exception while normalizing nested strings: $($_.Exception.Message)"
                }

                throw
            }

            if ([string]$result.projections.TEST_TAG.columns[0].value.text -ne 'alpha') {
                throw 'Expected nested string leaf value to be preserved during normalization.'
            }

            if ([string]$result.projections.TEST_TAG.columns[0].value.nested.label -ne 'beta') {
                throw 'Expected nested string leaf value to remain accessible after normalization.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'preserves one-item projection filter arrays through normalization and JSON reserialization' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-projection-array-shape-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $projectionContractPath = Join-Path $tempRoot 'assembler.projections.v1.json'
            Set-Content -LiteralPath $projectionContractPath -Encoding UTF8 -Value (@{
                schema = 'assembler.projections'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'single-item filter projection contract'
                projections = @{
                    'LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI' = @{
                        filter = @(
                            @{
                                field = 'transport'
                                equals = 'iscsi'
                            }
                        )
                        columns = @(
                            @{
                                name = 'Port'
                                value = 'name'
                            }
                        )
                    }
                }
            } | ConvertTo-Json -Depth 10)

            $result = Read-ProjectionContractFile -Path $projectionContractPath
            if (-not ($result.projections['LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI'].filter -is [System.Collections.IList])) {
                throw 'Expected single-item filter to remain an array after loading projection contract.'
            }

            if (@($result.projections['LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI'].filter).Count -ne 1) {
                throw 'Expected exactly one filter entry after loading projection contract.'
            }

            $projectionContractJson = $result | ConvertTo-Json -Depth 10
            $jsonShape = Test-ProjectionContractJsonArrayShape -JsonText $projectionContractJson
            if (-not $jsonShape.isValid) {
                throw "Expected projection contract JSON to preserve array shape, but got: $($jsonShape.message)"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'accepts mapping migration tag shapes (sdtTag-only, dual, and target-only) during schema compatibility validation' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $mappingSchemaPath = Join-Path $repoRoot '.deps/contracts/standards/mapping.dataset-to-sdt.schema.v1.json'

        $baseMapping = @{
            schema = 'mapping.dataset-to-sdt'
            schemaVersion = 1
            techId = 'Test.Tech'
            displayName = 'shape compatibility test'
            compatibility = @{ contracts = @{ version = 'v1' } }
            strictContracts = @{ enabled = $true; requireAllMappings = $true }
            mappings = @(
                @{
                    dataset = 'datasets/systems.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                }
            )
        }

        $variants = @(
            @{ name = 'sdtTag-only'; entry = @{ sdtTag = 'TAG.ONE' }; expectedMode = 'as-is' },
            @{ name = 'dual'; entry = @{ sdtTag = 'TAG.ONE'; target = @{ sdtTag = 'TAG.ONE' } }; expectedMode = 'as-is' },
            @{ name = 'target-only'; entry = @{ target = @{ sdtTag = 'TAG.ONE' } }; expectedMode = 'as-is' }
        )

        foreach ($variant in $variants) {
            $candidate = Copy-AsHashtable -Value $baseMapping
            foreach ($key in $variant.entry.Keys) {
                $candidate.mappings[0][$key] = $variant.entry[$key]
            }

            $result = Resolve-MappingSchemaCompatibleDocument -MappingDocument $candidate -SchemaPath $mappingSchemaPath -DocumentLabel "variant-$($variant.name)"
            if (-not [bool]$result.isValid) {
                throw "Expected '$($variant.name)' mapping shape to be accepted, but got: $($result.message)"
            }
            if ([string]$result.mode -ne [string]$variant.expectedMode) {
                throw "Expected '$($variant.name)' compatibility mode '$($variant.expectedMode)', got '$($result.mode)'"
            }
        }
    }

    It 'reports schema validation diagnostics with clear path and tag-shape mismatch message' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-mapping-shape-diagnostics-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    required = $true
                    selectors = @('items', '0', 'name')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) { throw 'Expected non-zero exit code for mapping with missing tag shape' }

            $report = $output | ConvertFrom-Json -AsHashtable
            $issue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-MAPPING-INVALID' }) | Select-Object -First 1
            if ($null -eq $issue) {
                throw 'Expected ASB-ASM-SCHEMA-MAPPING-INVALID issue for missing sdtTag/target.sdtTag'
            }
            if ([string]$issue.path -ne [string]$fixture.mappingPath) {
                throw "Expected mapping validation issue path '$($fixture.mappingPath)', got '$($issue.path)'"
            }
            if ([string]$issue.message -notmatch 'sdtTag') {
                throw "Expected mapping validation message to mention sdtTag shape requirements, got '$($issue.message)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails validation when the projection contract is schema-invalid' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-invalid-projection-contract-test-" + [guid]::NewGuid().ToString())
        $tempContractsRoot = Join-Path $tempRoot 'contracts'
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            Copy-Item -LiteralPath $contractsRoot -Destination $tempContractsRoot -Recurse -Force
            $projectionContractPath = Join-Path $tempContractsRoot 'tech/Lenovo.DE/assembler.projections.v1.json'
            Set-Content -LiteralPath $projectionContractPath -Encoding UTF8 -Value (@{
                schema = 'assembler.projections'
                schemaVersion = 1
                techId = 'Lenovo.DE'
                displayName = 'invalid projection contract'
                projections = @(
                    @{
                        sdtTag = 'BROKEN'
                        columns = @(
                            @{ name = 'OnlyName' }
                        )
                    }
                )
            } | ConvertTo-Json -Depth 10)

            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName'
                    required = $true
                    selectors = @('items', '0', 'name')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $tempContractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to invalid projection schema' }

            $report = $output | ConvertFrom-Json -AsHashtable
            $issue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SCHEMA-PROJECTIONS-INVALID' }) | Select-Object -First 1
            if ($null -eq $issue) {
                throw 'Expected projection schema validation issue in report'
            }
            if ([string]$issue.path -ne $projectionContractPath) {
                throw "Expected projection schema issue path '$projectionContractPath', got '$($issue.path)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'applies selector chains sequentially and records the full selector chain in matches' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Summary.SystemName>>' -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName'
                    required = $true
                    selectors = @('items', '0', 'name')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'System=ArrayOne') { throw "Expected selector chain to resolve value, got '$rendered'" }

            $report = $output | ConvertFrom-Json -AsHashtable
            $match = @($report.matches | Where-Object { $_.tag -eq 'LNV.Lenovo.DE.System[ArrayName].Summary.SystemName' }) | Select-Object -First 1
            if ($null -eq $match) { throw 'Expected LNV.Lenovo.DE.System[ArrayName].Summary.SystemName match entry in report' }
            if ($match.selector -ne 'items -> 0 -> name') {
                throw "Expected full selector chain in report match selector, got '$($match.selector)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits selector no-match ERROR for required mappings and warning for optional mappings' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Req=<<SDT:REQ_NAME>>;Opt=<<SDT:OPT_NAME>>" -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'REQ_NAME'
                    required = $true
                    selectors = @('items', '0', 'missing')
                },
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'OPT_NAME'
                    required = $false
                    selectors = @('items', '0', 'alsoMissing')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to required selector failure' }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ERROR') { throw "Expected report.status ERROR, got '$($report.status)'" }

            $selectorIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-SELECTOR-NOMATCH' })
            $requiredIssue = @($selectorIssues | Where-Object { $_.severity -eq 'ERROR' -and $_.message -match "tag 'REQ_NAME'" }) | Select-Object -First 1
            if ($null -eq $requiredIssue) { throw 'Expected required selector failure to emit ERROR issue' }

            $optionalIssue = @($selectorIssues | Where-Object { $_.severity -eq 'WARN' -and $_.message -match "tag 'OPT_NAME'" }) | Select-Object -First 1
            if ($null -eq $optionalIssue) { throw 'Expected optional selector failure to emit WARN issue' }

            if ((@($report.matches | Where-Object { $_.tag -eq 'OPT_NAME' }).Count) -ne 0) {
                throw 'Expected optional failed selector mapping to be skipped from matches'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'treats empty array selector values as successful resolutions for Lenovo.DE datasets' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-empty-array-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template @'
NTP0=<<SDT:NTP0>>
DHCP0=<<SDT:DHCP0>>
DNS0=<<SDT:DNS0>>
NTP1=<<SDT:NTP1>>
DHCP1=<<SDT:DHCP1>>
DNS1=<<SDT:DNS1>>
'@ -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 2
                items = @(
                    @{
                        ntpServers = @()
                        dhcpAcquiredServers = @()
                        dnsServers = @()
                    },
                    @{
                        ntpServers = @()
                        dhcpAcquiredServers = @()
                        dnsServers = @()
                    }
                )
            } -Mappings @(
                @{ dataset = 'datasets/systems.json'; sdtTag = 'NTP0'; required = $true; selectors = @('items', '0', 'ntpServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DHCP0'; required = $true; selectors = @('items', '0', 'dhcpAcquiredServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DNS0'; required = $true; selectors = @('items', '0', 'dnsServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'NTP1'; required = $true; selectors = @('items', '1', 'ntpServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DHCP1'; required = $true; selectors = @('items', '1', 'dhcpAcquiredServers') },
                @{ dataset = 'datasets/systems.json'; sdtTag = 'DNS1'; required = $true; selectors = @('items', '1', 'dnsServers') }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') { throw "Expected report.status OK, got '$($report.status)'" }

            $selectorIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-SELECTOR-NOMATCH' })
            if ($selectorIssues.Count -ne 0) {
                throw "Expected no selector no-match issues for empty arrays, got $($selectorIssues.Count)"
            }

            foreach ($tag in @('NTP0', 'DHCP0', 'DNS0', 'NTP1', 'DHCP1', 'DNS1')) {
                $match = @($report.matches | Where-Object { $_.tag -eq $tag }) | Select-Object -First 1
                if ($null -eq $match) { throw "Expected match entry for tag '$tag'" }
            }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            foreach ($expectedLine in @('NTP0=[]', 'DHCP0=[]', 'DNS0=[]', 'NTP1=[]', 'DHCP1=[]', 'DNS1=[]')) {
                if ($rendered -notmatch [regex]::Escape($expectedLine)) {
                    throw "Expected rendered output to contain '$expectedLine', got '$rendered'"
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits envelope ERROR for required mappings and warning for optional mappings' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Req=<<SDT:REQ_NAME>>;Opt=<<SDT:OPT_NAME>>" -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 2
                items = @(
                    @{ name = 'ArrayOne'; status = 'online' }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'REQ_NAME'
                    required = $true
                    selectors = @('items', '0', 'name')
                },
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'OPT_NAME'
                    required = $false
                    selectors = @('items', '0', 'name')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code due to required envelope validation failure' }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ERROR') { throw "Expected report.status ERROR, got '$($report.status)'" }

            $envelopeIssues = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DATASET-ENVELOPE' })
            $requiredIssue = @($envelopeIssues | Where-Object { $_.severity -eq 'ERROR' -and $_.message -match "tag 'REQ_NAME'" }) | Select-Object -First 1
            if ($null -eq $requiredIssue) { throw 'Expected required mapping envelope failure to emit ERROR issue' }

            $optionalIssue = @($envelopeIssues | Where-Object { $_.severity -eq 'WARN' -and $_.message -match "tag 'OPT_NAME'" }) | Select-Object -First 1
            if ($null -eq $optionalIssue) { throw 'Expected optional mapping envelope failure to emit WARN issue' }

            if ((@($report.matches | Where-Object { $_.tag -eq 'OPT_NAME' }).Count) -ne 0) {
                throw 'Expected optional envelope-invalid mapping to be skipped from matches'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails with unresolved-tag ERROR when required SDT placeholders remain in rendered output' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-unresolved-required-tag-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template @'
First=<<SDT:REQ_NAME>>
Second=<<SDT:REQ_NAME>>
'@ -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'REQ_NAME'
                    required = $true
                    selectors = @('items', '0', 'missingField')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) { throw 'Expected non-zero exit code when required unresolved tags remain' }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ERROR') { throw "Expected report.status ERROR, got '$($report.status)'" }

            $issue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-UNRESOLVED-TAG' -and $_.message -match "tag 'REQ_NAME'" }) | Select-Object -First 1
            if ($null -eq $issue) { throw 'Expected unresolved-tag issue for required REQ_NAME token' }
            if ($issue.severity -ne 'ERROR') { throw "Expected unresolved required tag severity ERROR, got '$($issue.severity)'" }
            if ($issue.message -notmatch '2 occurrence\(s\)') { throw "Expected unresolved issue to include occurrence count, got '$($issue.message)'" }
            if ($issue.message -notmatch 'L1:C7') { throw "Expected unresolved issue to include sample location, got '$($issue.message)'" }

            $renderStage = @($report.stages | Where-Object { $_.name -eq 'Render' }) | Select-Object -First 1
            if ($null -eq $renderStage) { throw 'Expected render stage entry in report' }
            if ($null -eq $renderStage.details -or $null -eq $renderStage.details.unresolved) {
                throw 'Expected unresolved summary under Render stage details'
            }
            if ([int]$renderStage.details.unresolved.unresolvedTagCount -ne 1) {
                throw "Expected unresolvedTagCount 1, got '$($renderStage.details.unresolved.unresolvedTagCount)'"
            }
            if ([int]$renderStage.details.unresolved.unresolvedOccurrences -ne 2) {
                throw "Expected unresolvedOccurrences 2, got '$($renderStage.details.unresolved.unresolvedOccurrences)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'marks report PARTIAL when only optional unresolved SDT placeholders remain' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-unresolved-optional-tag-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template @'
Req=<<SDT:REQ_NAME>>
Opt=<<SDT:OPT_NAME>>
'@ -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'REQ_NAME'
                    required = $true
                    selectors = @('items', '0', 'name')
                },
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'OPT_NAME'
                    required = $false
                    selectors = @('items', '0', 'missingField')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected zero exit code for optional unresolved placeholder case, got $exitCode" }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'PARTIAL') { throw "Expected report.status PARTIAL, got '$($report.status)'" }

            $unresolvedIssue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-UNRESOLVED-TAG' -and $_.message -match "tag 'OPT_NAME'" }) | Select-Object -First 1
            if ($null -eq $unresolvedIssue) { throw 'Expected unresolved-tag issue for optional OPT_NAME token' }
            if ($unresolvedIssue.severity -ne 'WARN') { throw "Expected unresolved optional tag severity WARN, got '$($unresolvedIssue.severity)'" }

            if ($report.status -eq 'OK') {
                throw 'Expected unresolved placeholders to prevent report.status OK'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'consumes legacy Lenovo.DE run_summary payloads without failing envelope validation' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-legacy-summary-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Collected=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectedUTC>>;Mode=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionMode>>" -DatasetRelativePath 'datasets/run_summary.json' -Dataset @{
                collectedUtc = '2026-03-21T15:38:55.2459138+11:00'
                mode = 'Cli'
                controller = '10.240.59.179'
                port = 8443
                systemCount = 1
            } -Mappings @(
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectedUTC'
                    required = $true
                    selectors = @('collectedUtc')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionMode'
                    required = $true
                    selectors = @('mode')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Collected=2026-03-21T15:38:55.2459138\+11:00;Mode=Cli') {
                throw "Expected legacy summary values to render successfully, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $compatIssue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DATASET-COMPAT' }) | Select-Object -First 1
            if ($null -eq $compatIssue) {
                throw 'Expected legacy summary compatibility warning in report'
            }
            if ($compatIssue.severity -ne 'WARN') {
                throw "Expected compatibility warning severity WARN, got '$($compatIssue.severity)'"
            }

            if ((@($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-DATASET-ENVELOPE' }).Count) -ne 0) {
                throw 'Expected legacy summary compatibility to suppress envelope validation errors'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'extracts Lenovo.DE summary values from enveloped run_summary output using existing selectors' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-envelope-summary-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Controller=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController>>;Port=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionPort>>;SystemCount=<<SDT:LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.SystemCountReturned>>" -DatasetRelativePath 'datasets/run_summary.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'LNV.AsBuiltDoc.Lenovo.DE'; version = '1.0.0' }
                source = @{ kind = 'Lenovo.DE'; endpoint = 'local'; file = 'run_summary.json' }
                dataset = @{ key = 'run_summary'; schema_path = 'tech/Lenovo.DE/dataset/run_summary.schema.json' }
                item_count = 1
                items = @(
                    @{
                        collectedUtc = '2026-03-21T15:38:55.2459138+11:00'
                        mode = 'Cli'
                        controller = '10.240.59.179'
                        port = 8443
                        systemCount = 1
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController'
                    required = $true
                    selectors = @('controller')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionPort'
                    required = $true
                    selectors = @('port')
                },
                @{
                    dataset = 'datasets/run_summary.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.SystemCountReturned'
                    required = $true
                    selectors = @('systemCount')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            foreach ($expectedValue in @(
                'Controller=10.240.59.179',
                'Port=8443',
                'SystemCount=1'
            )) {
                if ($rendered -notmatch [regex]::Escape($expectedValue)) {
                    throw "Expected rendered output to contain '$expectedValue', got '$rendered'"
                }
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $controllerMatch = @($report.matches | Where-Object { $_.tag -eq 'LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController' }) | Select-Object -First 1
            if ($null -eq $controllerMatch) {
                throw 'Expected LNV.Lenovo.DE.System[ArrayName].Evidence.Collection.CollectionController match entry in report'
            }
            if ($controllerMatch.selector -ne 'controller') {
                throw "Expected existing selector 'controller' to remain in report, got '$($controllerMatch.selector)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'renders FC host-port placeholder row when projection filters out all rows' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-empty-fc-hostports-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "FC=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC>>" -DatasetRelativePath 'datasets/host-ports.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'host-ports'
                item_count = 1
                items = @(
                    @{
                        controllerLabel = 'A'
                        controllerSlot = '1'
                        portLabel = '1'
                        channel = '1'
                        linkStatus = 'up'
                        transport = 'iscsi'
                        ipv4Address = '192.0.2.10'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/host-ports.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if (-not $rendered.StartsWith('FC=')) {
                throw "Expected FC output prefix to remain intact, got '$rendered'"
            }
            if ($rendered -notmatch 'Not configured') {
                throw "Expected FC table placeholder row with 'Not configured' after projection filter removes all rows, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders Lenovo.DE capabilities projection when filtering leaves a single row' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-single-capability-row-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Caps=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary>>" -DatasetRelativePath 'datasets/capabilities-normalized.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'capabilities-normalized'
                item_count = 2
                items = @(
                    @{
                        displayName = 'Snapshot Copies'
                        category = 'Data Protection'
                        state = 'Enabled'
                        compliance = 'Compliant'
                        entitlement = 'Included'
                        includeInMainBody = $true
                        includeInAppendix = $true
                        sortOrder = 10
                    },
                    @{
                        displayName = 'Hidden Feature'
                        category = 'Testing'
                        state = 'Disabled'
                        compliance = 'Unknown'
                        entitlement = 'None'
                        includeInMainBody = $false
                        includeInAppendix = $false
                        sortOrder = 20
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/capabilities-normalized.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Feature\s+Category\s+State\s+Compliance\s+Entitlement') {
                throw "Expected capabilities projection table header, got '$rendered'"
            }
            if ($rendered -notmatch 'Snapshot Copies\s+Data Protection\s+Enabled\s+Compliant\s+Included') {
                throw "Expected filtered projected capability row, got '$rendered'"
            }
            if ($rendered -match 'Hidden Feature') {
                throw "Expected projection filter to remove hidden capability row, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders an empty string when capabilities projection filters out all rows' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-empty-capabilities-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Caps=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary>>" -DatasetRelativePath 'datasets/capabilities-normalized.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'capabilities-normalized'
                item_count = 1
                items = @(
                    @{
                        displayName = 'Hidden Feature'
                        category = 'Testing'
                        state = 'Disabled'
                        compliance = 'Unknown'
                        entitlement = 'None'
                        includeInMainBody = $false
                        includeInAppendix = $false
                        sortOrder = 10
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/capabilities-normalized.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -ne 'Caps=') {
                throw "Expected empty capabilities table rendering after projection filter removes all rows, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'OK') {
                throw "Expected report.status OK, got '$($report.status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'uses Lenovo.DE system inventory projection so system table tags render reader-facing tabular columns' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-system-inventory-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "System=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Inventory>>" -DatasetRelativePath 'datasets/systems.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{
                        name = 'DE4800-A'
                        model = 'DE4800F'
                        status = 'optimal'
                        fwVersion = '11.20'
                        appVersion = '11.20'
                        ip2 = '192.0.2.10'
                        controllers = 2
                        trayCount = 4
                        driveCount = 96
                        hiddenRef = 'internal-only'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Inventory'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'SystemName\s+Model\s+Status\s+FirmwareVersion\s+ApplicationVersion\s+ManagementIP\s+ControllerCount\s+TrayCount\s+DriveCount') {
                throw "Expected projected system inventory table header, got '$rendered'"
            }
            if ($rendered -match 'hiddenRef|\{"name":') {
                throw "Expected reader-facing system projection output instead of raw JSON, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders Lenovo.DE system inventory projection with display columns and selected values from systems fixture' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-system-inventory-focused-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Inventory=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Inventory>>" -DatasetRelativePath 'datasets/systems.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{
                        name = 'Array-Prime'
                        model = 'DE6000F'
                        status = 'optimal'
                        fwVersion = '11.90'
                        appVersion = '11.90.1'
                        ip2 = '198.51.100.24'
                        controllers = 2
                        trayCount = 3
                        driveCount = 48
                        hiddenRef = 'internal-only'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Inventory'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'SystemName\s+Model\s+Status\s+FirmwareVersion\s+ApplicationVersion\s+ManagementIP\s+ControllerCount\s+TrayCount\s+DriveCount') {
                throw "Expected readable projected system inventory header, got '$rendered'"
            }
            if ($rendered -notmatch 'Array-Prime\s+DE6000F\s+optimal\s+11\.90\s+11\.90\.1\s+198\.51\.100\.24\s+2\s+3\s+48') {
                throw "Expected projected system inventory values, got '$rendered'"
            }
            if ($rendered -match 'hiddenRef|fwVersion|appVersion|\{"name":|^\s*Inventory=\s*\{' ) {
                throw "Expected projected system inventory output instead of raw JSON keys/braces, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses Lenovo.DE tray projection so tray table tags render reader-facing tabular columns' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-tray-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Trays=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>" -DatasetRelativePath 'datasets/trays.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'trays'
                item_count = 1
                items = @(
                    @{
                        trayId = 99
                        trayType = 'de224c'
                        trayRole = 'controller-tray'
                        serialNumber = 'SN-TRAY-99'
                        partNumber = 'PN-12345'
                        numDriveSlots = 24
                        numControllerSlots = 2
                        status = 'optimal'
                        manufacturer = 'Lenovo'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/trays.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Trays'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'TrayId\s+TrayType\s+TrayRole\s+SerialNumber\s+PartNumber\s+DriveSlots\s+ControllerSlots\s+Status') {
                throw "Expected projected tray table header, got '$rendered'"
            }
            if ($rendered -match 'manufacturer|\{"trayId":') {
                throw "Expected reader-facing tray projection output instead of raw JSON, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'renders Lenovo.DE tray projection with display columns and excludes internal tray fields' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-tray-focused-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Trays=<<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>" -DatasetRelativePath 'datasets/trays.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'trays'
                item_count = 1
                items = @(
                    @{
                        trayId = 7
                        trayType = 'DE212C'
                        trayRole = 'expansion-tray'
                        serialNumber = 'TRAY-0007'
                        partNumber = '01KP999'
                        numDriveSlots = 12
                        numControllerSlots = 0
                        status = 'optimal'
                        manufacturer = 'Lenovo'
                        esmFirmware = '8.20'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/trays.json'
                    sdtTag = 'LNV.Lenovo.DE.System[ArrayName].Tables.Trays'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'TrayId\s+TrayType\s+TrayRole\s+SerialNumber\s+PartNumber\s+DriveSlots\s+ControllerSlots\s+Status') {
                throw "Expected readable projected tray header, got '$rendered'"
            }
            if ($rendered -notmatch '7\s+DE212C\s+expansion-tray\s+TRAY-0007\s+01KP999\s+12\s+0\s+optimal') {
                throw "Expected projected tray values, got '$rendered'"
            }
            if ($rendered -match 'manufacturer|esmFirmware|numDriveSlots|numControllerSlots|\{"trayId":|^\s*Trays=\s*\{' ) {
                throw "Expected projected tray output instead of raw/internal fields, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses Lenovo.DE projection aliases so reader-facing drive inventory tags render projected tabular columns' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-drive-projection-alias-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template "Drive=<<SDT:LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory>>" -DatasetRelativePath 'datasets/drives.json' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'drives'
                item_count = 1
                items = @(
                    @{
                        slot = 1
                        driveMediaType = 'ssd'
                        rawCapacityBytes = 2000398934016
                        usableCapacityBytes = 1800398934016
                        firmwareVersion = 'LE00'
                        status = 'optimal'
                        serialNumber = 'SN123'
                        hiddenRef = 'internal-only'
                    }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/drives.json'
                    sdtTag = 'LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory'
                    required = $true
                    selectors = @('items')
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) { throw "Expected exit code 0, got $exitCode" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Slot\s+Media Type\s+Raw\s+Usable\s+Firmware\s+Status\s+SerialNumber') {
                throw "Expected projected drive inventory table header, got '$rendered'"
            }
            if ($rendered -match 'rawCapacityBytes|usableCapacityBytes|hiddenRef') {
                throw "Expected reader-facing drive projection to hide raw/internal columns, got '$rendered'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails drift check when Lenovo.DE runtime mapping diverges from generated mapping tag shape' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $syncScriptPath = Join-Path $repoRoot 'scripts/Sync-AssemblerContractsToRepo.ps1'
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $collectorMappingPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-lenovo-generated-mapping-test-" + [guid]::NewGuid().ToString())
        $generatedMappingPath = Join-Path $tempRoot 'DE-SDT-Collector.mapping.generated.json'
        $tempContractsRoot = Join-Path $tempRoot 'contracts-copy'

        try {
            Copy-Item -LiteralPath $contractsRoot -Destination $tempContractsRoot -Recurse -Force
            $json = & $pwshPath -NoLogo -NoProfile -File $syncScriptPath -ExportContractsPath $tempContractsRoot -DepsContractsPath (Join-Path $tempRoot '.deps/contracts') -SkeletonMappingOutputPath $generatedMappingPath -Clean
            if ($LASTEXITCODE -ne 0) {
                throw "Expected sync script to successfully generate mapping, got exit code $LASTEXITCODE"
            }

            if (-not (Test-Path -LiteralPath $generatedMappingPath -PathType Leaf)) {
                throw "Expected generated mapping at '$generatedMappingPath'"
            }

            $checkedInMapping = Get-Content -LiteralPath $collectorMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $controllersEntry = @($checkedInMapping.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.Controllers' }) | Select-Object -First 1
            if ($null -ne $controllersEntry) {
                $controllersEntry.Remove('target')
            }

            $checkedInJson = $checkedInMapping | ConvertTo-Json -Depth 30
            $generatedJson = Get-Content -LiteralPath $generatedMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 30

            if ($checkedInJson -eq $generatedJson) {
                throw 'Expected drift check fixture to diverge after shape mutation, but generated and runtime mappings were unexpectedly identical'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits a render issue and placeholder when table render mode has no projection definition' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-table-missing-projection-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'Table=<<SDT:MISSING_TABLE>>' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{ name = 'row1'; status = 'online' }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'MISSING_TABLE'
                    required = $true
                    renderHint = @{ renderMode = 'table'; missingProjectionPolicy = 'placeholder' }
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            if ($LASTEXITCODE -ne 0) { throw "Expected exit code 0, got $LASTEXITCODE" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch [regex]::Escape('Table=[table data omitted: projection required]')) {
                throw "Expected placeholder output for missing table projection, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $issue = @($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-TABLE-PROJECTION-MISSING' }) | Select-Object -First 1
            if ($null -eq $issue) {
                throw 'Expected missing table projection issue in report'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'allows raw JSON only for explicitly declared json evidence render mode' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-json-evidence-render-mode-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'Evidence=<<SDT:RAW_EVIDENCE>>' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'systems'
                item_count = 1
                items = @(
                    @{ name = 'ArrayOne'; nested = @{ state = 'ok' } }
                )
            } -Mappings @(
                @{
                    dataset = 'datasets/systems.json'
                    sdtTag = 'RAW_EVIDENCE'
                    required = $true
                    selectors = @('items', '0')
                    renderHint = @{ renderMode = 'json-evidence' }
                }
            )

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            if ($LASTEXITCODE -ne 0) { throw "Expected exit code 0, got $LASTEXITCODE" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Evidence=\{"name":"ArrayOne","nested":\{"state":"ok"\}\}') {
                throw "Expected explicit json evidence render mode to preserve JSON, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            if ((@($report.issues | Where-Object { $_.code -eq 'ASB-ASM-SDT-STRUCTURED-VALUE-RENDERMODE-REQUIRED' }).Count) -ne 0) {
                throw 'Expected no structured-value render mode warning for explicit json evidence rendering'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses dataset presentation metadata to default selectors and preferred projections' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts in this test'
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-dataset-presentation-metadata-test-" + [guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        try {
            $contractsRoot = New-MinimalContractsRoot -Root $tempRoot -DatasetName 'host-ports'

            $fixture = New-TestRenderFixture -Root $tempRoot -Template 'Ports=<<SDT:LNV.Test.Tech.System[ArrayName].Tables.Sample>>' -Dataset @{
                schema_version = 'lnv.collector.dataset.v1'
                collector = @{ module = 'test.module'; version = '1.0.0' }
                source = @{ kind = 'integration-test'; endpoint = 'local' }
                dataset = 'host-ports'
                item_count = 1
                items = @(
                    @{
                        systemId = 'sys-01'
                        transport = 'iscsi'
                        controllerRef = 'A'
                        controllerLabel = 'A'
                        controllerSlot = 1
                        portLabel = 'P1'
                        interfaceRef = 'if-01'
                        linkStatus = 'up'
                        channel = 1
                        ipv4Address = '10.0.0.10'
                        ipv4SubnetMask = '255.255.255.0'
                        ipv4Gateway = '10.0.0.1'
                        tcpPort = 3260
                        iqn = 'iqn.1993-08.org.debian:01:test'
                    }
                )
            } -DatasetRelativePath 'datasets/host-ports.json' -Mappings @(
                @{
                    dataset = 'datasets/host-ports.json'
                    sdtTag = 'LNV.Test.Tech.System[ArrayName].Tables.Sample'
                    required = $true
                }
            ) -TechId 'Test.Tech'

            $invokeScript = Join-Path $repoRoot 'scripts/Invoke-AssemblerSdtRender.ps1'
            $output = & $pwshPath -NoLogo -NoProfile -File $invokeScript -BundleRoot $fixture.bundleRoot -MappingPath $fixture.mappingPath -TemplatePath $fixture.templatePath -OutputPath $fixture.outputPath -ReportPath $fixture.reportPath -ContractsRoot $contractsRoot
            if ($LASTEXITCODE -ne 0) { throw "Expected exit code 0, got $LASTEXITCODE" }

            $rendered = Get-Content -LiteralPath $fixture.outputPath -Raw -Encoding UTF8
            if ($rendered -notmatch 'Controller' -or $rendered -notmatch '10\.0\.0\.10' -or $rendered -notmatch 'iqn\.1993-08\.org\.debian:01:test') {
                throw "Expected dataset presentation metadata to drive items-selector table rendering, got '$rendered'"
            }

            $report = $output | ConvertFrom-Json -AsHashtable
            $match = @($report.matches | Where-Object { $_.tag -eq 'LNV.Test.Tech.System[ArrayName].Tables.Sample' }) | Select-Object -First 1
            if ($null -eq $match) {
                throw 'Expected match entry for metadata-driven host port rendering'
            }
            if ([string]$match.selector -ne 'items') {
                throw "Expected selector chain 'items' from dataset presentation metadata, got '$($match.selector)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

}
