[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$PackageRoot,
    [Parameter(Mandatory = $false)][string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Join-Path $repoRoot '.deps/nuget'
}

New-Item -ItemType Directory -Path $PackageRoot -Force | Out-Null

$packageId = 'microsoft.web.webview2'
$baseUri = "https://api.nuget.org/v3-flatcontainer/$packageId"
if ([string]::IsNullOrWhiteSpace($Version)) {
    $index = Invoke-RestMethod -Uri "$baseUri/index.json"
    $stableVersions = @($index.versions | Where-Object { [string]$_ -notmatch '-' })
    if ($stableVersions.Count -gt 0) {
        $Version = [string]$stableVersions[-1]
    }
    else {
        $Version = [string]@($index.versions)[-1]
    }
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw 'Unable to determine a Microsoft.Web.WebView2 package version from NuGet.'
}

$packageDirectory = Join-Path (Join-Path $PackageRoot $packageId) $Version
$assemblyProbe = Join-Path $packageDirectory 'lib'
if (-not (Test-Path -LiteralPath $assemblyProbe -PathType Container)) {
    $tempPackage = Join-Path ([System.IO.Path]::GetTempPath()) ("$packageId.$Version.nupkg")
    Invoke-WebRequest -Uri "$baseUri/$Version/$packageId.$Version.nupkg" -OutFile $tempPackage
    if (Test-Path -LiteralPath $packageDirectory -PathType Container) {
        Remove-Item -LiteralPath $packageDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $tempPackage -DestinationPath $packageDirectory -Force
    Remove-Item -LiteralPath $tempPackage -Force
}

$targetFramework = if ($PSVersionTable.PSEdition -eq 'Core') { 'netcoreapp3.0' } else { 'net462' }
$assembly = Get-ChildItem -LiteralPath $packageDirectory -Recurse -Filter 'Microsoft.Web.WebView2.Wpf.dll' -File |
    Where-Object { $_.FullName -match "\\lib\\$([regex]::Escape($targetFramework))\\Microsoft\.Web\.WebView2\.Wpf\.dll$" } |
    Sort-Object -Property FullName -Descending |
    Select-Object -First 1
if ($null -eq $assembly) {
    $assembly = Get-ChildItem -LiteralPath $packageDirectory -Recurse -Filter 'Microsoft.Web.WebView2.Wpf.dll' -File |
        Sort-Object -Property FullName -Descending |
        Select-Object -First 1
}

$arch = if ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' }
$loader = Get-ChildItem -LiteralPath $packageDirectory -Recurse -Filter 'WebView2Loader.dll' -File |
    Where-Object { $_.FullName -match "\\runtimes\\$arch\\native\\WebView2Loader\.dll$" } |
    Sort-Object -Property FullName -Descending |
    Select-Object -First 1
if ($null -eq $loader) {
    $loader = Get-ChildItem -LiteralPath $packageDirectory -Recurse -Filter 'WebView2Loader.dll' -File |
        Sort-Object -Property FullName -Descending |
        Select-Object -First 1
}

if ($null -eq $assembly) {
    throw "Microsoft.Web.WebView2 package restored, but Microsoft.Web.WebView2.Wpf.dll was not found under '$PackageRoot'."
}
if ($null -eq $loader) {
    throw "Microsoft.Web.WebView2 package restored, but WebView2Loader.dll was not found under '$PackageRoot'."
}

[ordered]@{
    packageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
    assemblyPath = [string]$assembly.FullName
    loaderPath = [string]$loader.FullName
} | ConvertTo-Json -Depth 5
