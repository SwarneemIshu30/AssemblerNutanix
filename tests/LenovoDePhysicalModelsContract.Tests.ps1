Describe 'Lenovo.DE physical model contract mirror' {
    It 'keeps runtime and export physical model lookup contracts aligned' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $runtimePath = Join-Path $repoRoot '.deps/contracts/tech/Lenovo.DE/physical-models.v1.json'
        $exportPath = Join-Path $repoRoot 'exports/LNV.AsBuiltDoc.Contracts/tech/Lenovo.DE/physical-models.v1.json'

        Test-Path -LiteralPath $runtimePath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $exportPath -PathType Leaf | Should -BeTrue

        $runtime = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8
        $export = Get-Content -LiteralPath $exportPath -Raw -Encoding UTF8
        $export | Should -Be $runtime
    }

    It 'includes the discovered DE4200H 2U24 MT mapping' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $runtimePath = Join-Path $repoRoot '.deps/contracts/tech/Lenovo.DE/physical-models.v1.json'
        $contract = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $model = @($contract.items | Where-Object { $_.mtPrefix -eq '7DCQ' }) | Select-Object -First 1

        $model | Should -Not -BeNullOrEmpty
        $model.displayName | Should -Be 'DE4200H 2U24'
        $model.visualAssetKey | Should -Be 'de4200h-2u24'
        $model.modelFamily | Should -Be 'DE4200'
        $model.modelSuffix | Should -Be 'H'
        $model.enclosure | Should -Be '2U24'
    }
}
