Set-StrictMode -Version Latest

$script:DefaultWebView2PackageRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.deps/nuget'

function Get-AssemblerWebView2PackageRoot {
    param([Parameter(Mandatory = $false)][string]$RepoRoot)

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        return $script:DefaultWebView2PackageRoot
    }

    return (Join-Path $RepoRoot '.deps/nuget')
}

function Select-PreferredWebView2Candidate {
    param([Parameter(Mandatory = $true)]$Candidates)

    $ranked = foreach ($candidate in @($Candidates)) {
        $versionText = '0.0'
        if ([string]$candidate.FullName -match 'microsoft\.web\.webview2[\\/](?<version>[^\\/]+)[\\/]') {
            $versionText = [string]$Matches.version
        }
        $stable = if ($versionText -match '-') { 0 } else { 1 }
        $versionCore = $versionText -replace '-.*$', ''
        try {
            $version = [version]$versionCore
        }
        catch {
            $version = [version]'0.0'
        }

        [pscustomobject]@{
            Candidate = $candidate
            Stable = $stable
            Version = $version
            FullName = [string]$candidate.FullName
        }
    }

    return ($ranked | Sort-Object -Property @{ Expression = 'Stable'; Descending = $true }, @{ Expression = 'Version'; Descending = $true }, @{ Expression = 'FullName'; Descending = $true } | Select-Object -First 1).Candidate
}

function Resolve-AssemblerWebView2AssemblyPath {
    param(
        [Parameter(Mandatory = $false)][string]$PackageRoot,
        [Parameter(Mandatory = $false)][string]$PreferredTargetFramework
    )

    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        $PackageRoot = $script:DefaultWebView2PackageRoot
    }
    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($PreferredTargetFramework)) {
        $PreferredTargetFramework = if ($PSVersionTable.PSEdition -eq 'Core') { 'netcoreapp3.0' } else { 'net462' }
    }

    $candidates = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Filter 'Microsoft.Web.WebView2.Wpf.dll' -File -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        return $null
    }

    $preferred = @($candidates | Where-Object {
            $_.FullName -match "\\lib\\$([regex]::Escape($PreferredTargetFramework))\\Microsoft\.Web\.WebView2\.Wpf\.dll$"
        })
    if ($preferred.Count -gt 0) {
        return [string](Select-PreferredWebView2Candidate -Candidates $preferred).FullName
    }

    $fallback = @($candidates | Where-Object {
            $_.FullName -match '\\lib\\(netcoreapp3\.0|net462|net45)\\Microsoft\.Web\.WebView2\.Wpf\.dll$'
        })
    if ($fallback.Count -gt 0) {
        return [string](Select-PreferredWebView2Candidate -Candidates $fallback).FullName
    }

    return [string](Select-PreferredWebView2Candidate -Candidates $candidates).FullName
}

function Resolve-AssemblerWebView2LoaderPath {
    param([Parameter(Mandatory = $false)][string]$PackageRoot)

    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        $PackageRoot = $script:DefaultWebView2PackageRoot
    }
    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        return $null
    }

    $arch = if ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' }
    $preferred = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Filter 'WebView2Loader.dll' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\runtimes\\$arch\\native\\WebView2Loader\.dll$" })
    if ($preferred.Count -gt 0) {
        return [string](Select-PreferredWebView2Candidate -Candidates $preferred).FullName
    }

    $fallback = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Filter 'WebView2Loader.dll' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property FullName -Descending)
    if ($fallback.Count -gt 0) {
        return [string](Select-PreferredWebView2Candidate -Candidates $fallback).FullName
    }

    return $null
}

function Test-AssemblerWebView2RuntimeAvailable {
    $programRoots = @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles,
        $env:LOCALAPPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $programRoots) {
        $runtimeRoot = Join-Path $root 'Microsoft/EdgeWebView/Application'
        if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
            $runtimeExe = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -Filter 'msedgewebview2.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($runtimeExe.Count -gt 0) {
                return $true
            }
        }
    }

    return $false
}

function Get-AssemblerWebView2BootstrapStatus {
    param(
        [Parameter(Mandatory = $false)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$PackageRoot
    )

    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        $PackageRoot = Get-AssemblerWebView2PackageRoot -RepoRoot $RepoRoot
    }

    $assemblyPath = Resolve-AssemblerWebView2AssemblyPath -PackageRoot $PackageRoot
    $loaderPath = Resolve-AssemblerWebView2LoaderPath -PackageRoot $PackageRoot
    $runtimeAvailable = Test-AssemblerWebView2RuntimeAvailable
    $assemblyAvailable = -not [string]::IsNullOrWhiteSpace($assemblyPath)
    $loaderAvailable = -not [string]::IsNullOrWhiteSpace($loaderPath)

    $message = if (-not $assemblyAvailable) {
        "Microsoft.Web.WebView2.Wpf.dll was not found under '$PackageRoot'. Run scripts/Restore-WebView2Dependency.ps1."
    }
    elseif (-not $loaderAvailable) {
        "WebView2Loader.dll was not found under '$PackageRoot'. Run scripts/Restore-WebView2Dependency.ps1."
    }
    elseif (-not $runtimeAvailable) {
        'WebView2 SDK assembly is available, but the Microsoft Edge WebView2 Runtime was not detected.'
    }
    else {
        'WebView2 SDK assembly and runtime are available.'
    }

    [ordered]@{
        available = ($assemblyAvailable -and $loaderAvailable -and $runtimeAvailable)
        assemblyAvailable = $assemblyAvailable
        loaderAvailable = $loaderAvailable
        runtimeAvailable = $runtimeAvailable
        assemblyPath = $assemblyPath
        loaderPath = $loaderPath
        packageRoot = $PackageRoot
        message = $message
    }
}

Export-ModuleMember -Function @(
    'Get-AssemblerWebView2PackageRoot',
    'Resolve-AssemblerWebView2AssemblyPath',
    'Resolve-AssemblerWebView2LoaderPath',
    'Test-AssemblerWebView2RuntimeAvailable',
    'Get-AssemblerWebView2BootstrapStatus'
)
