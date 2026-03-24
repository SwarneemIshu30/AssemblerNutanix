Describe 'Invoke-AssemblerSdtRender render hint helpers' {
    BeforeAll {
        $scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-AssemblerSdtRender.ps1'
        $scriptSource = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
        $functionBlock = [regex]::Match(
            $scriptSource,
            '(?s)function Test-MapHasKey \{.*?^}\s*.*?function Resolve-PreferredProjectionFromMetadata \{.*?^}\s*.*?function Get-MappingRenderHint \{.*?^}',
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        ).Value

        if ([string]::IsNullOrWhiteSpace($functionBlock)) {
            throw 'Failed to load render hint helper functions from script under test.'
        }

        Invoke-Expression $functionBlock
    }

    It 'returns expected render hints when mapping and presentation are hashtables' {
        $mappingEntry = @{
            renderHint = @{
                projectionRef = 'Projection.From.Mapping'
            }
            renderAs = 'table'
            view = 'MappingView'
        }

        $datasetPresentation = @{
            presentationKind = 'table'
            preferredProjectionViews = @(
                @{
                    name = 'Sample'
                    projectionRef = 'Projection.From.Metadata'
                }
            )
        }

        $hint = Get-MappingRenderHint -MappingEntry $mappingEntry -DatasetPresentation $datasetPresentation -Tag 'tag-with-sample'

        $hint.renderAs | Should -Be 'table'
        $hint.projectionRef | Should -Be 'Projection.From.Mapping'
        $hint.view | Should -Be 'Sample'
    }

    It 'returns expected render hints when mapping and presentation are OrderedDictionary values' {
        $mappingRenderHint = [ordered]@{}
        $mappingRenderHint['projectionRef'] = 'Projection.From.Ordered.Mapping'
        $mappingEntry = [ordered]@{}
        $mappingEntry['renderHint'] = $mappingRenderHint
        $mappingEntry['renderAs'] = 'table'
        $mappingEntry['view'] = 'OrderedMappingView'

        $preferredProjection = [ordered]@{}
        $preferredProjection['name'] = 'Summary'
        $preferredProjection['projectionRef'] = 'Projection.From.Ordered.Metadata'

        $datasetPresentation = [ordered]@{}
        $datasetPresentation['presentationKind'] = 'table'
        $datasetPresentation['preferredProjectionViews'] = @($preferredProjection)

        $hint = Get-MappingRenderHint -MappingEntry $mappingEntry -DatasetPresentation $datasetPresentation -Tag 'tag-summary'

        $hint.renderAs | Should -Be 'table'
        $hint.projectionRef | Should -Be 'Projection.From.Ordered.Mapping'
        $hint.view | Should -Be 'Summary'
    }
}
