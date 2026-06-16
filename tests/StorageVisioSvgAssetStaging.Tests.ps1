Describe 'Storage Visio SVG asset staging' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Build-StorageVisioSvgAssetStaging.ps1'
        $script:generatedRoot = Join-Path $script:repoRoot '.diagramKB/generated/storage-visio-svg'

        function New-StorageSvgExportFixture {
            param(
                [Parameter(Mandatory = $true)][string]$Root
            )

            foreach ($family in @('DE','DM','DG','DS')) {
                $familyRoot = Join-Path $Root $family
                $null = New-Item -Path $familyRoot -ItemType Directory -Force

                $generatedIndex = Join-Path $script:generatedRoot (Join-Path $family ("_visio-master-export-index-$($family.ToLowerInvariant()).csv"))
                Copy-Item -LiteralPath $generatedIndex -Destination (Join-Path $familyRoot '_visio-master-export-index.csv') -Force

                foreach ($row in @(Import-Csv -LiteralPath $generatedIndex)) {
                    if ([string]::IsNullOrWhiteSpace([string]$row.AssetFile) -or [string]$row.AssetFile -notmatch '\.svg$') { continue }
                    $svgPath = Join-Path $familyRoot ([string]$row.AssetFile)
                    if (-not (Test-Path -LiteralPath $svgPath -PathType Leaf)) {
                        Set-Content -LiteralPath $svgPath -Encoding UTF8 -Value '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"></svg>'
                    }
                }
            }
        }
    }

    It 'generates manifests for every storage family without rerunning Visio' {
        $exportRoot = Join-Path $TestDrive 'exports'
        $outputRoot = Join-Path $TestDrive 'generated'
        New-StorageSvgExportFixture -Root $exportRoot

        $json = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$script:scriptPath' -Families @('DE','DM','DG','DS') -ExportRoot '$($exportRoot.Replace("'", "''"))' -OutputRoot '$($outputRoot.Replace("'", "''"))'"
        $result = $json | ConvertFrom-Json

        @($result).Count | Should -Be 4
        foreach ($family in @('DE','DM','DG','DS')) {
            $familyResult = @($result | Where-Object { $_.Family -eq $family }) | Select-Object -First 1
            $familyResult | Should -Not -BeNullOrEmpty
            $familyResult.SvgCount | Should -BeGreaterThan 0
            Test-Path -LiteralPath ([string]$familyResult.Manifest) -PathType Leaf | Should -BeTrue
        }

        $scriptSource = Get-Content -LiteralPath $script:scriptPath -Raw -Encoding UTF8
        $scriptSource | Should -Not -Match 'Visio\.Application'
        $scriptSource | Should -Not -Match 'New-Object\s+-ComObject\s+Visio'
    }

    It 'keeps family manifests routed to the correct technology ownership' {
        $deManifest = Get-Content -LiteralPath (Join-Path $script:generatedRoot 'DE/lenovo-de-asset-manifest.yaml') -Raw -Encoding UTF8
        $dmManifest = Get-Content -LiteralPath (Join-Path $script:generatedRoot 'DM/netapp-ontap-dm-asset-manifest.yaml') -Raw -Encoding UTF8
        $dgManifest = Get-Content -LiteralPath (Join-Path $script:generatedRoot 'DG/netapp-ontap-dg-asset-manifest.yaml') -Raw -Encoding UTF8
        $dsManifest = Get-Content -LiteralPath (Join-Path $script:generatedRoot 'DS/netapp-ontap-ds-asset-manifest.yaml') -Raw -Encoding UTF8

        $deManifest | Should -Match 'technology: "Lenovo.DE"'
        $dmManifest | Should -Match 'technology: "NetApp.ONTAP"'
        $dgManifest | Should -Match 'technology: "NetApp.ONTAP"'
        $dsManifest | Should -Match 'technology: "NetApp.ONTAP"'
    }

    It 'does not reference raw EMF files or allow components and unknowns as primary assets' {
        foreach ($manifestPath in @(Get-ChildItem -LiteralPath $script:generatedRoot -Recurse -Filter '*asset-manifest.yaml')) {
            $lines = @(Get-Content -LiteralPath $manifestPath.FullName -Encoding UTF8)
            ($lines -join "`n") | Should -Not -Match '\.emf'
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match 'assetType: "component"') {
                    (@($lines[$index..([Math]::Min($index + 10, $lines.Count - 1))]) -join "`n") | Should -Not -Match 'canBePrimaryProductAsset: true'
                }
                if ($lines[$index] -match 'assetType: "unknown"') {
                    (@($lines[$index..([Math]::Min($index + 10, $lines.Count - 1))]) -join "`n") | Should -Not -Match 'needsReview: false'
                }
            }
        }
    }

    It 'contains branch safety checks for protected target branches' {
        $scriptSource = Get-Content -LiteralPath $script:scriptPath -Raw -Encoding UTF8

        $scriptSource | Should -Match 'protectedBranches'
        $scriptSource | Should -Match 'assets/diagrams'
        $scriptSource | Should -Match 'Refusing to stage'
    }
}
