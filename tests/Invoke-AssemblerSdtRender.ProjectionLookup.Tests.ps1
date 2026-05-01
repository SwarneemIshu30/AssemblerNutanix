Describe 'Invoke-AssemblerSdtRender projection lookup helpers' {
    BeforeAll {
        $scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-AssemblerSdtRender.ps1'
        $scriptSource = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
        $functionBlock = [regex]::Match(
            $scriptSource,
            '(?s)function ConvertTo-ProjectionLookupKey \{.*?^}',
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        ).Value

        if ([string]::IsNullOrWhiteSpace($functionBlock)) {
            throw 'Failed to load projection lookup helper functions from script under test.'
        }

        Invoke-Expression $functionBlock
    }

    It 'normalizes Lenovo MT prefixes from full and padded part numbers' {
        (ConvertTo-ProjectionLookupKey -Value '7DCQCTO1WW' -Transform 'mtPrefix4') | Should -Be '7DCQ'
        (ConvertTo-ProjectionLookupKey -Value '7DCQCTO1WW     ' -Transform 'mtPrefix4') | Should -Be '7DCQ'
    }

    It 'does not throw for null, empty, or short part numbers' {
        { ConvertTo-ProjectionLookupKey -Value $null -Transform 'mtPrefix4' } | Should -Not -Throw
        { ConvertTo-ProjectionLookupKey -Value '' -Transform 'mtPrefix4' } | Should -Not -Throw
        { ConvertTo-ProjectionLookupKey -Value '7Y6' -Transform 'mtPrefix4' } | Should -Not -Throw
        ConvertTo-ProjectionLookupKey -Value $null -Transform 'mtPrefix4' | Should -Be $null
        ConvertTo-ProjectionLookupKey -Value '7Y6' -Transform 'mtPrefix4' | Should -Be '7Y6'
    }
}
