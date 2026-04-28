Describe 'Invoke-AssemblerPipeline validation result handling' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:archiveModulePath = Join-Path $script:repoRoot 'scripts/internal/AssemblerBundleArchive.psm1'
        Import-Module $script:archiveModulePath -Force
        $script:pipelineExtractedRootsToRemove = [System.Collections.Generic.List[string]]::new()

        function New-PipelineArchiveInput {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("lnv-pipeline-archive-test-" + [guid]::NewGuid().ToString('n'))
            $bundleRoot = Join-Path $root 'bundle'
            $configRoot = Join-Path $bundleRoot 'config'
            New-Item -Path $configRoot -ItemType Directory -Force | Out-Null

            $objectIndex = [ordered]@{
                schemaVersion = 1
                collectedUtc = '2026-01-01T00:00:00Z'
                objects = @(
                    [ordered]@{
                        techId = 'Test.Tech'
                        kind = 'test'
                        key = 'target-a'
                        displayName = 'Target A'
                    }
                )
            }
            $solutionPlan = [ordered]@{
                schemaVersion = 1
                solutionId = 'PipelineArchiveTest'
                targets = @(
                    [ordered]@{
                        techId = 'Test.Tech'
                        kind = 'test'
                        key = 'target-a'
                        displayName = 'Target A'
                        endpoints = [ordered]@{ default = 'localhost' }
                    }
                )
                collectors = @(
                    [ordered]@{
                        techId = 'Test.Tech'
                        modulePath = 'Test.Module'
                        targetKeys = @('target-a')
                    }
                )
            }
            Set-Content -LiteralPath (Join-Path $bundleRoot 'objectIndex.json') -Value ($objectIndex | ConvertTo-Json -Depth 20) -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $configRoot 'solution.plan.json') -Value ($solutionPlan | ConvertTo-Json -Depth 20) -Encoding UTF8

            $relativeFiles = @('objectIndex.json', 'config/solution.plan.json')
            $fileIndex = @(
                foreach ($relativeFile in $relativeFiles) {
                    $filePath = Join-Path $bundleRoot ($relativeFile -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                    [pscustomobject]@{
                        path = $relativeFile
                        bytes = (Get-Item -LiteralPath $filePath).Length
                        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash.ToLowerInvariant()
                    }
                }
            )
            $manifest = [ordered]@{
                schemaVersion = 1
                bundleId = 'pipeline-archive-test'
                createdUtc = '2026-01-01T00:00:00Z'
                completedUtc = '2026-01-01T00:00:01Z'
                files = @($fileIndex)
                results = @(
                    [ordered]@{
                        techId = 'Test.Tech'
                        status = 'OK'
                        startedUtc = '2026-01-01T00:00:00Z'
                        completedUtc = '2026-01-01T00:00:01Z'
                        errors = @()
                        warnings = @()
                    }
                )
                integrity = [ordered]@{
                    hashAlgorithm = 'SHA256'
                    bundleHash = Get-AssemblerBundleHash -FileIndex $fileIndex
                }
            }
            Set-Content -LiteralPath (Join-Path $bundleRoot 'manifest.json') -Value ($manifest | ConvertTo-Json -Depth 20) -Encoding UTF8

            $archivePath = Join-Path $root 'pipeline-archive-test.lnvbundle.zip'
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($entry in @('manifest.json') + @($fileIndex | Sort-Object path | ForEach-Object { [string]$_.path })) {
                    $sourcePath = Join-Path $bundleRoot ($entry -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $sourcePath, $entry, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
                }
            }
            finally {
                $zip.Dispose()
            }

            [pscustomobject]@{
                Root = $root
                BundleRoot = $bundleRoot
                ArchivePath = $archivePath
            }
        }
    }

    AfterAll {
        $bundleRoot = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'bundle')).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        foreach ($root in @($script:pipelineExtractedRootsToRemove | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $fullRoot = [System.IO.Path]::GetFullPath($root)
            if ($fullRoot.StartsWith($bundleRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullRoot -PathType Container)) {
                Remove-Item -LiteralPath $fullRoot -Recurse -Force
            }
        }
    }

    It 'returns status ok for a valid solution plan without throwing on planErrors.Count' {
        $repoRoot = $script:repoRoot
        $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $bundleRoot = (New-PipelineArchiveInput).BundleRoot

        $contractsRoot = Join-Path $repoRoot '.deps/contracts'

        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts/Invoke-AssemblerPipeline.ps1 in this test'
        }

        $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -ContractsRoot $contractsRoot
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            throw "Expected exit code 0 for valid bundle, got $exitCode"
        }
        if ([string]::IsNullOrWhiteSpace([string]$output)) {
            throw 'Expected non-empty output from Invoke-AssemblerPipeline'
        }

        $report = $output | ConvertFrom-Json -AsHashtable
        if ($report.status -ne 'ok') {
            throw "Expected report.status to be 'ok' for valid bundle, got '$($report.status)'"
        }

        $renderStage = @($report.stages | Where-Object { [string]$_.name -eq 'Render' })[0]
        if ($null -eq $renderStage) {
            throw 'Expected Render stage to be present in pipeline report'
        }
        if ([string]$renderStage.status -ne 'SKIPPED') {
            throw "Expected Render stage status SKIPPED by default, got '$($renderStage.status)'"
        }

        $guidanceDiagnostic = @($report.diagnostics | Where-Object { [string]$_.code -eq 'ASB-ASM-RENDER-NEXT-COMMAND' })[0]
        if ($null -eq $guidanceDiagnostic) {
            throw 'Expected ASB-ASM-RENDER-NEXT-COMMAND diagnostic when render handoff is not requested'
        }
        if ([string]$guidanceDiagnostic.message -notlike '*Invoke-AssemblerBundleRender.ps1*') {
            throw "Expected guidance diagnostic to reference Invoke-AssemblerBundleRender.ps1, got '$($guidanceDiagnostic.message)'"
        }
    }

    It 'returns status error and guidance when render handoff parameters are incomplete' {
        $repoRoot = $script:repoRoot
        $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $bundleRoot = (New-PipelineArchiveInput).BundleRoot

        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts/Invoke-AssemblerPipeline.ps1 in this test'
        }

        $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -ContractsRoot $contractsRoot -RenderCatalogPath './templates/skeletons/Lenovo.DE/DE-SDT-Dummy.catalog.json'
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            throw 'Expected non-zero exit code when render handoff parameters are incomplete'
        }

        $report = $output | ConvertFrom-Json -AsHashtable
        if ($report.status -ne 'error') {
            throw "Expected report.status to be 'error' for incomplete render handoff params, got '$($report.status)'"
        }
        $failureDiagnostic = @($report.diagnostics | Where-Object { [string]$_.code -eq 'ASB-ASM-INPUT-FAIL' })[0]
        if ($null -eq $failureDiagnostic -or [string]$failureDiagnostic.message -notlike '*ASB-ASM-RENDER-PARAMS-INCOMPLETE*') {
            throw "Expected failure diagnostic to include ASB-ASM-RENDER-PARAMS-INCOMPLETE, got '$($failureDiagnostic.message)'"
        }
    }

    It 'returns status error when mapping shape paths are supplied without mode' {
        $repoRoot = $script:repoRoot
        $scriptPath = Join-Path $repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $bundleRoot = (New-PipelineArchiveInput).BundleRoot

        $contractsRoot = Join-Path $repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts/Invoke-AssemblerPipeline.ps1 in this test'
        }

        $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $bundleRoot -ContractsRoot $contractsRoot -ContractMappingPath './.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            throw 'Expected non-zero exit code when mapping path is supplied without -MappingShapeMode'
        }

        $report = $output | ConvertFrom-Json -AsHashtable
        if ($report.status -ne 'error') {
            throw "Expected report.status to be 'error' for missing mapping shape mode, got '$($report.status)'"
        }
        $failureDiagnostic = @($report.diagnostics | Where-Object { [string]$_.code -eq 'ASB-ASM-INPUT-FAIL' })[0]
        if ($null -eq $failureDiagnostic -or [string]$failureDiagnostic.message -notlike '*ASB-ASM-MAPPING-SHAPE-PARAMS-INCOMPLETE*') {
            throw "Expected mapping shape parameter guidance, got '$($failureDiagnostic.message)'"
        }
    }

    It 'imports a bundle archive before validation and reports the extracted repo bundle root' {
        $inputRoot = New-PipelineArchiveInput
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $contractsRoot = Join-Path $script:repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts/Invoke-AssemblerPipeline.ps1 in this test'
        }

        $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleArchivePath $inputRoot.ArchivePath -ContractsRoot $contractsRoot
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Expected exit code 0 for valid archive, got $exitCode :: $output"
        }

        $report = $output | ConvertFrom-Json -AsHashtable
        if ($report.status -ne 'ok') {
            throw "Expected report.status ok, got '$($report.status)'"
        }
        if ($null -eq $report.archiveImport -or [string]$report.archiveImport.status -ne 'OK') {
            throw 'Expected archiveImport status OK.'
        }
        $script:pipelineExtractedRootsToRemove.Add([string]$report.archiveImport.extractedBundleRoot)
        $repoBundleRoot = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'bundle')).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if (-not ([string]$report.bundle.root).StartsWith($repoBundleRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Expected pipeline bundle root under repo bundle folder, got '$($report.bundle.root)'."
        }
    }

    It 'rejects folder and archive inputs together' {
        $inputRoot = New-PipelineArchiveInput
        $scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-AssemblerPipeline.ps1'
        $contractsRoot = Join-Path $script:repoRoot '.deps/contracts'
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw 'pwsh is required to execute scripts/Invoke-AssemblerPipeline.ps1 in this test'
        }

        $output = & $pwshPath -NoLogo -NoProfile -File $scriptPath -BundleRoot $inputRoot.BundleRoot -BundleArchivePath $inputRoot.ArchivePath -ContractsRoot $contractsRoot
        if ($LASTEXITCODE -eq 0) {
            throw 'Expected non-zero exit code when both bundle inputs are supplied.'
        }
        $report = $output | ConvertFrom-Json -AsHashtable
        $failureDiagnostic = @($report.diagnostics | Where-Object { [string]$_.code -eq 'ASB-ASM-INPUT-FAIL' })[0]
        if ($null -eq $failureDiagnostic -or [string]$failureDiagnostic.message -notlike '*ASB-ASM-INPUT-BUNDLE-MODE-CONFLICT*') {
            throw "Expected bundle mode conflict diagnostic, got '$($failureDiagnostic.message)'"
        }
    }
}
