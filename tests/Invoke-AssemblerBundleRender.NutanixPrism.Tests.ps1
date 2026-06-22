Describe 'Invoke-AssemblerBundleRender Nutanix Prism contract mapping' {
    It 'renders mapped Prism datasets and leaves evidence-only datasets unmapped' -Skip:(-not (Test-Path -LiteralPath 'C:\Github\LNV.AsBuiltDoc.Core\out\740aaaa8-b726-4a2c-8035-b9a1746d172a.lnvbundle.zip' -PathType Leaf)) {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $bundleArchivePath = 'C:\Github\LNV.AsBuiltDoc.Core\out\740aaaa8-b726-4a2c-8035-b9a1746d172a.lnvbundle.zip'
        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $prismMappingPath = Join-Path $repoRoot 'templates/skeletons/Nutanix.Prism/Prism-SDT-Collector.mapping.json'
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-prism-render-" + [guid]::NewGuid().ToString('N'))
        $bundleRoot = Join-Path $tempRoot 'bundle'
        $outputRoot = Join-Path $tempRoot 'out'

        try {
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            Expand-Archive -LiteralPath $bundleArchivePath -DestinationPath $bundleRoot -Force

            $mapping = Get-Content -LiteralPath $prismMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            @($mapping.mappings).Count | Should -Be 18
            $documentMappings = @($mapping.mappings | Where-Object { [string]$_.scope -ne 'targetGroup' })
            $documentMappings.Count | Should -Be 17

            $catalogPath = Join-Path $tempRoot 'Prism-SDT-Collector.catalog.json'
            $runtimeMappingPath = Join-Path $tempRoot 'Prism-SDT-Collector.mapping.json'
            $templatePath = Join-Path $tempRoot 'Prism-SDT-Collector.template.txt'

            Copy-Item -LiteralPath $prismMappingPath -Destination $runtimeMappingPath
            $templateLines = [System.Collections.Generic.List[string]]::new()
            $templateLines.Add('Nutanix Prism SDT acceptance')
            $templateLines.Add('')
            foreach ($entry in $documentMappings) {
                $tag = [string]$entry.sdtTag
                $templateLines.Add("BEGIN:$tag")
                $templateLines.Add("<<SDT:$tag>>")
                $templateLines.Add("END:$tag")
                $templateLines.Add('')
            }
            Set-Content -LiteralPath $templatePath -Encoding UTF8 -Value $templateLines.ToArray()

            [ordered]@{
                schema = 'assembler.template-catalog'
                schemaVersion = 1
                displayName = 'Nutanix Prism acceptance catalog'
                entries = @(
                    [ordered]@{
                        id = 'nutanix-prism-acceptance'
                        techId = 'Nutanix.Prism'
                        displayName = 'Nutanix Prism Acceptance'
                        docType = 'acceptance'
                        mappingPath = 'Prism-SDT-Collector.mapping.json'
                        templatePath = 'Prism-SDT-Collector.template.txt'
                        outputFileName = 'Nutanix-Prism-Acceptance.txt'
                        enabled = $true
                        priority = 100
                    }
                )
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $catalogPath -Encoding UTF8

            $null = & $pwshPath -NoLogo -NoProfile -File (Join-Path $repoRoot 'scripts/Invoke-AssemblerBundleRender.ps1') `
                -BundleRoot $bundleRoot `
                -CatalogPath $catalogPath `
                -OutputRoot $outputRoot `
                -ContractsRoot $contractsRoot `
                -TechId Nutanix.Prism `
                -OutputType text

            $LASTEXITCODE | Should -Be 0

            $bundleReportPath = Join-Path $outputRoot 'assembler-bundle-render-report.json'
            Test-Path -LiteralPath $bundleReportPath -PathType Leaf | Should -BeTrue
            $bundleReport = Get-Content -LiteralPath $bundleReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $bundleReport.status | Should -Be 'OK'
            @($bundleReport.issues).Count | Should -Be 0
            @($bundleReport.runs).Count | Should -Be 1
            $bundleReport.runs[0].status | Should -Be 'WARN'

            $renderReport = $bundleReport.runs[0].rendererOutput
            $renderReport.status | Should -Be 'PARTIAL'
            @($renderReport.issues).Count | Should -Be 1
            $renderReport.issues[0].code | Should -Be 'ASB-ASM-SDT-DATASET-MISSING'
            $renderReport.issues[0].severity | Should -Be 'WARN'
            $renderReport.issues[0].message | Should -Match "LNV\.Nutanix\.Prism\.Group\[GroupKey\]\.Tables\.Relationships"
            @($renderReport.matches).Count | Should -Be $documentMappings.Count

            $matchedTags = @($renderReport.matches | ForEach-Object { [string]$_.tag })
            foreach ($entry in $documentMappings) {
                $matchedTags | Should -Contain ([string]$entry.sdtTag)
            }

            $rendered = Get-Content -LiteralPath $bundleReport.runs[0].outputPath -Raw -Encoding UTF8
            $rendered | Should -Not -Match '<<SDT:'
            foreach ($entry in $documentMappings) {
                $tag = [regex]::Escape([string]$entry.sdtTag)
                $sectionMatch = [regex]::Match($rendered, "(?s)BEGIN:$tag\s*(?<body>.*?)\s*END:$tag")
                $sectionMatch.Success | Should -BeTrue
                ([string]$sectionMatch.Groups['body'].Value).Trim().Length | Should -BeGreaterThan 0
            }

            $compiledMappingPath = Join-Path $outputRoot '.render-plan/mappings/nutanix-prism-acceptance.json'
            Test-Path -LiteralPath $compiledMappingPath -PathType Leaf | Should -BeTrue
            $compiledMapping = Get-Content -LiteralPath $compiledMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $compiledDatasets = @($compiledMapping.mappings | Where-Object { $_.ContainsKey('resolvedDataset') } | ForEach-Object { [string]$_.dataset } | Sort-Object -Unique)

            $evidenceOnlyDatasets = @(
                Get-ChildItem -LiteralPath (Join-Path $contractsRoot 'tech/Nutanix.Prism/dataset') -Filter '*.assembler.meta.json' -File |
                    ForEach-Object {
                        $metadata = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                        if ([string]$metadata.presentationKind -eq 'evidence' -or $metadata.documentFacing -eq $false) {
                            $_.BaseName -replace '\.assembler\.meta$', ''
                        }
                    } |
                    Sort-Object -Unique
            )
            $evidenceOnlyDatasets.Count | Should -BeGreaterThan 0

            foreach ($dataset in $evidenceOnlyDatasets) {
                $compiledDatasets | Should -Not -Contain $dataset
            }
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
