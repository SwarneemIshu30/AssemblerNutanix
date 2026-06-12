# NetApp ONTAP Skeleton Blueprint

## Document Shape

1. Cluster summary
2. Node, SVM, aggregate, volume, network, and license inventory tables
3. Optional REST gap tables for mediators, multi-admin approval, consistency groups, and S3
4. Toolkit baseline appendix
5. Assembler-rendered diagrams from graph datasets and assembler-owned NetApp diagram assets

## Dataset Inputs

All collector datasets use native `lnv.collector.dataset.v1` envelopes. The assembler should consume `items` for table projections and graph dataset `items[0]` for diagram projections.

## Diagram Policy

The collector emits graph data only. Rendering, layout, icon selection, and diagram asset ownership belong to assembler-side logic.
