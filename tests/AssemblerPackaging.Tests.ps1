Describe 'Assembler package include manifest' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:includePath = Join-Path $script:repoRoot '.packaging/assembler-package.include'
    }

    It 'includes wrapper and GUI assets needed by the refactored WPF flow' {
        $includeText = Get-Content -LiteralPath $script:includePath -Raw -Encoding UTF8
        foreach ($expected in @(
            'scripts/Invoke-LnvAssemblerRender.ps1',
            'scripts/Restore-WebView2Dependency.ps1',
            'scripts/internal',
            'gui'
        )) {
            if ($includeText -notmatch [regex]::Escape($expected)) {
                throw "Expected package include manifest to contain '$expected'."
            }
        }
    }
}
