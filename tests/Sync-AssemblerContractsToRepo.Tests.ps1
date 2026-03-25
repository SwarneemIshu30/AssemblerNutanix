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
            [switch]$NonInteractive
        )

        $invocationArgs = @('-NoLogo', '-NoProfile')
        if ($NonInteractive) {
            $invocationArgs += '-NonInteractive'
        }

        $invocationArgs += @('-File', $scriptPath)
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


    It 'fails mapping generation when dataset path template metadata is missing' {
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

    It 'emits actionable error when ConvertFrom-Yaml is unavailable' {
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
            if ([string]$report.message -notmatch 'ConvertFrom-Yaml is required') {
                throw "Expected actionable ConvertFrom-Yaml guidance, got '$($report.message)'"
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
