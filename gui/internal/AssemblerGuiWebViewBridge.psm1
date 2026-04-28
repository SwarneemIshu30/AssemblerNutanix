Set-StrictMode -Version Latest

function ConvertTo-BridgeDictionary {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return @{} }
    if ($Value -is [System.Collections.IDictionary]) { return $Value }

    $result = @{}
    foreach ($property in @($Value.PSObject.Properties)) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Test-BridgeHasKey {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ($Map -is [hashtable]) { return $Map.ContainsKey($Key) }
    return $Map.Contains($Key)
}

function New-AssemblerWebViewBridgeRoots {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$BundleRoot,
        [Parameter(Mandatory = $false)][string]$OutputRoot,
        [Parameter(Mandatory = $false)][string]$ContractsRoot
    )

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        $RepoRoot,
        $BundleRoot,
        $OutputRoot,
        $ContractsRoot,
        (Join-Path $RepoRoot '.deps/contracts'),
        (Join-Path $RepoRoot 'exports/LNV.AsBuiltDoc.Contracts'),
        (Join-Path $RepoRoot 'templates/skeletons')
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $fullPath = [System.IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $fullPath -PathType Container) {
                $fullPath = (Resolve-Path -LiteralPath $fullPath).Path
            }
            if (-not (@($roots) -contains $fullPath)) {
                $roots.Add($fullPath)
            }
        }
        catch {
            continue
        }
    }

    return @($roots)
}

function Test-AssemblerWebViewAllowedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedRoots,
        [Parameter(Mandatory = $false)][string]$BaseRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        if ([string]::IsNullOrWhiteSpace($BaseRoot)) { return $false }
        $candidate = Join-Path $BaseRoot $candidate
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
    }
    catch {
        return $false
    }

    foreach ($root in @($AllowedRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try {
            $fullRoot = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
            if ($fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        catch {
            continue
        }
    }

    return $false
}

function New-AssemblerWebViewResponse {
    param(
        [Parameter(Mandatory = $false)][string]$Id,
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $false)]$Payload = $null,
        [Parameter(Mandatory = $false)][string]$Error = ''
    )

    [ordered]@{
        id = if ([string]::IsNullOrWhiteSpace($Id)) { $null } else { $Id }
        ok = $Ok
        type = $Type
        payload = $Payload
        error = if ([string]::IsNullOrWhiteSpace($Error)) { $null } else { $Error }
    }
}

function ConvertFrom-AssemblerWebViewMessage {
    param([Parameter(Mandatory = $true)]$Message)

    if ($Message -is [string]) {
        try {
            return ($Message | ConvertFrom-Json -AsHashtable)
        }
        catch {
            throw "Invalid WebView message JSON: $($_.Exception.Message)"
        }
    }

    return (ConvertTo-BridgeDictionary -Value $Message)
}

function Get-AssemblerWebViewFileText {
    param(
        [Parameter(Mandatory = $false)][string]$Path,
        [Parameter(Mandatory = $false)][string]$MissingText = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $MissingText
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function New-AssemblerWebViewMappingStudioState {
    param(
        [Parameter(Mandatory = $false)]$Workbench,
        [Parameter(Mandatory = $false)][string]$ManifestPath,
        [Parameter(Mandatory = $false)][string]$ResolvedMappingsRoot,
        [Parameter(Mandatory = $false)][string]$RenderReportPath,
        [Parameter(Mandatory = $false)][string]$Status = ''
    )

    $sdtInventory = @()
    $warnings = @()
    if ($null -ne $Workbench) {
        $sdtInventory = @($Workbench.Targets | ForEach-Object {
                [ordered]@{
                    tag = [string]$_.TargetPath
                    domain = [string]$_.PlacementGroup
                    blockType = [string]$_.TypeLabel
                    mapped = [bool]$_.IsMapped
                    placed = [bool]$_.IsPlaced
                }
            })
        $warnings = @($Workbench.Warnings)
        if ([string]::IsNullOrWhiteSpace($ManifestPath) -and $null -ne $Workbench.MappingDocument) {
            $ManifestPath = [string]$Workbench.MappingDocument.contractPath
            if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
                $ManifestPath = [string]$Workbench.MappingDocument.runtimePath
            }
        }
    }

    $resolvedMappingsText = 'No resolved mappings found.'
    if (-not [string]::IsNullOrWhiteSpace($ResolvedMappingsRoot) -and (Test-Path -LiteralPath $ResolvedMappingsRoot -PathType Container)) {
        $resolvedFiles = @(Get-ChildItem -LiteralPath $ResolvedMappingsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
        if ($resolvedFiles.Count -gt 0) {
            $resolvedChunks = foreach ($file in $resolvedFiles) {
                @(
                    "### $($file.Name)"
                    (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8)
                ) -join [Environment]::NewLine
            }
            $resolvedMappingsText = $resolvedChunks -join ([Environment]::NewLine + [Environment]::NewLine)
        }
    }

    $validation = [ordered]@{
        status = if ($warnings.Count -gt 0) { 'warning' } else { 'ok' }
        issues = @($warnings)
    }

    [ordered]@{
        sdtInventory = @($sdtInventory)
        manifestPath = if ([string]::IsNullOrWhiteSpace($ManifestPath)) { '' } else { $ManifestPath }
        manifestText = Get-AssemblerWebViewFileText -Path $ManifestPath -MissingText 'No mapping manifest is available.'
        resolvedMappingsText = $resolvedMappingsText
        validationText = ($validation | ConvertTo-Json -Depth 20)
        renderReportText = Get-AssemblerWebViewFileText -Path $RenderReportPath -MissingText 'No render report is available.'
        status = if ([string]::IsNullOrWhiteSpace($Status)) { 'Mapping Studio state loaded.' } else { $Status }
    }
}

function Invoke-AssemblerWebViewCommand {
    param(
        [Parameter(Mandatory = $true)]$Message,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$AllowedRoots,
        [Parameter(Mandatory = $false)]$Callbacks = @{}
    )

    try {
        $request = ConvertFrom-AssemblerWebViewMessage -Message $Message
    }
    catch {
        return New-AssemblerWebViewResponse -Ok $false -Type 'Error' -Error $_.Exception.Message
    }

    $id = if (Test-BridgeHasKey -Map $request -Key 'id') { [string]$request.id } else { $null }
    $command = if (Test-BridgeHasKey -Map $request -Key 'command') { [string]$request.command } else { '' }
    $payload = if (Test-BridgeHasKey -Map $request -Key 'payload') { ConvertTo-BridgeDictionary -Value $request.payload } else { @{} }
    $callbackMap = ConvertTo-BridgeDictionary -Value $Callbacks

    try {
        switch ($command) {
            'OpenFile' {
                $path = [string]$payload.path
                if (-not (Test-AssemblerWebViewAllowedPath -Path $path -AllowedRoots $AllowedRoots -BaseRoot $RepoRoot)) {
                    throw "Path is outside the WebView bridge allow-list: $path"
                }
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw "File not found: $path"
                }
                $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
                return New-AssemblerWebViewResponse -Id $id -Ok $true -Type 'FileContent' -Payload ([ordered]@{ path = $path; text = $text })
            }
            'SaveMapping' {
                if (-not (Test-BridgeHasKey -Map $callbackMap -Key 'SaveMapping')) {
                    throw 'SaveMapping callback is not configured.'
                }
                $result = & $callbackMap.SaveMapping $payload
                return New-AssemblerWebViewResponse -Id $id -Ok $true -Type 'SaveMappingResult' -Payload $result
            }
            'ValidateMapping' {
                if (Test-BridgeHasKey -Map $callbackMap -Key 'ValidateMapping') {
                    $result = & $callbackMap.ValidateMapping $payload
                }
                else {
                    $result = [ordered]@{ status = 'ok'; issues = @(); message = 'No bridge validation callback was configured.' }
                }
                return New-AssemblerWebViewResponse -Id $id -Ok $true -Type 'ValidationResult' -Payload $result
            }
            'RunRender' {
                if (-not (Test-BridgeHasKey -Map $callbackMap -Key 'RunRender')) {
                    throw 'RunRender callback is not configured.'
                }
                $result = & $callbackMap.RunRender $payload
                return New-AssemblerWebViewResponse -Id $id -Ok $true -Type 'RunRenderResult' -Payload $result
            }
            default {
                throw "Unsupported WebView command: $command"
            }
        }
    }
    catch {
        return New-AssemblerWebViewResponse -Id $id -Ok $false -Type 'Error' -Error $_.Exception.Message
    }
}

Export-ModuleMember -Function @(
    'New-AssemblerWebViewBridgeRoots',
    'Test-AssemblerWebViewAllowedPath',
    'New-AssemblerWebViewResponse',
    'ConvertFrom-AssemblerWebViewMessage',
    'New-AssemblerWebViewMappingStudioState',
    'Invoke-AssemblerWebViewCommand'
)
