Describe 'Invoke-AssemblerSdtRender selectors helpers' {
    BeforeAll {
        $scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-AssemblerSdtRender.ps1'
        $tokens = $null
        $parseErrors = $null
        $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptUnderTest, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) {
            throw "Failed to parse renderer script under test: $($parseErrors[0].Message)"
        }

        $functionsByName = @{}
        foreach ($functionAst in @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $functionsByName[[string]$functionAst.Name] = $functionAst.Extent.Text
        }

        $functionBlock = @(
            foreach ($functionName in @(
                'Test-MapHasKey',
                'ConvertTo-ObjectArray',
                'Get-EffectiveSelectorsForMapping'
            )) {
                if (-not $functionsByName.ContainsKey($functionName)) {
                    throw "Failed to load helper function '$functionName' from script under test."
                }
                $functionsByName[$functionName]
            }
        ) -join "`n`n"

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

    It 'supports OrderedDictionary mapping entries, render hints, and dataset presentation' {
        $mappingEntry = [ordered]@{}
        $mappingEntry['dataset'] = 'datasets/host-ports.json'
        $mappingEntry['sdtTag'] = 'LNV.Test.Tag'
        $mappingEntry['selectors'] = @()

        $renderHint = [ordered]@{}
        $renderHint['projectionRef'] = 'LNV.Test.Projection'

        $datasetPresentation = [ordered]@{}
        $datasetPresentation['defaultItemRoot'] = 'rows'

        $selectors = @(Get-EffectiveSelectorsForMapping -MappingEntry $mappingEntry -RenderHint $renderHint -DatasetPresentation $datasetPresentation)

        $selectors | Should -Be @('rows')
    }
}
