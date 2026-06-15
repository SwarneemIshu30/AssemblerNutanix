BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:syncScript = Join-Path $script:repoRoot 'scripts/Sync-AssemblerContractsToRepo.ps1'

    function New-SyncFixture {
        param([string]$Name, [int]$SchemaVersion = 2)

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("assembler-sync-$Name-" + [guid]::NewGuid().ToString('N'))
        $source = Join-Path $root 'source'
        $techRoot = Join-Path $source 'tech/Test.Tech'
        New-Item -ItemType Directory -Path (Join-Path $source 'standards') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $techRoot 'dataset') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:repoRoot '.deps/contracts/standards/mapping.dataset-to-sdt.schema.v1.json') -Destination (Join-Path $source 'standards')
        Copy-Item -LiteralPath (Join-Path $script:repoRoot '.deps/contracts/standards/mapping.dataset-to-sdt.schema.v2.json') -Destination (Join-Path $source 'standards')
        @"
schema: mapping.dataset-to-sdt
schemaVersion: $SchemaVersion
techId: Test.Tech
displayName: Test mapping
compatibility:
  contracts:
    version: 2.0.0
mappings:
  - dataset: systems
    scope: target
    domain: core
    sdtTag: TEST.Systems
    required: true
    selectors:
      - items
    renderHint:
      renderAs: table
      renderMode: table
      projectionRef: TEST.Systems
  - dataset: relationships
    scope: targetGroup
    domain: relationships
    sdtTag: TEST.Relationships
    required: false
"@ | Set-Content -LiteralPath (Join-Path $techRoot 'mapping.dataset-to-sdt.v1.yaml') -Encoding UTF8

        return @{
            Root = $root
            Source = $source
            Deps = Join-Path $root 'deps'
            Mapping = Join-Path $root 'runtime.mapping.json'
        }
    }
}

Describe 'Sync-AssemblerContractsToRepo v2' {
    It 'copies contracts and generates a validated logical mapping' {
        $fixture = New-SyncFixture -Name 'local'
        try {
            & $script:syncScript -ExportContractsPath $fixture.Source -DepsContractsPath $fixture.Deps -TechId 'Test.Tech' -SkeletonMappingOutputPath $fixture.Mapping -StrictEmptyGeneration -Clean | Out-Null
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath (Join-Path $fixture.Deps 'contracts.snapshot.json') | Should -BeTrue
            $mapping = Get-Content -LiteralPath $fixture.Mapping -Raw | ConvertFrom-Json -AsHashtable
            $mapping.schemaVersion | Should -Be 2
            @($mapping.mappings.dataset) | Should -Be @('systems', 'relationships')
            @($mapping.mappings.dataset | Where-Object { $_ -match '[/\\]|__' }).Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts schema-v1 contract mappings and emits schema v2' {
        $fixture = New-SyncFixture -Name 'v1-source' -SchemaVersion 1
        try {
            & $script:syncScript -ExportContractsPath $fixture.Source -DepsContractsPath $fixture.Deps -TechId 'Test.Tech' -SkeletonMappingOutputPath $fixture.Mapping -Clean | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content -LiteralPath $fixture.Mapping -Raw | ConvertFrom-Json).schemaVersion | Should -Be 2
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves scope domain selectors tags and render hints' {
        $fixture = New-SyncFixture -Name 'preservation'
        try {
            & $script:syncScript -ExportContractsPath $fixture.Source -DepsContractsPath $fixture.Deps -TechId 'Test.Tech' -SkeletonMappingOutputPath $fixture.Mapping -Clean | Out-Null
            $entry = (Get-Content -LiteralPath $fixture.Mapping -Raw | ConvertFrom-Json -AsHashtable).mappings[0]
            $entry.scope | Should -Be 'target'
            $entry.domain | Should -Be 'core'
            @($entry.selectors) | Should -Be @('items')
            $entry.sdtTag | Should -Be 'TEST.Systems'
            $entry.required | Should -BeTrue
            $entry.renderHint.projectionRef | Should -Be 'TEST.Systems'
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'auto-discovers technology mappings when no explicit output path is supplied' {
        $fixture = New-SyncFixture -Name 'discovery'
        try {
            & $script:syncScript -ExportContractsPath $fixture.Source -DepsContractsPath $fixture.Deps -Clean | Out-Null
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath (Join-Path $script:repoRoot 'templates/skeletons/Test.Tech/Tech-SDT-Collector.mapping.json') | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath (Join-Path $script:repoRoot 'templates/skeletons/Test.Tech') -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an explicit mapping output without a technology id' {
        $fixture = New-SyncFixture -Name 'invalid'
        try {
            { & $script:syncScript -ExportContractsPath $fixture.Source -DepsContractsPath $fixture.Deps -SkeletonMappingOutputPath $fixture.Mapping -Clean 2>$null | Out-Null } |
                Should -Throw '*SkeletonMappingOutputPath requires TechId*'
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
