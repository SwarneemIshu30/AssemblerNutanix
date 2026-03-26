Describe 'Sync-AssemblerContractsToRepo' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot 'scripts/Sync-AssemblerContractsToRepo.ps1'
    $sourceRoot = Join-Path $repoRoot '.deps/contracts'
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source

    function New-DeterministicTempRoot {
        param([Parameter(Mandatory = $true)][string]$Name)

        $root = Join-Path ([System.IO.Path]::GetTempPath()) (Join-Path 'assembler-contract-sync-tests' $Name)
        if (Test-Path -LiteralPath $root -PathType Container) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }

        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function Invoke-SyncScript {
        param(
            [Parameter(Mandatory = $true)][string[]]$Arguments,
            [string]$ScriptPath = $scriptPath,
            [switch]$NonInteractive
        )

        $invocationArgs = @('-NoLogo', '-NoProfile')
        if ($NonInteractive) {
            $invocationArgs += '-NonInteractive'
        }

        $invocationArgs += @('-File', $ScriptPath)
        $invocationArgs += $Arguments

        $output = & $pwshPath @invocationArgs
        [ordered]@{
            Output = [string]$output
            ExitCode = $LASTEXITCODE
            Json = if ([string]::IsNullOrWhiteSpace([string]$output)) { $null } else { $output | ConvertFrom-Json -AsHashtable }
        }
    }

    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        throw 'pwsh is required to execute scripts in this test'
    }

    It 'copies an explicit local contracts source into the deterministic destination' {
        $tempRoot = New-DeterministicTempRoot -Name 'local-copy-success'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected exit code 0 from contract sync, got $($result.ExitCode)"
            }

            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'standards/mapping.dataset-to-sdt.schema.v1.json') -PathType Leaf)) {
                throw 'Expected mapping contract schema in destination after sync'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'standards/assembler/assembler.bundle-render-report.schema.v1.json') -PathType Leaf)) {
                throw 'Expected bundle render report schema in destination after sync'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'standards/assembler/assembler.projections.schema.v1.json') -PathType Leaf)) {
                throw 'Expected projection contract schema in destination after sync'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'contracts.snapshot.json') -PathType Leaf)) {
                throw 'Expected contracts snapshot in destination after sync'
            }
            if (-not (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf)) {
                throw 'Expected Lenovo.DE collector skeleton mapping generated from contract during sync'
            }

            $generatedMapping = Get-Content -LiteralPath $skeletonMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if ($generatedMapping.generatedFromContract.path -ne 'tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml') {
                throw "Expected generatedFromContract.path to be contract yaml path, got '$($generatedMapping.generatedFromContract.path)'"
            }
            if ((@($generatedMapping.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.Controllers' }).Count) -eq 0) {
                throw 'Expected generated skeleton mapping to include Controllers table mapping from contract'
            }

            if ($result.Json.status -ne 'ok') {
                throw "Expected sync status ok, got '$($result.Json.status)'"
            }
            if ($result.Json.mode -ne 'LocalExport') {
                throw "Expected sync mode LocalExport, got '$($result.Json.mode)'"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Json.skeletonMappingPath) -and -not (Test-Path -LiteralPath ([string]$result.Json.skeletonMappingPath) -PathType Leaf)) {
                throw "Expected report.skeletonMappingPath '$($result.Json.skeletonMappingPath)' to exist"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'supports auto-discovery when TechId is omitted and generates discovered mappings' {
        $tempRoot = New-DeterministicTempRoot -Name 'auto-discovery-no-techid'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $tempScriptRoot = Join-Path $tempRoot 'repo/scripts'
        $tempScriptPath = Join-Path $tempScriptRoot 'Sync-AssemblerContractsToRepo.ps1'

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $contractsSourceRoot 'tech/Echo.OrderedRegression/dataset') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $contractsSourceRoot 'tech/Echo.OrderedRegression/dataset/ping.assembler.meta.json') -Encoding UTF8 -Value @'
{
  "dataset": "ping",
  "datasetPathTemplate": "datasets/echo/Ping.json"
}
'@
        New-Item -ItemType Directory -Path $tempScriptRoot -Force | Out-Null
        Copy-Item -LiteralPath $scriptPath -Destination $tempScriptPath -Force

        try {
            $result = Invoke-SyncScript -ScriptPath $tempScriptPath -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected exit code 0 in TechId auto-discovery mode, got $($result.ExitCode). Output: $($result.Output)"
            }
            if ($result.Json.status -ne 'ok') {
                throw "Expected status ok in TechId auto-discovery mode, got '$($result.Json.status)'"
            }
            if ([string]$result.Output -match 'Method invocation failed because \[System\.Collections\.Specialized\.OrderedDictionary\] does not contain a method named ''ContainsKey''') {
                throw "Expected auto-discovery run to avoid OrderedDictionary ContainsKey method invocation errors. Output: $($result.Output)"
            }

            $generatedPaths = @($result.Json.skeletonMappingPaths)
            if ($generatedPaths.Count -eq 0) {
                throw 'Expected at least one generated skeleton mapping path from discovered tech ids'
            }

            $expectedDiscoveredMappingPath = Join-Path $tempRoot 'repo/templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
            if ($generatedPaths -notcontains $expectedDiscoveredMappingPath) {
                throw "Expected discovered mapping path '$expectedDiscoveredMappingPath' in report output. Paths: $($generatedPaths -join ', ')"
            }
            if (-not (Test-Path -LiteralPath $expectedDiscoveredMappingPath -PathType Leaf)) {
                throw "Expected discovered mapping file to exist at '$expectedDiscoveredMappingPath'"
            }

            $skippedTechIds = @($result.Json.skippedTechIds)
            if ($skippedTechIds -notcontains 'Echo.OrderedRegression') {
                throw "Expected auto-discovery run to skip Echo.OrderedRegression (missing mapping contract). Skipped: $($skippedTechIds -join ', ')"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'auto-discovery safely handles mixed mapping generations with optional policy blocks missing' {
        $tempRoot = New-DeterministicTempRoot -Name 'auto-discovery-mixed-generations'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $tempScriptRoot = Join-Path $tempRoot 'repo/scripts'
        $tempScriptPath = Join-Path $tempScriptRoot 'Sync-AssemblerContractsToRepo.ps1'

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force
        foreach ($techPath in @(Get-ChildItem -LiteralPath (Join-Path $contractsSourceRoot 'tech') -Directory)) {
            if ($techPath.Name -notin @('Lenovo.DE', 'Nutanix.PrismElement')) {
                Remove-Item -LiteralPath $techPath.FullName -Recurse -Force
            }
        }

        New-Item -ItemType Directory -Path $tempScriptRoot -Force | Out-Null
        Copy-Item -LiteralPath $scriptPath -Destination $tempScriptPath -Force

        try {
            $result = Invoke-SyncScript -ScriptPath $tempScriptPath -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected exit code 0 in mixed-generation auto-discovery mode, got $($result.ExitCode). Output: $($result.Output)"
            }
            if ($result.Json.status -ne 'ok') {
                throw "Expected status ok in mixed-generation auto-discovery mode, got '$($result.Json.status)'"
            }
            if ([string]$result.Output -match 'collectorSdtTagPolicy|collectorSkeletonMapping|PropertyNotFoundException|missing datasetPath\.template metadata') {
                throw "Expected auto-discovery to avoid optional-policy/dataset-template property crashes. Output: $($result.Output)"
            }

            $generatedPaths = @($result.Json.skeletonMappingPaths)
            $lenovoMappingPath = Join-Path $tempRoot 'repo/templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
            $nutanixMappingPath = Join-Path $tempRoot 'repo/templates/skeletons/Nutanix.PrismElement/Nutanix.PrismElement-SDT-Collector.mapping.json'
            if ($generatedPaths -notcontains $lenovoMappingPath) {
                throw "Expected generated mapping output for Lenovo.DE. Paths: $($generatedPaths -join ', ')"
            }
            if ($generatedPaths -notcontains $nutanixMappingPath) {
                throw "Expected generated mapping output for Nutanix.PrismElement. Paths: $($generatedPaths -join ', ')"
            }
            if (-not (Test-Path -LiteralPath $nutanixMappingPath -PathType Leaf)) {
                throw "Expected generated mapping file at '$nutanixMappingPath'"
            }

            $nutanixMapping = Get-Content -LiteralPath $nutanixMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if (($nutanixMapping.mappings | Measure-Object).Count -ne 0) {
                throw 'Expected generated Nutanix mapping to skip entries without datasetPath.template metadata'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'handles single-TechId post-sync summary without Count property failures' {
        $tempRoot = New-DeterministicTempRoot -Name 'single-techid-summary-count-safe'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-TechId', 'Lenovo.DE',
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected exit code 0 for single-TechId sync, got $($result.ExitCode). Output: $($result.Output)"
            }
            if ($result.Json.status -ne 'ok') {
                throw "Expected status ok for single-TechId sync, got '$($result.Json.status)'"
            }
            if ([string]$result.Output -match 'property ''Count'' cannot be found') {
                throw "Expected single-TechId sync to avoid scalar Count failures. Output: $($result.Output)"
            }

            if ([string]::IsNullOrWhiteSpace([string]$result.Json.skeletonMappingPath)) {
                throw 'Expected single-TechId sync to emit skeletonMappingPath in report'
            }
            if (-not (Test-Path -LiteralPath ([string]$result.Json.skeletonMappingPath) -PathType Leaf)) {
                throw "Expected skeleton mapping file at '$($result.Json.skeletonMappingPath)'"
            }

            if ([string]$result.Output -notmatch 'mapping generation') {
                throw "Expected sync output to include mapping generation stage details. Output: $($result.Output)"
            }
            if ([string]$result.Output -notmatch 'techIdsProcessed=Lenovo\.DE') {
                throw "Expected summary output to include techIdsProcessed=Lenovo.DE. Output: $($result.Output)"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'returns non-zero and structured error for invalid argument combinations' {
        $tempRoot = New-DeterministicTempRoot -Name 'invalid-argument-combo'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-ContractsVersion', '1.0.0',
                '-DepsContractsPath', $destinationRoot
            )

            if ($result.ExitCode -eq 0) {
                throw 'Expected non-zero exit code for invalid parameter combination'
            }

            if ($result.Json.status -ne 'error') {
                throw "Expected status=error, got '$($result.Json.status)'"
            }
            if ($result.Json.stage -ne 'argument-validation') {
                throw "Expected stage argument-validation, got '$($result.Json.stage)'"
            }
            if ([int]$result.Json.exitCode -ne 10) {
                throw "Expected exitCode 10 for argument validation failure, got '$($result.Json.exitCode)'"
            }
            if ([string]$result.Json.message -notmatch 'Specify either -ExportContractsPath') {
                throw "Expected actionable argument-validation message, got '$($result.Json.message)'"
            }

            if (Test-Path -LiteralPath $destinationRoot -PathType Container) {
                throw 'Did not expect destination directory to be created for argument validation failure'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'returns clear stage-specific error when local source path is missing' {
        $tempRoot = New-DeterministicTempRoot -Name 'missing-local-source'
        $missingSourceRoot = Join-Path $tempRoot 'does-not-exist'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $missingSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-Clean'
            )

            if ($result.ExitCode -eq 0) {
                throw 'Expected non-zero exit code when source path is missing'
            }
            if ($result.Json.status -ne 'error') {
                throw "Expected status=error, got '$($result.Json.status)'"
            }
            if ($result.Json.stage -ne 'local-copy') {
                throw "Expected stage local-copy for missing local source, got '$($result.Json.stage)'"
            }
            if ([int]$result.Json.exitCode -ne 30) {
                throw "Expected exitCode 30 for layout/local-copy errors, got '$($result.Json.exitCode)'"
            }
            if ([string]$result.Json.message -notmatch 'Cannot find path') {
                throw "Expected missing-path message, got '$($result.Json.message)'"
            }
            if ([string]$result.Json.recommendedAction -notmatch 'layout and destination permissions') {
                throw "Expected stage-specific recommended action, got '$($result.Json.recommendedAction)'"
            }

            if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) {
                throw 'Expected destination root to be created before source resolution failed'
            }
            if (Test-Path -LiteralPath (Join-Path $destinationRoot 'contracts.snapshot.json') -PathType Leaf) {
                throw 'Did not expect snapshot file when local source resolution failed'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }


    It 'fails mapping generation when dataset path template metadata is missing in strict empty-generation mode' {
        $tempRoot = New-DeterministicTempRoot -Name 'missing-dataset-path-template'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $contractsSourceRoot 'tech/Lenovo.DE/dataset/systems.assembler.meta.json') -Force

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-StrictEmptyGeneration',
                '-Clean'
            )

            if ($result.ExitCode -eq 0) {
                throw 'Expected non-zero exit code when dataset path template metadata is missing'
            }
            if ($result.Json.status -ne 'error') {
                throw "Expected status=error, got '$($result.Json.status)'"
            }
            if ($result.Json.stage -ne 'mapping-generation') {
                throw "Expected stage mapping-generation, got '$($result.Json.stage)'"
            }
            if ([int]$result.Json.exitCode -ne 40) {
                throw "Expected exitCode 40 for mapping-generation failure, got '$($result.Json.exitCode)'"
            }
            if ([string]$result.Json.message -notmatch 'datasetPath.template metadata') {
                throw "Expected missing dataset template guidance, got '$($result.Json.message)'"
            }

            if (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf) {
                throw 'Did not expect skeleton mapping output when dataset path template metadata is missing'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'reports empty generation status (without failing) when mappings exist but datasetPath metadata is absent and strict mode is off' {
        $tempRoot = New-DeterministicTempRoot -Name 'empty-generation-non-strict'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $techId = 'Regression.EmptyMeta'
        $mappingContractRelativePath = "tech/$techId/mapping.dataset-to-sdt.v1.yaml"
        $skeletonMappingPath = Join-Path $tempRoot "templates/skeletons/$techId/EmptyMeta-SDT-Collector.mapping.json"
        $techDatasetRoot = Join-Path $contractsSourceRoot "tech/$techId/dataset"
        $mappingContractPath = Join-Path $contractsSourceRoot $mappingContractRelativePath

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force
        New-Item -ItemType Directory -Path $techDatasetRoot -Force | Out-Null
        Set-Content -LiteralPath $mappingContractPath -Encoding UTF8 -Value @"
schema: mapping.dataset-to-sdt
schemaVersion: 1
techId: $techId
displayName: Regression empty metadata
mappings:
  - dataset: missing-template-dataset
    sdtTag: LNV.Regression.EmptyMeta.Tables.MissingTemplate
    required: false
"@

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-TechId', $techId,
                '-MappingContractRelativePath', $mappingContractRelativePath,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected success in non-strict empty-generation mode, got $($result.ExitCode). Output: $($result.Output)"
            }

            $dashboard = $result.Json.mappingShapeDashboard[$techId]
            if ($null -eq $dashboard) {
                throw "Expected mappingShapeDashboard entry for $techId"
            }
            if ([string]$dashboard.generationStatus -ne 'empty') {
                throw "Expected generationStatus empty for $techId, got '$($dashboard.generationStatus)'"
            }
            if ([int]$dashboard.contract.total -ne 1 -or [int]$dashboard.runtime.total -ne 0) {
                throw "Expected invariant contract.total=1/runtime.total=0, got contract=$($dashboard.contract.total), runtime=$($dashboard.runtime.total)"
            }
            if ([int]$dashboard.skipReasons.missingDatasetTemplate -ne 1) {
                throw "Expected missingDatasetTemplate skip count 1, got '$($dashboard.skipReasons.missingDatasetTemplate)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails sync in strict mode when generation status is empty' {
        $tempRoot = New-DeterministicTempRoot -Name 'empty-generation-strict'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $techId = 'Regression.EmptyMeta'
        $mappingContractRelativePath = "tech/$techId/mapping.dataset-to-sdt.v1.yaml"
        $skeletonMappingPath = Join-Path $tempRoot "templates/skeletons/$techId/EmptyMeta-SDT-Collector.mapping.json"
        $techDatasetRoot = Join-Path $contractsSourceRoot "tech/$techId/dataset"
        $mappingContractPath = Join-Path $contractsSourceRoot $mappingContractRelativePath

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force
        New-Item -ItemType Directory -Path $techDatasetRoot -Force | Out-Null
        Set-Content -LiteralPath $mappingContractPath -Encoding UTF8 -Value @"
schema: mapping.dataset-to-sdt
schemaVersion: 1
techId: $techId
displayName: Regression empty metadata
mappings:
  - dataset: missing-template-dataset
    sdtTag: LNV.Regression.EmptyMeta.Tables.MissingTemplate
    required: false
"@

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-TechId', $techId,
                '-MappingContractRelativePath', $mappingContractRelativePath,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-StrictEmptyGeneration',
                '-Clean'
            )

            if ($result.ExitCode -eq 0) {
                throw 'Expected strict empty-generation mode to fail'
            }
            if ($result.Json.stage -ne 'mapping-generation') {
                throw "Expected mapping-generation stage in strict empty-generation failure, got '$($result.Json.stage)'"
            }
            if ([string]$result.Json.message -notmatch 'invariant violated|Strict empty-generation policy is enabled') {
                throw "Expected strict empty-generation invariant failure message, got '$($result.Json.message)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'does not fail without strict mode even when required mappings generate empty output' {
        $tempRoot = New-DeterministicTempRoot -Name 'empty-generation-required-non-strict'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $techId = 'Regression.RequiredEmptyMeta'
        $mappingContractRelativePath = "tech/$techId/mapping.dataset-to-sdt.v1.yaml"
        $skeletonMappingPath = Join-Path $tempRoot "templates/skeletons/$techId/RequiredEmptyMeta-SDT-Collector.mapping.json"
        $techDatasetRoot = Join-Path $contractsSourceRoot "tech/$techId/dataset"
        $mappingContractPath = Join-Path $contractsSourceRoot $mappingContractRelativePath

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force
        New-Item -ItemType Directory -Path $techDatasetRoot -Force | Out-Null
        Set-Content -LiteralPath $mappingContractPath -Encoding UTF8 -Value @"
schema: mapping.dataset-to-sdt
schemaVersion: 1
techId: $techId
displayName: Regression required empty metadata
mappings:
  - dataset: missing-template-dataset
    sdtTag: LNV.Regression.RequiredEmptyMeta.Tables.MissingTemplate
    required: true
"@

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-TechId', $techId,
                '-MappingContractRelativePath', $mappingContractRelativePath,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected success without strict mode even for required empty-generation, got $($result.ExitCode). Output: $($result.Output)"
            }

            $dashboard = $result.Json.mappingShapeDashboard[$techId]
            if ([string]$dashboard.generationStatus -ne 'empty') {
                throw "Expected generationStatus empty for $techId, got '$($dashboard.generationStatus)'"
            }
            if ([bool]$dashboard.strictEmptyGeneration) {
                throw "Expected strictEmptyGeneration false without switch, got '$($dashboard.strictEmptyGeneration)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses contract syncPolicy selector defaults instead of hardcoded items selector' {
        $tempRoot = New-DeterministicTempRoot -Name 'sync-policy-selectors'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $mappingContractPath = Join-Path $contractsSourceRoot 'tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force

        $contractText = Get-Content -LiteralPath $mappingContractPath -Raw -Encoding UTF8
        $contractText = $contractText -replace "(?ms)allowedRenderAs:\s*\n\s*-\s*table", "allowedRenderAs:`n    - table`n    - list"
        $contractText = $contractText -replace "(?ms)(defaultByRenderAs:\s*\n\s*table:\s*\n\s*-\s*items)", "`$1`n        list:`n        - rows"
        $contractText = $contractText -replace "(?ms)(- dataset: system-controllers.*?renderHint:\s*\n\s*renderAs: )table", '${1}list'
        Set-Content -LiteralPath $mappingContractPath -Value $contractText -Encoding UTF8

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected exit code 0 from sync with list renderAs policy, got $($result.ExitCode)"
            }

            $generatedMapping = Get-Content -LiteralPath $skeletonMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $controllers = @($generatedMapping.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.Controllers' }) | Select-Object -First 1
            if ($null -eq $controllers) {
                throw 'Expected generated mapping for Controllers entry'
            }
            if ([string]$controllers.renderHint.renderAs -ne 'list') {
                throw "Expected controllers renderAs to be list, got '$($controllers.renderHint.renderAs)'"
            }
            if ((@($controllers.selectors) -join ',') -ne 'rows') {
                throw "Expected controllers selectors to resolve from syncPolicy defaultByRenderAs.list (rows), got '$(@($controllers.selectors) -join ',')'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails closed for required mappings when renderAs is unsupported by policy' {
        $tempRoot = New-DeterministicTempRoot -Name 'sync-policy-required-fail-closed'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $mappingContractPath = Join-Path $contractsSourceRoot 'tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force

        $contractText = Get-Content -LiteralPath $mappingContractPath -Raw -Encoding UTF8
        $contractText = $contractText -replace "(?ms)(- dataset: system-controllers.*?renderHint:\s*\n\s*renderAs: )table", '${1}matrix'
        Set-Content -LiteralPath $mappingContractPath -Value $contractText -Encoding UTF8

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-Clean'
            )

            if ($result.ExitCode -eq 0) {
                throw 'Expected non-zero exit code when required mapping renderAs is unsupported by policy'
            }
            if ($result.Json.stage -ne 'mapping-generation') {
                throw "Expected mapping-generation stage, got '$($result.Json.stage)'"
            }
            if ([string]$result.Json.message -notmatch 'Contract policy rejected mapping') {
                throw "Expected contract policy rejection message, got '$($result.Json.message)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits configured mapping tag shape for source-only, dual, and target-only contract entries' {
        $tempRoot = New-DeterministicTempRoot -Name 'mapping-shape-emission'
        $contractsSourceRoot = Join-Path $tempRoot 'contracts-source'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $mappingContractPath = Join-Path $contractsSourceRoot 'tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml'

        Copy-Item -LiteralPath $sourceRoot -Destination $contractsSourceRoot -Recurse -Force

        $contractText = Get-Content -LiteralPath $mappingContractPath -Raw -Encoding UTF8
        $contractText = $contractText -replace "(?ms)(- dataset: system-controllers\s+.*?projectionRef: LNV\.Lenovo\.DE\.System\[ArrayName\]\.Tables\.Controllers)", "`$1`n  phase: source-only"
        $contractText = $contractText -replace "(?ms)(- dataset: transport\s+.*?projectionRef: LNV\.Lenovo\.DE\.System\[ArrayName\]\.Tables\.Transport)", "`$1`n  phase: dual"
        $contractText = $contractText -replace "(?ms)(- dataset: system-dns\s+.*?projectionRef: LNV\.Lenovo\.DE\.System\[ArrayName\]\.Tables\.DNS)", "`$1`n  phase: target-first"
        Set-Content -LiteralPath $mappingContractPath -Value $contractText -Encoding UTF8

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $contractsSourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected sync success while testing shape emission, got $($result.ExitCode)"
            }

            $generatedMapping = Get-Content -LiteralPath $skeletonMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $controllers = @($generatedMapping.mappings | Where-Object { $_.dataset -eq 'datasets/systems/Controllers.json' }) | Select-Object -First 1
            $transport = @($generatedMapping.mappings | Where-Object { $_.dataset -eq 'datasets/systems/ActiveTransport.json' }) | Select-Object -First 1
            $dns = @($generatedMapping.mappings | Where-Object { $_.dataset -eq 'datasets/systems/DNS.json' }) | Select-Object -First 1

            if ($null -eq $controllers -or $null -eq $transport -or $null -eq $dns) {
                throw 'Expected generated mapping entries for Controllers, ActiveTransport, and DNS datasets'
            }

            if (-not $controllers.ContainsKey('sdtTag') -or $controllers.ContainsKey('target')) {
                throw 'Expected phase source-only entry to emit sdtTag only (no target.sdtTag)'
            }
            if (-not $transport.ContainsKey('sdtTag') -or -not ($transport.ContainsKey('target') -and $transport.target -is [System.Collections.IDictionary] -and $transport.target.ContainsKey('sdtTag'))) {
                throw 'Expected phase dual entry to emit both sdtTag and target.sdtTag'
            }
            if ($dns.ContainsKey('sdtTag') -or -not ($dns.ContainsKey('target') -and $dns.target -is [System.Collections.IDictionary] -and $dns.target.ContainsKey('sdtTag'))) {
                throw 'Expected phase target-first entry to emit target.sdtTag only'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'supports rollout mode legacy and reports migration dashboard counts' {
        $tempRoot = New-DeterministicTempRoot -Name 'mapping-shape-mode-legacy'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-OutputShapeMode', 'legacy',
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected success for legacy rollout mode, got $($result.ExitCode)"
            }

            $generatedMapping = Get-Content -LiteralPath $skeletonMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $firstEntry = @($generatedMapping.mappings)[0]
            if (-not $firstEntry.ContainsKey('sdtTag') -or $firstEntry.ContainsKey('target')) {
                throw 'Expected legacy rollout mode to emit sdtTag-only runtime mappings'
            }

            $dashboard = $result.Json.mappingShapeDashboard.'Lenovo.DE'
            if ($null -eq $dashboard) {
                throw 'Expected mappingShapeDashboard entry for Lenovo.DE'
            }
            if ([int]$dashboard.contract.sdtTagOnly -le 0) {
                throw "Expected contract dashboard to report sdtTag-only mappings, got '$($dashboard.contract.sdtTagOnly)'"
            }
            if ([int]$dashboard.runtime.dual -ne 0 -or [int]$dashboard.runtime.targetOnly -ne 0) {
                throw "Expected runtime dashboard to remain legacy-only, got dual=$($dashboard.runtime.dual), targetOnly=$($dashboard.runtime.targetOnly)"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'defaults output shape mode when omitted and still generates skeleton mapping' {
        $tempRoot = New-DeterministicTempRoot -Name 'mapping-shape-mode-default'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected success when OutputShapeMode is omitted, got $($result.ExitCode). Output: $($result.Output)"
            }
            if ([string]$result.Output -match 'Cannot validate argument on parameter ''OutputShapeMode''') {
                throw "Did not expect ValidateSet binding failure for omitted OutputShapeMode. Output: $($result.Output)"
            }
            if (-not (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf)) {
                throw 'Expected skeleton mapping generation to succeed in default output shape mode'
            }

            $generatedMapping = Get-Content -LiteralPath $skeletonMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if ($null -eq $generatedMapping -or @($generatedMapping.mappings).Count -eq 0) {
                throw 'Expected generated mapping to contain at least one mapping entry in default output shape mode'
            }
            if ($result.Json.outputShapeMode -ne $null) {
                throw "Expected report outputShapeMode to be null in default mode, got '$($result.Json.outputShapeMode)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails when rollout mode enforcement is dual but contract is legacy-shaped' {
        $tempRoot = New-DeterministicTempRoot -Name 'mapping-shape-mode-dual-fail'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-OutputShapeMode', 'dual',
                '-Clean'
            )

            if ($result.ExitCode -eq 0) {
                throw 'Expected failure when enforcing dual mode against legacy contract mappings'
            }
            if ($result.Json.stage -ne 'mapping-generation') {
                throw "Expected mapping-generation stage on rollout validation failure, got '$($result.Json.stage)'"
            }
            if ([string]$result.Json.message -notmatch "Output shape mode 'dual' violated") {
                throw "Expected dual-mode enforcement message, got '$($result.Json.message)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'sync succeeds when a YAML parser is available' {
        $tempRoot = New-DeterministicTempRoot -Name 'yaml-parser-available'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            )

            if ($result.ExitCode -ne 0) {
                throw "Expected exit code 0 when YAML parser is available, got $($result.ExitCode). Output: $($result.Output)"
            }
            if ($result.Json.status -ne 'ok') {
                throw "Expected status=ok when YAML parser is available, got '$($result.Json.status)'"
            }
            if (-not (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf)) {
                throw 'Expected skeleton mapping output when YAML parser is available'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits actionable error when YAML parser is unavailable' {
        $tempRoot = New-DeterministicTempRoot -Name 'missing-convertfromyaml'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $bootstrapPath = Join-Path $tempRoot 'invoke-with-mocked-get-command.ps1'

        @"
function Get-Command {
    param(
        [Parameter(Position = 0)]
        [string]
        `$Name
    )

    if (`$Name -eq 'ConvertFrom-Yaml') {
        return `$null
    }

    Microsoft.PowerShell.Utility\Get-Command @PSBoundParameters
}

& '$scriptPath' -ExportContractsPath '$sourceRoot' -DepsContractsPath '$destinationRoot' -SkeletonMappingOutputPath '$skeletonMappingPath' -Clean
"@ | Set-Content -LiteralPath $bootstrapPath -Encoding UTF8

        try {
            $output = & $pwshPath -NoLogo -NoProfile -File $bootstrapPath
            $exitCode = $LASTEXITCODE
            $report = $output | ConvertFrom-Json -AsHashtable

            if ($exitCode -eq 0) {
                throw 'Expected non-zero exit code when ConvertFrom-Yaml cannot be resolved'
            }
            if ($report.status -ne 'error') {
                throw "Expected status=error, got '$($report.status)'"
            }
            if ($report.stage -ne 'mapping-generation') {
                throw "Expected stage mapping-generation, got '$($report.stage)'"
            }
            if ([int]$report.exitCode -ne 40) {
                throw "Expected mapping-generation exit code 40, got '$($report.exitCode)'"
            }
            if ([string]$report.message -notmatch 'Detected PowerShell edition/version') {
                throw "Expected detected PowerShell edition/version details in parser error, got '$($report.message)'"
            }
            if ([string]$report.message -notmatch 'Install-Module powershell-yaml -Scope CurrentUser') {
                throw "Expected powershell-yaml install hint in parser error, got '$($report.message)'"
            }
            if ([string]$report.message -notmatch 'run this script under pwsh 7\+') {
                throw "Expected pwsh 7+ recommendation in parser error, got '$($report.message)'"
            }

            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'contracts.snapshot.json') -PathType Leaf)) {
                throw 'Expected snapshot to be written before mapping-generation failure'
            }
            if (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf) {
                throw 'Did not expect skeleton mapping output when ConvertFrom-Yaml is unavailable'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits expected verbose and stage marker output when verbose mode is enabled' {
        $tempRoot = New-DeterministicTempRoot -Name 'verbose-stage-markers'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        try {
            $mergedOutput = & $pwshPath -NoLogo -NoProfile -Command @"
`$InformationPreference = 'Continue'
& '$scriptPath' -ExportContractsPath '$sourceRoot' -DepsContractsPath '$destinationRoot' -SkeletonMappingOutputPath '$skeletonMappingPath' -Clean -Verbose 4>&1 6>&1
"@
            $exitCode = $LASTEXITCODE
            $allText = (($mergedOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

            if ($exitCode -ne 0) {
                throw "Expected exit code 0 for verbose invocation, got $exitCode"
            }

            foreach ($marker in @('[input validation]', '[source resolution]', '[copy/download]', '[layout normalization]', '[mapping generation]', '[final report]')) {
                if ($allText -notmatch [Regex]::Escape($marker)) {
                    throw "Expected stage marker '$marker' in verbose output"
                }
            }

            if ($allText -notmatch 'VERBOSE:') {
                throw 'Expected verbose stream entries in merged output'
            }
            if ($allText -notmatch 'durationMs') {
                throw 'Expected verbose details to include durationMs values'
            }

            $jsonLine = ($mergedOutput | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
            $report = $jsonLine | ConvertFrom-Json -AsHashtable
            if ($report.status -ne 'ok') {
                throw "Expected final JSON status ok, got '$($report.status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'does not break non-interactive invocation when progress helper is enabled' {
        $tempRoot = New-DeterministicTempRoot -Name 'noninteractive-progress'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean'
            ) -NonInteractive

            if ($result.ExitCode -ne 0) {
                throw "Expected non-interactive invocation to succeed, got $($result.ExitCode)"
            }
            if ($result.Json.status -ne 'ok') {
                throw "Expected status=ok for non-interactive invocation, got '$($result.Json.status)'"
            }

            if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'contracts.snapshot.json') -PathType Leaf)) {
                throw 'Expected snapshot in non-interactive run'
            }
            if (-not (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf)) {
                throw 'Expected mapping output in non-interactive run'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'retries published-pack downloads on network failure and returns categorized exit payload' {
        $tempRoot = New-DeterministicTempRoot -Name 'published-pack-network-failure'
        $destinationRoot = Join-Path $tempRoot '.deps/contracts'
        $skeletonMappingPath = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $missingPackUrl = 'http://127.0.0.1:1/contracts.zip'

        try {
            $result = Invoke-SyncScript -Arguments @(
                '-ContractsPackUrl', $missingPackUrl,
                '-DownloadRetryCount', '2',
                '-DownloadTimeoutSec', '1',
                '-DepsContractsPath', $destinationRoot,
                '-SkeletonMappingOutputPath', $skeletonMappingPath,
                '-Clean',
                '-Verbose'
            )

            if ($result.ExitCode -eq 0) {
                throw 'Expected non-zero exit code for failed published-pack download'
            }
            if ($result.Json.status -ne 'error') {
                throw "Expected status=error, got '$($result.Json.status)'"
            }
            if ($result.Json.stage -ne 'download') {
                throw "Expected stage=download, got '$($result.Json.stage)'"
            }
            if ([int]$result.Json.exitCode -ne 20) {
                throw "Expected exitCode=20 for download stage failures, got '$($result.Json.exitCode)'"
            }
            if ([string]$result.Json.message -notmatch 'after 2 attempt\(s\)') {
                throw "Expected retry-count details in message, got '$($result.Json.message)'"
            }
            if ([string]$result.Json.recommendedAction -notmatch 'network connectivity') {
                throw "Expected download-stage recommended action, got '$($result.Json.recommendedAction)'"
            }

            if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) {
                throw 'Expected destination directory to be created before download failure'
            }
            if (Test-Path -LiteralPath (Join-Path $destinationRoot 'contracts.snapshot.json') -PathType Leaf) {
                throw 'Did not expect snapshot generation on download failure'
            }
            if (Test-Path -LiteralPath $skeletonMappingPath -PathType Leaf) {
                throw 'Did not expect skeleton mapping output on download failure'
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'produces consistent post-sync outputs for local-copy and published-pack modes' {
        $tempRoot = New-DeterministicTempRoot -Name 'mode-consistency'
        $localDestinationRoot = Join-Path $tempRoot 'local/.deps/contracts'
        $packDestinationRoot = Join-Path $tempRoot 'pack/.deps/contracts'
        $localMappingPath = Join-Path $tempRoot 'local/templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $packMappingPath = Join-Path $tempRoot 'pack/templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json'
        $zipPath = Join-Path $tempRoot 'contracts.zip'
        $httpRoot = Join-Path $tempRoot 'http'
        $pythonPath = (Get-Command python3 -ErrorAction SilentlyContinue).Source
        $serverProcess = $null

        if ([string]::IsNullOrWhiteSpace($pythonPath)) {
            throw 'python3 is required for local published-pack HTTP smoke test.'
        }

        try {
            New-Item -ItemType Directory -Path $httpRoot -Force | Out-Null
            Compress-Archive -Path (Join-Path $sourceRoot '*') -DestinationPath $zipPath -Force
            Copy-Item -LiteralPath $zipPath -Destination (Join-Path $httpRoot 'contracts.zip') -Force

            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $listener.Stop()

            $serverProcess = Start-Process -FilePath $pythonPath -ArgumentList @('-m', 'http.server', [string]$port, '--bind', '127.0.0.1') -WorkingDirectory $httpRoot -PassThru
            Start-Sleep -Seconds 1

            $localResult = Invoke-SyncScript -Arguments @(
                '-ExportContractsPath', $sourceRoot,
                '-DepsContractsPath', $localDestinationRoot,
                '-SkeletonMappingOutputPath', $localMappingPath,
                '-Clean'
            )
            $packResult = Invoke-SyncScript -Arguments @(
                '-ContractsPackUrl', "http://127.0.0.1:$port/contracts.zip",
                '-DepsContractsPath', $packDestinationRoot,
                '-SkeletonMappingOutputPath', $packMappingPath,
                '-Clean'
            )

            if ($localResult.ExitCode -ne 0 -or $packResult.ExitCode -ne 0) {
                throw "Expected both sync modes to succeed, got local=$($localResult.ExitCode), pack=$($packResult.ExitCode)"
            }

            $localSnapshot = Get-Content -LiteralPath (Join-Path $localDestinationRoot 'contracts.snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $packSnapshot = Get-Content -LiteralPath (Join-Path $packDestinationRoot 'contracts.snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

            if ([string]$localSnapshot.source -ne 'local-export-copy') {
                throw "Expected local snapshot source local-export-copy, got '$($localSnapshot.source)'"
            }
            if ([string]$packSnapshot.source -ne 'published-pack') {
                throw "Expected published-pack snapshot source, got '$($packSnapshot.source)'"
            }

            $localMapping = Get-Content -LiteralPath $localMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $packMapping = Get-Content -LiteralPath $packMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

            if (@($localMapping.mappings).Count -ne @($packMapping.mappings).Count) {
                throw 'Expected equal mapping counts from local and published-pack modes'
            }

            $localControllers = @($localMapping.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.Controllers' }) | Select-Object -First 1
            $packControllers = @($packMapping.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.Controllers' }) | Select-Object -First 1
            if ($null -eq $localControllers -or $null -eq $packControllers) {
                throw 'Expected controllers mapping in both mode outputs'
            }
            if (($localControllers | ConvertTo-Json -Depth 20) -ne ($packControllers | ConvertTo-Json -Depth 20)) {
                throw 'Expected controllers mapping entry to be identical across sync modes'
            }
        }
        finally {
            if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
                Stop-Process -Id $serverProcess.Id -Force
            }
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
