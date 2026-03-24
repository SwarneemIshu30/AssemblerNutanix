Describe 'Invoke-AssemblerSdtRender render hint helpers' {
    BeforeAll {
        $scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-AssemblerSdtRender.ps1'
        $scriptSource = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
        $functionBlock = [regex]::Match(
            $scriptSource,
            '(?s)function Test-MapHasKey \{.*?^}\s*.*?function Resolve-PreferredProjectionFromMetadata \{.*?^}\s*.*?function Get-MappingRenderHint \{.*?^}\s*.*?function Get-EffectiveRenderMode \{.*?^}\s*.*?function Get-ProjectionDefinitionForMapping \{.*?^}\s*.*?function Get-ProjectionDefinitionForTag \{.*?^}',
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

    It 'resolves render mode from OrderedDictionary render hints and projection fragments' {
        $renderHint = [ordered]@{}
        $renderHint['renderAs'] = 'table'

        $projection = [ordered]@{}
        $projection['renderMode'] = 'json-evidence'

        (Get-EffectiveRenderMode -RenderHint $renderHint -ProjectionDefinition $projection -Tag 'Sample.Tag') | Should -Be 'json-evidence'
        (Get-EffectiveRenderMode -RenderHint $renderHint -ProjectionDefinition $null -Tag 'Sample.Tag') | Should -Be 'table'
    }

    It 'resolves projection definitions from Hashtable and OrderedDictionary inputs' {
        $projectionTag = 'Projection.Ref.Sample'

        $projectionFragment = [ordered]@{}
        $projectionFragment['renderMode'] = 'table'

        $projectionDefinitions = [ordered]@{}
        $projectionDefinitions[$projectionTag] = $projectionFragment

        $projectionAliases = @{ 'Alias.Sample' = $projectionTag }

        $renderHint = @{ projectionRef = $projectionTag }
        $resolved = Get-ProjectionDefinitionForMapping -Tag 'Fallback.Tag' -RenderHint $renderHint -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases
        $resolved['renderMode'] | Should -Be 'table'

        $renderHintOrdered = [ordered]@{}
        $renderHintOrdered['view'] = 'Alias.Sample'
        $resolvedByAlias = Get-ProjectionDefinitionForMapping -Tag 'Fallback.Tag' -RenderHint $renderHintOrdered -ProjectionDefinitions $projectionDefinitions -ProjectionAliases $projectionAliases
        $resolvedByAlias['renderMode'] | Should -Be 'table'
    }
}
