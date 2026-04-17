Describe 'Start-AssemblerGui Mapping Studio module' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'gui/internal/AssemblerGuiMappingStudio.psm1'
    $catalogPath = Join-Path $repoRoot 'templates/skeletons/Lenovo.DE/DE-SDT-Collector.catalog.json'
    $contractsRoot = Join-Path $repoRoot '.deps/contracts'
    $bundleRoot = Join-Path $repoRoot 'bundle'

    function New-DeterministicTempRoot {
        param([Parameter(Mandatory = $true)][string]$Name)

        $root = Join-Path ([System.IO.Path]::GetTempPath()) (Join-Path 'assembler-mapping-studio-tests' $Name)
        if (Test-Path -LiteralPath $root -PathType Container) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }

        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function Get-LenovoWorkbench {
        param(
            [string]$ResolvedRepoRoot = $repoRoot,
            [string]$ResolvedCatalogPath = $catalogPath,
            [string]$ResolvedContractsRoot = $contractsRoot,
            [string]$ResolvedBundleRoot = $bundleRoot
        )

        $collection = Get-TemplateCollections -CatalogPath $ResolvedCatalogPath | Select-Object -First 1
        if ($null -eq $collection) {
            throw "Expected at least one mapping collection at '$ResolvedCatalogPath'"
        }

        return (Get-MappingStudioWorkbench -RepoRoot $ResolvedRepoRoot -BundleRoot $ResolvedBundleRoot -ContractsRoot $ResolvedContractsRoot -Collection $collection)
    }

    function New-TestContractDocument {
        param([switch]$IncludeDuplicateManagementTarget)

        $mappings = [System.Collections.Generic.List[object]]::new()
        $mappings.Add([ordered]@{
                dataset = 'systems'
                sdtTag = 'LNV.Lenovo.DE.System[<SystemId>].Narrative.Config'
                required = $false
                selectors = @('items.0.model')
                target = [ordered]@{
                    kind = 'sdt'
                    path = 'LNV.Lenovo.DE.System[<SystemId>].Narrative.Config'
                }
                renderHint = [ordered]@{
                    renderAs = 'scalar'
                    view = 'Config'
                }
            }) | Out-Null
        $mappings.Add([ordered]@{
                dataset = 'management-interfaces'
                sdtTag = 'LNV.Lenovo.DE.System[<SystemId>].Tables.ManagementInterfaces'
                required = $true
                selectors = @('items')
                target = [ordered]@{
                    kind = 'sdt'
                    path = 'LNV.Lenovo.DE.System[<SystemId>].Tables.ManagementInterfaces'
                }
                renderHint = [ordered]@{
                    renderAs = 'table'
                    projectionRef = 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces'
                }
            }) | Out-Null
        if ($IncludeDuplicateManagementTarget) {
            $mappings.Add([ordered]@{
                    dataset = 'transport'
                    sdtTag = 'LNV.Lenovo.DE.System[<SystemId>].Tables.ManagementInterfaces'
                    required = $false
                    selectors = @('items')
                    target = [ordered]@{
                        kind = 'sdt'
                        path = 'LNV.Lenovo.DE.System[<SystemId>].Tables.ManagementInterfaces'
                    }
                    renderHint = [ordered]@{
                        renderAs = 'table'
                        projectionRef = 'LNV.Lenovo.DE.System[ArrayName].Tables.Transport'
                    }
                }) | Out-Null
        }

        return [ordered]@{
            schema = 'mapping.dataset-to-sdt'
            schemaVersion = 1
            techId = 'Lenovo.DE'
            displayName = 'Lenovo DE Mapping Studio test contract'
            syncPolicy = [ordered]@{
                collectorSkeletonMapping = [ordered]@{
                    allowedRenderAs = @('table', 'scalar')
                    selectors = [ordered]@{
                        defaultByRenderAs = [ordered]@{
                            table = @('items')
                            scalar = @('items.0')
                        }
                    }
                    unsupportedRenderShape = [ordered]@{
                        documentFacing = 'fail'
                        nonDocumentFacing = 'skip'
                    }
                }
            }
            collectorSdtTagPolicy = [ordered]@{
                required = $true
                tokenRewrites = [ordered]@{
                    '[<SystemId>]' = '[ArrayName]'
                }
                tagAliases = [ordered]@{
                    'LNV.Lenovo.DE.System[ArrayName].Tables.Drives' = 'LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory'
                    'LNV.Lenovo.DE.System[ArrayName].Tables.StorageContainers' = 'LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory'
                }
            }
            mappings = @($mappings)
        }
    }

    function New-MappingStudioTempRepo {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [switch]$UseJsonYamlContract,
            [switch]$IncludeDuplicateManagementTarget,
            [switch]$RemoveTokenAudit,
            [switch]$RemoveHeadingMap,
            [switch]$BreakSystemsExamplePath
        )

        $tempRoot = New-DeterministicTempRoot -Name $Name
        $skeletonDestination = Join-Path $tempRoot 'templates/skeletons/Lenovo.DE'
        $contractsDestination = Join-Path $tempRoot '.deps/contracts/tech/Lenovo.DE'
        $exportDestination = Join-Path $tempRoot 'exports/LNV.AsBuiltDoc.Contracts/tech/Lenovo.DE'

        Copy-Item -LiteralPath (Join-Path $repoRoot 'templates/skeletons/Lenovo.DE') -Destination $skeletonDestination -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot '.deps/contracts/tech/Lenovo.DE') -Destination $contractsDestination -Recurse -Force
        New-Item -ItemType Directory -Path $exportDestination -Force | Out-Null

        $tokenAuditPath = Join-Path $skeletonDestination 'DE-SDT-Collector.token-audit.md'
        $headingMapPath = Join-Path $skeletonDestination 'SK_Lenovo_DE_DRAFT_v0.1.heading-tag-map.md'
        if ($RemoveTokenAudit -and (Test-Path -LiteralPath $tokenAuditPath -PathType Leaf)) {
            Remove-Item -LiteralPath $tokenAuditPath -Force
        }
        if ($RemoveHeadingMap -and (Test-Path -LiteralPath $headingMapPath -PathType Leaf)) {
            Remove-Item -LiteralPath $headingMapPath -Force
        }

        if ($BreakSystemsExamplePath) {
            $systemsMetadataPath = Join-Path $contractsDestination 'dataset/systems.assembler.meta.json'
            $systemsMetadata = Get-Content -LiteralPath $systemsMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $systemsMetadata.datasetPath.template = 'datasets/__TECH_ID__/missing/__DATASET__.json'
            $systemsMetadata | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $systemsMetadataPath -Encoding UTF8
        }

        $contractPath = Join-Path $contractsDestination 'mapping.dataset-to-sdt.v1.yaml'
        if ($UseJsonYamlContract) {
            $contractDocument = New-TestContractDocument -IncludeDuplicateManagementTarget:$IncludeDuplicateManagementTarget
            $contractDocument | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $contractPath -Encoding UTF8
        }

        return [ordered]@{
            RepoRoot = $tempRoot
            CatalogPath = Join-Path $skeletonDestination 'DE-SDT-Collector.catalog.json'
            ContractsRoot = Join-Path $tempRoot '.deps/contracts'
            BundleRoot = $bundleRoot
            ContractPath = $contractPath
            ExportMirrorPath = Join-Path $exportDestination 'mapping.dataset-to-sdt.v1.yaml'
            ProjectionContractPath = Join-Path $contractsDestination 'assembler.projections.v1.json'
            ProjectionExportMirrorPath = Join-Path $exportDestination 'assembler.projections.v1.json'
            RuntimeMappingPath = Join-Path $skeletonDestination 'DE-SDT-Collector.mapping.json'
            TokenAuditPath = $tokenAuditPath
            HeadingMapPath = $headingMapPath
        }
    }

    Import-Module $modulePath -Force

    It 'discovers template collections and prefers the DOCX variant first' {
        $collections = @(Get-TemplateCollections -CatalogPath $catalogPath)
        if ($collections.Count -lt 2) {
            throw "Expected multiple template collections, got $($collections.Count)"
        }
        if ([string]$collections[0].OutputType -ne 'docx') {
            throw "Expected the first collection to prefer DOCX output, got '$($collections[0].OutputType)'"
        }
        if ([string]$collections[0].Id -ne 'lenovo-de-collector-summary-docx') {
            throw "Expected the Lenovo.DE DOCX collection first, got '$($collections[0].Id)'"
        }
    }

    It 'avoids unsafe first-item indexing in the Mapping Studio connector editor defaults' {
        $wpfScriptPath = Join-Path $repoRoot 'gui/Start-AssemblerGui.Wpf.ps1'
        $wpfScriptText = Get-Content -LiteralPath $wpfScriptPath -Raw -Encoding UTF8

        if ($wpfScriptText -match '@\(\$targetNode\.Mappings \| Select-Object -First 1\)\[0\]') {
            throw 'Expected connector editor to avoid direct [0] indexing when target mappings can be empty'
        }
        if ($wpfScriptText -match '@\(\$projectionCandidates \| Select-Object -First 1\)\[0\]') {
            throw 'Expected connector editor to avoid direct [0] indexing when projection candidates can be empty'
        }
        if ($wpfScriptText -match '@\(\$mappingStudioState\.DraftProjection(Columns|Filter|RowOrder).*\)\[0\]') {
            throw 'Expected projection draft selection helpers to avoid direct [0] indexing when editor lists can be empty'
        }
        if ($wpfScriptText -match '\(if \(\$null -ne \$selectedConnection\)') {
            throw 'Expected connector editor to avoid inline (if ...) expressions in selection-change code paths'
        }
        if ($wpfScriptText -match '\$connectorDatasetList\.SelectedItem\s*=\s*\$ConnectionRow\.DatasetNode') {
            throw 'Expected edit-mode selection to resolve connector dataset items through the live ItemsSource rather than direct ConnectionRow object assignment'
        }
        if ($wpfScriptText -match '\$connectorTargetList\.SelectedItem\s*=\s*\$ConnectionRow\.TargetNode') {
            throw 'Expected edit-mode selection to resolve connector target items through the live ItemsSource rather than direct ConnectionRow object assignment'
        }
    }

    It 'embeds a decodable brand logo payload in the WPF launcher' {
        $wpfScriptPath = Join-Path $repoRoot 'gui/Start-AssemblerGui.Wpf.ps1'
        $wpfScriptText = Get-Content -LiteralPath $wpfScriptPath -Raw -Encoding UTF8
        $logoMatch = [regex]::Match($wpfScriptText, "(?ms)\$brandLogoBase64 = @'\r?\n(?<payload>.*?)\r?\n'@")

        if (-not $logoMatch.Success) {
            throw 'Expected the WPF launcher to embed a brand logo payload'
        }

        $brandLogoPayload = ($logoMatch.Groups['payload'].Value -replace '\s+', '')
        if ([string]::IsNullOrWhiteSpace($brandLogoPayload)) {
            throw 'Expected the embedded brand logo payload to contain base64 content'
        }
        if ($brandLogoPayload -match '\.\.\.') {
            throw 'Expected the embedded brand logo payload to be complete rather than truncated with ellipsis'
        }

        try {
            $brandLogoBytes = [Convert]::FromBase64String($brandLogoPayload)
        }
        catch {
            throw "Expected the embedded brand logo payload to decode cleanly: $($_.Exception.Message)"
        }

        if (@($brandLogoBytes).Count -lt 1024) {
            throw "Expected the embedded brand logo payload to decode into a substantial image, got $(@($brandLogoBytes).Count) bytes"
        }
    }

    It 'shows the updated document property labels and reference images in the WPF launcher' {
        $wpfScriptPath = Join-Path $repoRoot 'gui/Start-AssemblerGui.Wpf.ps1'
        $wpfScriptText = Get-Content -LiteralPath $wpfScriptPath -Raw -Encoding UTF8

        foreach ($expectedText in @('Document Version', 'Configuration Snapshot Date', 'Reference ID', 'Cover Page Diagram', 'Header/Footer Diagram', 'CoverKeyImage', 'HeadFootKeyImage')) {
            if ($wpfScriptText -notmatch [regex]::Escape($expectedText)) {
                throw "Expected the WPF launcher to contain '$expectedText'"
            }
        }

        foreach ($unexpectedText in @('(core property)', '(custom property)')) {
            if ($wpfScriptText -match [regex]::Escape($unexpectedText)) {
                throw "Expected the WPF launcher to remove legacy label helper text '$unexpectedText'"
            }
        }
    }

    It 'shows the simplified connector editor controls in the WPF launcher' {
        $wpfScriptPath = Join-Path $repoRoot 'gui/Start-AssemblerGui.Wpf.ps1'
        $wpfScriptText = Get-Content -LiteralPath $wpfScriptPath -Raw -Encoding UTF8

        foreach ($expectedText in @('Current Connections', 'ConnectorConnectionList', 'ConnectorSearchTextBox', 'ConnectorQuickFilterCombo', 'ConnectorDetailText', 'ConnectorAuthoringExpander', 'Edit mapping', 'Replace target', 'New connection', 'Open dataset', 'Open target', 'Create or Rebind (choose an action above)', 'Mapping Setup', 'Columns', 'Rendered Table Preview', 'Advanced preview and data tools', 'Source Preview', 'Rendered Preview Detail', 'Filters (secondary)', 'Sort (secondary)', 'ConnectorProjectionColumnsList', 'ConnectorProjectionFiltersList', 'ConnectorProjectionSortList', 'ConnectorProjectionRefText', 'ConnectorRenderedPreviewGrid', 'ConnectorRenderedGridStatusText')) {
            if ($wpfScriptText -notmatch [regex]::Escape($expectedText)) {
                throw "Expected the WPF connector tab to contain '$expectedText'"
            }
        }

        foreach ($unexpectedText in @("Header='Projection Shaping'", "Header='Rendered Preview'", "<ListBox Name='ConnectorDatasetList'", "<ListBox Name='ConnectorTargetList'")) {
            if ($wpfScriptText -match [regex]::Escape($unexpectedText)) {
                throw "Expected the simplified connector editor to remove '$unexpectedText' from the primary layout"
            }
        }
        if ($wpfScriptText -notmatch "<ComboBox Name='ConnectorDatasetList'") {
            throw 'Expected the connector editor to use a compact dataset selector combo box'
        }
        if ($wpfScriptText -notmatch "<ComboBox Name='ConnectorTargetList'") {
            throw 'Expected the connector editor to use a compact target selector combo box'
        }
        if ($wpfScriptText -notmatch "<Expander Grid\.Row='4' Header='Advanced preview and data tools' IsExpanded='False'>") {
            throw 'Expected the connector editor to keep preview detail and data tools collapsed behind an advanced expander by default'
        }
        if ($wpfScriptText -notmatch "<ScrollViewer VerticalScrollBarVisibility='Auto' HorizontalScrollBarVisibility='Disabled'>") {
            throw 'Expected the connector editor to wrap the authoring workspace in a ScrollViewer'
        }
        if ($wpfScriptText -notmatch "Name='ConnectorRenderedPreviewGrid'[\s\S]*?CanUserSortColumns='False'") {
            throw 'Expected the live rendered preview grid to disable column-header sorting'
        }
        if ($wpfScriptText -notmatch '\$column\.CanUserSort = \$false') {
            throw 'Expected dynamic rendered preview columns to disable per-column sorting'
        }
        if ($wpfScriptText -notmatch "FindName\('MappingStudioTabs'\)") {
            throw 'Expected the WPF launcher to bind the MappingStudioTabs control for connector navigation actions'
        }
    }

    It 'builds known target inventory with placed, mapped-but-not-placed, and stage-only targets' {
        $workbench = Get-LenovoWorkbench
        $placedTarget = @($workbench.Targets | Where-Object { $_.TargetPath -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces' } | Select-Object -First 1)[0]
        $mappedNotPlacedTarget = @($workbench.Targets | Where-Object { $_.TargetPath -eq 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config' } | Select-Object -First 1)[0]
        $stageOnlyTarget = @($workbench.Targets | Where-Object { $_.TargetPath -eq 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>' } | Select-Object -First 1)[0]

        if ($null -eq $placedTarget -or [string]$placedTarget.PlacementGroup -ne 'Placed in template') {
            throw 'Expected ManagementInterfaces target to be discovered as placed in template'
        }
        if ($null -eq $mappedNotPlacedTarget -or [string]$mappedNotPlacedTarget.PlacementGroup -ne 'Mapped but not placed') {
            throw 'Expected Narrative.Config target to be discovered as mapped but not placed'
        }
        if ($null -eq $stageOnlyTarget -or [string]$stageOnlyTarget.PlacementGroup -ne 'Available to stage') {
            throw 'Expected Narrative.Config>> target to be discovered as available to stage'
        }
        if (@($workbench.Warnings).Count -ne 0) {
            throw "Did not expect artifact warnings for the primary Lenovo.DE workbench. Warnings: $(@($workbench.Warnings) -join '; ')"
        }
    }

    It 'builds one connection row per mapping entry with readable summaries and badges' {
        $workbench = Get-LenovoWorkbench
        $connectionRows = @($workbench.ConnectionRows)
        $managementConnection = @($connectionRows | Where-Object {
                [string]$_.DatasetId -eq 'management-interfaces' -and
                [string]$_.TargetPath -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces'
            } | Select-Object -First 1)[0]

        if ($connectionRows.Count -ne @($workbench.MappingViews).Count) {
            throw "Expected one connection row per mapping entry, got rows=$($connectionRows.Count) mappings=$(@($workbench.MappingViews).Count)"
        }
        if ($null -eq $managementConnection) {
            throw 'Expected a connection row for management-interfaces -> Tables.ManagementInterfaces'
        }
        if ([string]$managementConnection.Label -ne 'management-interfaces -> LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces') {
            throw "Unexpected connection label '$($managementConnection.Label)'"
        }
        foreach ($badgeFragment in @('table', 'placed', 'cols:7', 'Table Projection')) {
            if ([string]$managementConnection.BadgeText -notmatch [regex]::Escape($badgeFragment)) {
                throw "Expected connection badge text to include '$badgeFragment', got '$($managementConnection.BadgeText)'"
            }
        }
        if ([string]$managementConnection.Summary -notmatch 'selector=items') {
            throw "Expected connection summary to include selector=items, got '$($managementConnection.Summary)'"
        }
        if ([string]$managementConnection.Summary -notmatch 'columns=7') {
            throw "Expected connection summary to include a column count, got '$($managementConnection.Summary)'"
        }
        if ([string]$managementConnection.Summary -notmatch 'sort=3') {
            throw "Expected connection summary to include sort count, got '$($managementConnection.Summary)'"
        }
    }

    It 'prefills a projection draft for an existing table mapping and keeps target detail destination-focused' {
        $workbench = Get-LenovoWorkbench
        $managementConnection = @($workbench.ConnectionRows | Where-Object {
                [string]$_.DatasetId -eq 'management-interfaces' -and
                [string]$_.TargetPath -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces'
            } | Select-Object -First 1)[0]
        $projectionDraft = New-MappingStudioProjectionDraft -Workbench $workbench -ExistingMapping $managementConnection.MappingView -DatasetNode $managementConnection.DatasetNode -TargetNode $managementConnection.TargetNode -RenderAs 'table'
        $targetDetail = Format-TargetNodeDetail -TargetNode $managementConnection.TargetNode

        if ([string]$projectionDraft.ProjectionRef -ne 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces') {
            throw "Expected projection draft to keep the target-owned projection ref, got '$([string]$projectionDraft.ProjectionRef)'"
        }
        if (@($projectionDraft.Columns).Count -ne 7) {
            throw "Expected existing table mapping to prefill 7 projection columns, got $(@($projectionDraft.Columns).Count)"
        }
        if ([string]@($projectionDraft.RowOrder)[0].By -ne 'controllerSlot') {
            throw "Expected existing table mapping to prefill row order by controllerSlot, got '$([string]@($projectionDraft.RowOrder)[0].By)'"
        }
        if ($targetDetail -match 'Projection:') {
            throw "Expected target detail to stay destination-focused without projection metadata, got:`n$targetDetail"
        }
    }

    It 'groups datasets by scope and presentation kind using dataset metadata' {
        $workbench = Get-LenovoWorkbench
        $systems = $workbench.DatasetById['systems']
        $volumeMappings = $workbench.DatasetById['volume-mappings']
        $capabilities = $workbench.DatasetById['capabilities-normalized']

        if ([string]$systems.Label -ne '[target/summary] systems') {
            throw "Expected systems dataset label to include scope/presentation grouping, got '$($systems.Label)'"
        }
        if ([string]$volumeMappings.PresentationKind -ne 'relationshipTable') {
            throw "Expected volume-mappings presentationKind relationshipTable, got '$($volumeMappings.PresentationKind)'"
        }
        if ([string]$capabilities.PresentationKind -ne 'evidence') {
            throw "Expected capabilities-normalized to remain evidence/debug oriented, got '$($capabilities.PresentationKind)'"
        }
        if (-not [bool]$systems.HasExampleData) {
            throw 'Expected systems dataset to have example bundle data available'
        }
    }

    It 'filters connection rows by search text and quick filter' {
        $workbench = Get-LenovoWorkbench
        $connectionRows = @($workbench.ConnectionRows)
        $targetSearch = @(Select-MappingStudioConnectionRows -ConnectionRows $connectionRows -SearchText 'Narrative.Config' -QuickFilter 'All')
        $placedRows = @(Select-MappingStudioConnectionRows -ConnectionRows $connectionRows -SearchText '' -QuickFilter 'Placed')
        $scalarRows = @(Select-MappingStudioConnectionRows -ConnectionRows $connectionRows -SearchText '' -QuickFilter 'Scalar')

        if ($targetSearch.Count -eq 0) {
            throw 'Expected at least one connection row to match a target-path search for Narrative.Config'
        }
        if (@($targetSearch | Where-Object { [string]$_.TargetPath -notmatch 'Narrative\.Config' }).Count -gt 0) {
            throw 'Expected target-path search filtering to keep only matching connection rows'
        }
        if ($placedRows.Count -eq 0 -or @($placedRows | Where-Object { [string]$_.PlacementGroup -ne 'Placed in template' }).Count -gt 0) {
            throw 'Expected the Placed quick filter to return only placed connection rows'
        }
        if ($scalarRows.Count -eq 0 -or @($scalarRows | Where-Object { [string]$_.RenderAs -ne 'scalar' }).Count -gt 0) {
            throw 'Expected the Scalar quick filter to return only scalar connection rows'
        }
    }

    It 'previews Lenovo.DE scalar, table, and multi-view table mappings using bundle example data' {
        $workbench = Get-LenovoWorkbench
        $systemsPreview = Get-MappingStudioPreview -Workbench $workbench -DatasetId 'systems' -RenderAs 'scalar' -Selector 'items.0.name' -ProjectionRef '' -View ''
        $managementPreview = Get-MappingStudioPreview -Workbench $workbench -DatasetId 'management-interfaces' -RenderAs 'table' -Selector 'items' -ProjectionRef 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces' -View ''
        $capabilitiesPreview = Get-MappingStudioPreview -Workbench $workbench -DatasetId 'capabilities-normalized' -RenderAs 'table' -Selector 'items' -ProjectionRef 'LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary' -View 'CapabilitiesSummary'

        if ([string]$systemsPreview.Status -ne 'ok' -or [string]$systemsPreview.SampleValue -ne 'DE4200_Rack4') {
            throw "Expected scalar preview to resolve the systems sample value, got status='$($systemsPreview.Status)' sample='$($systemsPreview.SampleValue)'"
        }
        if ([string]$managementPreview.Status -ne 'ok' -or [int]$managementPreview.RowCount -lt 2) {
            throw "Expected management-interfaces preview rows, got status='$($managementPreview.Status)' rows='$($managementPreview.RowCount)'"
        }
        if ((@($managementPreview.ColumnNames) -join ',') -notmatch 'Controller,Slot,Port,Interface,LinkStatus,Address,Mask') {
            throw "Expected ManagementInterfaces projection columns, got '$((@($managementPreview.ColumnNames) -join ', '))'"
        }
        if ([string]$capabilitiesPreview.Status -ne 'ok' -or (@($capabilitiesPreview.ColumnNames).Count -eq 0)) {
            throw "Expected capabilities-normalized multi-view preview columns, got status='$($capabilitiesPreview.Status)' columns='$((@($capabilitiesPreview.ColumnNames) -join ', '))'"
        }
        if ([string]@($capabilitiesPreview.PreviewRows)[0].Feature -ne 'Storage Partitions') {
            throw "Expected first capabilities preview row to include Storage Partitions, got '$([string]@($capabilitiesPreview.PreviewRows)[0].Feature)'"
        }
        if ([int]$managementPreview.SourceRowCount -lt 2) {
            throw "Expected source-row preview to resolve the underlying table rows, got '$($managementPreview.SourceRowCount)'"
        }
        if ((@($managementPreview.SourceFieldCandidates) -join ',') -notmatch 'controllerLabel') {
            throw "Expected source preview to expose row field candidates, got '$((@($managementPreview.SourceFieldCandidates) -join ', '))'"
        }
        if ((@($managementPreview.RenderedGridColumns) -join ',') -notmatch 'Controller,Slot,Port,Interface,LinkStatus,Address,Mask') {
            throw "Expected rendered grid columns to match the projected headers, got '$((@($managementPreview.RenderedGridColumns) -join ', '))'"
        }
        if (@($managementPreview.RenderedGridRows).Count -lt 2) {
            throw "Expected rendered grid rows to include sample data, got '$(@($managementPreview.RenderedGridRows).Count)'"
        }
        if ([string]@($managementPreview.RenderedGridRows)[0].Controller -ne 'B') {
            throw "Expected rendered grid rows to expose projected values, got '$([string]@($managementPreview.RenderedGridRows)[0].Controller)'"
        }
    }

    It 'validates staged targets against the target inventory and replaces queued drafts for the same target' {
        $workbench = Get-LenovoWorkbench
        $firstPending = Add-MappingStudioPendingChange -Workbench $workbench -PendingChanges @() -DatasetId 'systems' -TargetPath 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>' -RenderAs 'scalar' -Selector 'items.0.model' -View 'Config'
        $replacedPending = Add-MappingStudioPendingChange -Workbench $workbench -PendingChanges $firstPending -DatasetId 'systems' -TargetPath 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>' -RenderAs 'scalar' -Selector 'items.0.name' -View 'Config'

        if (@($replacedPending).Count -ne 1) {
            throw "Expected only one queued draft for the staged target, got $(@($replacedPending).Count)"
        }
        if ([string]$replacedPending[0].Selector -ne 'items.0.name') {
            throw "Expected the later queued selector to replace the earlier draft, got '$($replacedPending[0].Selector)'"
        }

        $invalidTargetThrown = $false
        try {
            $null = Add-MappingStudioPendingChange -Workbench $workbench -PendingChanges @() -DatasetId 'systems' -TargetPath 'LNV.Lenovo.DE.System[ArrayName].Narrative.FreeForm' -RenderAs 'scalar' -Selector 'items.0.name'
        }
        catch {
            $invalidTargetThrown = $_.Exception.Message -match 'target inventory'
        }

        if (-not $invalidTargetThrown) {
            throw 'Expected free-form target queueing to be rejected for v1 staged target validation'
        }
    }

    It 'uses contract authoring support when YAML is available and falls back to runtime mapping otherwise' {
        $yamlSupport = Get-MappingStudioYamlSupport
        $workbench = Get-LenovoWorkbench

        if ([bool]$yamlSupport.available) {
            if ([string]$workbench.MappingDocument.source -ne 'contract') {
                throw "Expected contract mapping source when YAML support is available, got '$($workbench.MappingDocument.source)'"
            }
            if ([bool]$workbench.MappingDocument.readOnly) {
                throw 'Expected Mapping Studio workbench to be writable when YAML support is available'
            }
            return
        }
        if ([string]$workbench.MappingDocument.source -ne 'runtime-fallback') {
            throw "Expected runtime-fallback mapping source, got '$($workbench.MappingDocument.source)'"
        }
        if (-not [bool]$workbench.MappingDocument.readOnly) {
            throw 'Expected Mapping Studio workbench to be read-only without YAML support'
        }
    }

    It 'reports missing token-audit and heading-map artifacts explicitly' {
        $tempRepo = New-MappingStudioTempRepo -Name 'missing-artifacts' -RemoveTokenAudit -RemoveHeadingMap
        try {
            $workbench = Get-LenovoWorkbench -ResolvedRepoRoot $tempRepo.RepoRoot -ResolvedCatalogPath $tempRepo.CatalogPath
            $warnings = @($workbench.Warnings)

            if ($warnings -notcontains 'Token-audit artifact was not found. Template placement coverage is partially inferred.') {
                throw "Expected missing token-audit warning. Warnings: $($warnings -join '; ')"
            }
            if ($warnings -notcontains 'Heading-tag map artifact was not found. Template placement coverage is partially inferred.') {
                throw "Expected missing heading-map warning. Warnings: $($warnings -join '; ')"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRepo.RepoRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRepo.RepoRoot -Recurse -Force
            }
        }
    }

    It 'formats duplicate-target connection details with an explicit warning' {
        $tempRepo = New-MappingStudioTempRepo -Name 'duplicate-connection-detail' -UseJsonYamlContract -IncludeDuplicateManagementTarget
        try {
            function global:ConvertFrom-Yaml {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)]$InputObject)

                begin {
                    $chunks = [System.Collections.Generic.List[string]]::new()
                }
                process {
                    if ($null -ne $InputObject) {
                        $chunks.Add([string]$InputObject) | Out-Null
                    }
                }
                end {
                    $text = $chunks -join [Environment]::NewLine
                    if ([string]::IsNullOrWhiteSpace($text)) {
                        return $null
                    }
                    return ($text | ConvertFrom-Json -AsHashtable)
                }
            }

            function global:ConvertTo-Yaml {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)]$InputObject)

                begin {
                    $captured = $null
                }
                process {
                    $captured = $InputObject
                }
                end {
                    return ($captured | ConvertTo-Json -Depth 100)
                }
            }

            Import-Module $modulePath -Force
            $workbench = Get-LenovoWorkbench -ResolvedRepoRoot $tempRepo.RepoRoot -ResolvedCatalogPath $tempRepo.CatalogPath -ResolvedContractsRoot $tempRepo.ContractsRoot
            $duplicateRow = @($workbench.ConnectionRows | Where-Object {
                    [string]$_.TargetPath -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces'
                } | Select-Object -First 1)[0]
            $detail = Format-MappingStudioConnectionDetail -ConnectionRow $duplicateRow

            if ($null -eq $duplicateRow) {
                throw 'Expected a duplicate-target connection row for the ManagementInterfaces target'
            }
            if ($detail -notmatch 'Warning') {
                throw "Expected duplicate-target detail to include a Warning section, got:`n$detail"
            }
            if ($detail -notmatch 'active mappings') {
                throw "Expected duplicate-target detail to mention active mappings, got:`n$detail"
            }
        }
        finally {
            Remove-Item Function:\ConvertFrom-Yaml -ErrorAction SilentlyContinue
            Remove-Item Function:\ConvertTo-Yaml -ErrorAction SilentlyContinue
            Import-Module $modulePath -Force
            if (Test-Path -LiteralPath $tempRepo.RepoRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRepo.RepoRoot -Recurse -Force
            }
        }
    }

    It 'marks preview as unavailable when example bundle data is missing' {
        $tempRepo = New-MappingStudioTempRepo -Name 'missing-example-data' -BreakSystemsExamplePath
        try {
            $workbench = Get-LenovoWorkbench -ResolvedRepoRoot $tempRepo.RepoRoot -ResolvedCatalogPath $tempRepo.CatalogPath -ResolvedContractsRoot $tempRepo.ContractsRoot
            $systems = $workbench.DatasetById['systems']
            $preview = Get-MappingStudioPreview -Workbench $workbench -DatasetId 'systems' -RenderAs 'scalar' -Selector 'items.0.name' -ProjectionRef '' -View ''

            if ([bool]$systems.HasExampleData) {
                throw 'Expected systems dataset to lose live example data after overriding datasetPath.template'
            }
            if ([string]$preview.Status -ne 'missing-example') {
                throw "Expected missing-example preview state, got '$($preview.Status)'"
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRepo.RepoRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRepo.RepoRoot -Recurse -Force
            }
        }
    }

    Context 'with YAML authoring support stubbed for save-path tests' {
        BeforeAll {
            function global:ConvertFrom-Yaml {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)]$InputObject)

                begin {
                    $chunks = [System.Collections.Generic.List[string]]::new()
                }
                process {
                    if ($null -ne $InputObject) {
                        $chunks.Add([string]$InputObject) | Out-Null
                    }
                }
                end {
                    $text = $chunks -join [Environment]::NewLine
                    if ([string]::IsNullOrWhiteSpace($text)) {
                        return $null
                    }
                    return ($text | ConvertFrom-Json -AsHashtable)
                }
            }

            function global:ConvertTo-Yaml {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)]$InputObject)

                begin {
                    $captured = $null
                }
                process {
                    $captured = $InputObject
                }
                end {
                    return ($captured | ConvertTo-Json -Depth 100)
                }
            }

            Import-Module $modulePath -Force
        }

        AfterAll {
            Remove-Item Function:\ConvertFrom-Yaml -ErrorAction SilentlyContinue
            Remove-Item Function:\ConvertTo-Yaml -ErrorAction SilentlyContinue
            Import-Module $modulePath -Force
        }

        It 'saves a staged mapping to contract yaml, export mirror, and regenerated runtime mapping' {
            $tempRepo = New-MappingStudioTempRepo -Name 'save-staged-mapping' -UseJsonYamlContract
            try {
                $workbench = Get-LenovoWorkbench -ResolvedRepoRoot $tempRepo.RepoRoot -ResolvedCatalogPath $tempRepo.CatalogPath -ResolvedContractsRoot $tempRepo.ContractsRoot
                $pending = Add-MappingStudioPendingChange -Workbench $workbench -PendingChanges @() -DatasetId 'systems' -TargetPath 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>' -RenderAs 'scalar' -Selector 'items.0.model' -View 'Config'
                $result = Save-MappingStudioPendingChanges -Workbench $workbench -PendingChanges $pending
                $savedContract = Get-Content -LiteralPath $tempRepo.ContractPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                $runtimeDocument = Get-Content -LiteralPath $tempRepo.RuntimeMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                $savedEntry = @($savedContract.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>' } | Select-Object -First 1)[0]
                $runtimeEntry = @($runtimeDocument.mappings | Where-Object { $_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>' } | Select-Object -First 1)[0]

                if ([bool]$workbench.MappingDocument.readOnly) {
                    throw 'Expected authoring workbench to be writable with YAML stubs installed'
                }
                if ([int]$result.SavedCount -ne 1) {
                    throw "Expected SavedCount=1, got '$($result.SavedCount)'"
                }
                if ($null -eq $savedEntry) {
                    throw 'Expected saved contract document to include the staged Narrative.Config>> entry'
                }
                if ([string]$savedEntry.target.kind -ne 'sdt' -or [string]$savedEntry.target.path -ne 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>') {
                    throw "Expected dual-shape contract target.kind/path for staged entry, got kind='$([string]$savedEntry.target.kind)' path='$([string]$savedEntry.target.path)'"
                }
                if ([string]@($savedEntry.selectors)[0] -ne 'items.0.model') {
                    throw "Expected staged entry selector items.0.model, got '$([string]@($savedEntry.selectors)[0])'"
                }
                if (-not (Test-Path -LiteralPath $tempRepo.ExportMirrorPath -PathType Leaf)) {
                    throw 'Expected export mirror file to be written during save'
                }
                if ((Get-Content -LiteralPath $tempRepo.ExportMirrorPath -Raw -Encoding UTF8) -ne (Get-Content -LiteralPath $tempRepo.ContractPath -Raw -Encoding UTF8)) {
                    throw 'Expected export mirror content to match the saved contract document exactly'
                }
                if ($null -eq $runtimeEntry) {
                    throw 'Expected regenerated runtime mapping to include the staged Narrative.Config>> entry'
                }
                if ([string]$runtimeEntry.target.sdtTag -ne 'LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>') {
                    throw "Expected runtime mapping target.sdtTag for staged entry, got '$([string]$runtimeEntry.target.sdtTag)'"
                }
            }
            finally {
                if (Test-Path -LiteralPath $tempRepo.RepoRoot -PathType Container) {
                    Remove-Item -LiteralPath $tempRepo.RepoRoot -Recurse -Force
                }
            }
        }

        It 'rebinds an existing mapped target without leaving duplicate active mappings behind' {
            $tempRepo = New-MappingStudioTempRepo -Name 'save-rebind-existing' -UseJsonYamlContract -IncludeDuplicateManagementTarget
            try {
                $workbench = Get-LenovoWorkbench -ResolvedRepoRoot $tempRepo.RepoRoot -ResolvedCatalogPath $tempRepo.CatalogPath -ResolvedContractsRoot $tempRepo.ContractsRoot
                $pending = Add-MappingStudioPendingChange -Workbench $workbench -PendingChanges @() -DatasetId 'transport' -TargetPath 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces' -RenderAs 'table' -Selector 'items' -ProjectionRef 'LNV.Lenovo.DE.System[ArrayName].Tables.Transport'
                $null = Save-MappingStudioPendingChanges -Workbench $workbench -PendingChanges $pending
                $savedContract = Get-Content -LiteralPath $tempRepo.ContractPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                $savedProjectionDocument = Get-Content -LiteralPath $tempRepo.ProjectionContractPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                $savedMatches = @($savedContract.mappings | Where-Object {
                        [string]$_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces'
                    })
                $runtimeDocument = Get-Content -LiteralPath $tempRepo.RuntimeMappingPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                $runtimeMatches = @($runtimeDocument.mappings | Where-Object {
                        [string]$_.sdtTag -eq 'LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces'
                    })

                if ($savedMatches.Count -ne 1) {
                    throw "Expected exactly one active contract mapping after rebinding duplicate target, got $($savedMatches.Count)"
                }
                if ([string]$savedMatches[0].dataset -ne 'transport') {
                    throw "Expected rebound contract mapping dataset=transport, got '$([string]$savedMatches[0].dataset)'"
                }
                if ([string]$savedMatches[0].renderHint.projectionRef -ne 'LNV.Lenovo.DE.System[ArrayName].Tables.Transport') {
                    throw "Expected rebound projectionRef Transport, got '$([string]$savedMatches[0].renderHint.projectionRef)'"
                }
                if ($runtimeMatches.Count -ne 1) {
                    throw "Expected exactly one runtime mapping for the rebound target, got $($runtimeMatches.Count)"
                }
                if ($null -eq $savedProjectionDocument.projections['LNV.Lenovo.DE.System[ArrayName].Tables.Transport']) {
                    throw 'Expected projection contract JSON to remain present after save'
                }
                if (-not (Test-Path -LiteralPath $tempRepo.ProjectionExportMirrorPath -PathType Leaf)) {
                    throw 'Expected projection export mirror file to be written during save'
                }
            }
            finally {
                if (Test-Path -LiteralPath $tempRepo.RepoRoot -PathType Container) {
                    Remove-Item -LiteralPath $tempRepo.RepoRoot -Recurse -Force
                }
            }
        }
    }
}
