BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:syncScript = Join-Path $script:repoRoot 'scripts/Sync-AssemblerContractsToRepo.ps1'
}

Describe 'Assembler contract sync v2 output' {
    It 'generates a logical schema-v2 runtime mapping from a schema-v1 contract mapping' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-sync-v2-" + [guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $tempRoot 'source'
        $depsRoot = Join-Path $tempRoot 'deps'
        $mappingPath = Join-Path $tempRoot 'runtime.mapping.json'
        try {
            New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'standards') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'tech/Test.Tech/dataset') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:repoRoot '.deps/contracts/standards/mapping.dataset-to-sdt.schema.v1.json') -Destination (Join-Path $sourceRoot 'standards')
            Copy-Item -LiteralPath (Join-Path $script:repoRoot '.deps/contracts/standards/mapping.dataset-to-sdt.schema.v2.json') -Destination (Join-Path $sourceRoot 'standards')
            @'
schema: mapping.dataset-to-sdt
schemaVersion: 1
techId: Test.Tech
displayName: Test mapping
compatibility:
  contracts:
    version: 2.0.0
mappings:
  - dataset: relationships
    scope: targetGroup
    domain: relationships
    sdtTag: TEST.Relationships
    required: true
    selectors:
      - items
    renderHint:
      renderAs: table
      renderMode: table
      projectionRef: TEST.Relationships
'@ | Set-Content -LiteralPath (Join-Path $sourceRoot 'tech/Test.Tech/mapping.dataset-to-sdt.v1.yaml') -Encoding UTF8

            & $script:syncScript -ExportContractsPath $sourceRoot -DepsContractsPath $depsRoot -TechId 'Test.Tech' -SkeletonMappingOutputPath $mappingPath -StrictEmptyGeneration -Clean | Out-Null
            $LASTEXITCODE | Should -Be 0
            $mapping = Get-Content -LiteralPath $mappingPath -Raw | ConvertFrom-Json -AsHashtable
            $mapping.schemaVersion | Should -Be 2
            $mapping.mappings[0].dataset | Should -Be 'relationships'
            $mapping.mappings[0].scope | Should -Be 'targetGroup'
            $mapping.mappings[0].domain | Should -Be 'relationships'
            @($mapping.mappings[0].selectors) | Should -Be @('items')
            $mapping.mappings[0].dataset | Should -Not -Match '[/\\]|__'
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves logical filters from a schema-v2 contract mapping' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-sync-v2-source-" + [guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $tempRoot 'source'
        $depsRoot = Join-Path $tempRoot 'deps'
        $mappingPath = Join-Path $tempRoot 'runtime.mapping.json'
        try {
            New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'standards') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'tech/Test.Tech/dataset') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:repoRoot '.deps/contracts/standards/mapping.dataset-to-sdt.schema.v2.json') -Destination (Join-Path $sourceRoot 'standards')
            @'
schema: mapping.dataset-to-sdt
schemaVersion: 2
techId: Test.Tech
displayName: Test mapping v2
compatibility:
  contracts:
    version: 2.0.0
mappings:
  - dataset: relationships
    scope: targetGroup
    domain: group
    sdtTag: TEST.GroupRelationships
    required: false
'@ | Set-Content -LiteralPath (Join-Path $sourceRoot 'tech/Test.Tech/mapping.dataset-to-sdt.v1.yaml') -Encoding UTF8

            & $script:syncScript -ExportContractsPath $sourceRoot -DepsContractsPath $depsRoot -TechId 'Test.Tech' -SkeletonMappingOutputPath $mappingPath -Clean | Out-Null
            $LASTEXITCODE | Should -Be 0
            $mapping = Get-Content -LiteralPath $mappingPath -Raw | ConvertFrom-Json -AsHashtable
            $mapping.schemaVersion | Should -Be 2
            $mapping.mappings[0].dataset | Should -Be 'relationships'
            $mapping.mappings[0].scope | Should -Be 'targetGroup'
            $mapping.mappings[0].domain | Should -Be 'group'
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
