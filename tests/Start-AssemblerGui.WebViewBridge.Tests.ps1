Describe 'Assembler GUI WebView bridge module' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $modulePath = Join-Path $script:repoRoot 'gui/internal/AssemblerGuiWebViewBridge.psm1'
        Import-Module $modulePath -Force
    }

    It 'enforces allow-listed file roots' {
        $allowed = New-AssemblerWebViewBridgeRoots -RepoRoot $script:repoRoot -BundleRoot (Join-Path $script:repoRoot 'bundle') -OutputRoot (Join-Path $script:repoRoot 'out') -ContractsRoot (Join-Path $script:repoRoot '.deps/contracts')
        $insidePath = Join-Path $script:repoRoot 'gui/README.md'
        $outsidePath = Join-Path ([System.IO.Path]::GetTempPath()) 'outside.txt'

        if (-not (Test-AssemblerWebViewAllowedPath -Path $insidePath -AllowedRoots $allowed -BaseRoot $script:repoRoot)) {
            throw "Expected repo file path to be allowed: $insidePath"
        }
        if (Test-AssemblerWebViewAllowedPath -Path $outsidePath -AllowedRoots $allowed -BaseRoot $repoRoot) {
            throw "Expected temp path to be rejected: $outsidePath"
        }
    }

    It 'opens allowed files through the bridge envelope' {
        $allowed = @($script:repoRoot)
        $response = Invoke-AssemblerWebViewCommand -RepoRoot $script:repoRoot -AllowedRoots $allowed -Message ([ordered]@{
            id = '1'
            command = 'OpenFile'
            payload = [ordered]@{ path = (Join-Path $script:repoRoot 'gui/README.md') }
        })

        if (-not [bool]$response.ok) {
            throw "Expected OpenFile response to succeed: $($response.error)"
        }
        if ([string]$response.type -ne 'FileContent') {
            throw "Expected FileContent response, got $($response.type)"
        }
        if ([string]$response.payload.text -notmatch 'Assembler GUI launchers') {
            throw 'Expected file content payload.'
        }
    }

    It 'delegates validation and render commands to callbacks' {
        $callbacks = @{
            ValidateMapping = { param($payload) [ordered]@{ status = 'ok'; issues = @(); path = [string]$payload.path } }
            RunRender = { param($payload) [ordered]@{ accepted = $true; outputRoot = [string]$payload.outputRoot } }
        }

        $validation = Invoke-AssemblerWebViewCommand -RepoRoot $script:repoRoot -AllowedRoots @($script:repoRoot) -Callbacks $callbacks -Message ([ordered]@{
            id = '2'
            command = 'ValidateMapping'
            payload = [ordered]@{ path = 'mapping.yaml' }
        })
        $render = Invoke-AssemblerWebViewCommand -RepoRoot $script:repoRoot -AllowedRoots @($script:repoRoot) -Callbacks $callbacks -Message ([ordered]@{
            id = '3'
            command = 'RunRender'
            payload = [ordered]@{ outputRoot = 'out' }
        })

        if (-not [bool]$validation.ok -or [string]$validation.type -ne 'ValidationResult') {
            throw 'Expected validation callback response.'
        }
        if (-not [bool]$render.ok -or -not [bool]$render.payload.accepted) {
            throw 'Expected render callback response.'
        }
    }

    It 'returns an error envelope for malformed WebView JSON' {
        $response = Invoke-AssemblerWebViewCommand -RepoRoot $script:repoRoot -AllowedRoots @($script:repoRoot) -Message '{not-json'

        if ([bool]$response.ok) {
            throw 'Expected malformed JSON to return an error response.'
        }
        if ([string]$response.type -ne 'Error' -or [string]$response.error -notmatch 'Invalid WebView message JSON') {
            throw "Expected invalid JSON error envelope, got type='$($response.type)' error='$($response.error)'"
        }
    }

    It 'builds read-only Mapping Studio state with inventory and missing-artifact fallbacks' {
        $workbench = [ordered]@{
            Targets = @(
                [pscustomobject]@{
                    TargetPath = 'LNV.Tag.One'
                    PlacementGroup = 'Placed in template'
                    TypeLabel = 'Table'
                    IsMapped = $true
                    IsPlaced = $true
                }
            )
            Warnings = @('warning one')
            MappingDocument = [ordered]@{
                contractPath = Join-Path $script:repoRoot 'missing.yaml'
                runtimePath = ''
            }
        }

        $state = New-AssemblerWebViewMappingStudioState -Workbench $workbench -ResolvedMappingsRoot (Join-Path $script:repoRoot 'missing-resolved') -RenderReportPath (Join-Path $script:repoRoot 'missing-report.json') -Status 'ready'

        if (@($state.sdtInventory).Count -ne 1 -or [string]$state.sdtInventory[0].tag -ne 'LNV.Tag.One') {
            throw 'Expected SDT inventory payload from workbench targets.'
        }
        if ([string]$state.manifestText -notmatch 'No mapping manifest') {
            throw "Expected missing manifest fallback, got '$($state.manifestText)'"
        }
        if ([string]$state.resolvedMappingsText -notmatch 'No resolved mappings') {
            throw "Expected missing resolved mappings fallback, got '$($state.resolvedMappingsText)'"
        }
        if ([string]$state.renderReportText -notmatch 'No render report') {
            throw "Expected missing render report fallback, got '$($state.renderReportText)'"
        }
    }
}
