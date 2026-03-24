Describe 'Invoke-AssemblerSdtRender selectors helpers' {
    BeforeAll {
        $scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-AssemblerSdtRender.ps1'
        $scriptSource = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
        $functionBlock = [regex]::Match(
            $scriptSource,
            '(?s)function Test-MapHasKey \{.*?^}\s*.*?function Get-EffectiveSelectorsForMapping \{.*?^}\s*.*?function ConvertTo-ObjectArray \{.*?^}',
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        ).Value

        if ([string]::IsNullOrWhiteSpace($functionBlock)) {
            throw 'Failed to load selector helper functions from script under test.'
        }

        Invoke-Expression $functionBlock
    }

    It 'falls back to render hint/default item root when mapping has no selectors key' {
        $mappingEntry = @{
            dataset = 'datasets/host-ports.json'
            sdtTag = 'LNV.Test.Tag'
        }
        $renderHint = @{
            renderAs = 'table'
        }
        $datasetPresentation = @{
            defaultItemRoot = 'rows'
        }

        $selectors = @(Get-EffectiveSelectorsForMapping -MappingEntry $mappingEntry -RenderHint $renderHint -DatasetPresentation $datasetPresentation)

        $selectors | Should -Be @('rows')
    }

    It 'falls back to render hint/default item root when mapping selectors are empty' {
        $mappingEntry = @{
            dataset = 'datasets/host-ports.json'
            sdtTag = 'LNV.Test.Tag'
            selectors = @()
        }
        $renderHint = @{
            renderAs = 'table'
        }
        $datasetPresentation = @{
            defaultItemRoot = 'rows'
        }

        $selectors = @(Get-EffectiveSelectorsForMapping -MappingEntry $mappingEntry -RenderHint $renderHint -DatasetPresentation $datasetPresentation)

        $selectors | Should -Be @('rows')
    }

    It 'prefers populated mapping selectors when present' {
        $mappingEntry = @{
            dataset = 'datasets/host-ports.json'
            sdtTag = 'LNV.Test.Tag'
            selectors = @('items', '0')
        }
        $renderHint = @{
            renderAs = 'table'
        }
        $datasetPresentation = @{
            defaultItemRoot = 'rows'
        }

        $selectors = @(Get-EffectiveSelectorsForMapping -MappingEntry $mappingEntry -RenderHint $renderHint -DatasetPresentation $datasetPresentation)

        $selectors | Should -Be @('items', '0')
    }
}
