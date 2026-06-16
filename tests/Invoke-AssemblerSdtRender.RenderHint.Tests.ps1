Describe 'Invoke-AssemblerSdtRender render hint helpers' {
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
                'Resolve-PreferredProjectionFromMetadata',
                'Get-MappingRenderHint',
                'Get-EffectiveRenderMode',
                'Get-ProjectionDefinitionForMapping',
                'Get-ProjectionDefinitionForTag'
            )) {
                if (-not $functionsByName.ContainsKey($functionName)) {
                    throw "Failed to load helper function '$functionName' from script under test."
                }
                $functionsByName[$functionName]
            }
        ) -join "`n`n"

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

    It 'lets explicit render hints override projection fragments and uses projection mode as fallback' {
        $renderHint = [ordered]@{}
        $renderHint['renderMode'] = 'json-evidence'

        $projection = [ordered]@{}
        $projection['renderMode'] = 'table'

        (Get-EffectiveRenderMode -RenderHint $renderHint -ProjectionDefinition $projection -Tag 'Sample.Tag') | Should -Be 'json-evidence'
        (Get-EffectiveRenderMode -RenderHint $null -ProjectionDefinition $projection -Tag 'Sample.Tag') | Should -Be 'table'
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
