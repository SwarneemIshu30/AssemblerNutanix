Describe 'Assembler GUI WebView2 bootstrap module' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:modulePath = Join-Path $script:repoRoot 'gui/internal/AssemblerGuiWebView2.psm1'
        Import-Module $script:modulePath -Force
    }

    It 'resolves a NuGet-restored WebView2 WPF assembly from a package root' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('assembler-webview2-bootstrap-test-' + [guid]::NewGuid().ToString())
        try {
            $assemblyPath = Join-Path $tempRoot 'Microsoft.Web.WebView2/1.0.0/lib/netcoreapp3.0/Microsoft.Web.WebView2.Wpf.dll'
            $loaderPath = Join-Path $tempRoot 'Microsoft.Web.WebView2/1.0.0/runtimes/win-x64/native/WebView2Loader.dll'
            New-Item -ItemType Directory -Path (Split-Path -Parent $assemblyPath) -Force | Out-Null
            New-Item -ItemType Directory -Path (Split-Path -Parent $loaderPath) -Force | Out-Null
            Set-Content -LiteralPath $assemblyPath -Value 'placeholder' -Encoding UTF8
            Set-Content -LiteralPath $loaderPath -Value 'placeholder' -Encoding UTF8

            $resolved = Resolve-AssemblerWebView2AssemblyPath -PackageRoot $tempRoot -PreferredTargetFramework 'netcoreapp3.0'
            if ([string]$resolved -ne $assemblyPath) {
                throw "Expected assembly path '$assemblyPath', got '$resolved'"
            }
            $resolvedLoader = Resolve-AssemblerWebView2LoaderPath -PackageRoot $tempRoot
            if ([string]$resolvedLoader -ne $loaderPath) {
                throw "Expected loader path '$loaderPath', got '$resolvedLoader'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'returns a clear unavailable bootstrap state when the SDK assembly is missing' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('assembler-webview2-missing-test-' + [guid]::NewGuid().ToString())
        try {
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            $status = Get-AssemblerWebView2BootstrapStatus -RepoRoot $script:repoRoot -PackageRoot $tempRoot

            if ([bool]$status.available) {
                throw 'Expected bootstrap status to be unavailable without the WebView2 WPF assembly.'
            }
            if ([string]$status.message -notmatch 'Restore-WebView2Dependency') {
                throw "Expected restore guidance in status message, got '$($status.message)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'prefers stable WebView2 package folders over prerelease folders' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('assembler-webview2-version-test-' + [guid]::NewGuid().ToString())
        try {
            $stableAssembly = Join-Path $tempRoot 'microsoft.web.webview2/1.0.2/lib/net462/Microsoft.Web.WebView2.Wpf.dll'
            $previewAssembly = Join-Path $tempRoot 'microsoft.web.webview2/1.0.3-prerelease/lib/net462/Microsoft.Web.WebView2.Wpf.dll'
            foreach ($path in @($stableAssembly, $previewAssembly)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value 'placeholder' -Encoding UTF8
            }

            $resolved = Resolve-AssemblerWebView2AssemblyPath -PackageRoot $tempRoot -PreferredTargetFramework 'net462'
            if ([string]$resolved -ne $stableAssembly) {
                throw "Expected stable assembly path '$stableAssembly', got '$resolved'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
