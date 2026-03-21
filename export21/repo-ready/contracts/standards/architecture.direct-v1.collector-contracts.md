# Direct-v1 Collector Contracts Architecture (Contracts Pack 2.x)

This document defines the collector-contract architecture expected by Core for any technology contract that uses `CollectorContractManifest`.

## 1) Manifest model
A tech contract MUST provide `tech/<TechId>/manifest.yaml` with:

- `kind: CollectorContractManifest`
- `spec.datasetSchemaPath: dataset`
- `spec.datasetToSdtMapping: mapping.dataset-to-sdt.v1.yaml`
- `spec.datasets`: explicit list of dataset keys emitted by the collector
- `spec.bundleSchemas.dataset: lnv.collector.dataset.v1`

## 2) Layout model
Collector-contract tech layout MUST be:

- `tech/<TechId>/manifest.yaml`
- `tech/<TechId>/plan_validation.yaml`
- `tech/<TechId>/collector_spec.md`
- `tech/<TechId>/sdt_inventory.md`
- `tech/<TechId>/skeleton_blueprint.md`
- `tech/<TechId>/mapping.dataset-to-sdt.v1.yaml`
- `tech/<TechId>/dataset/*.schema.json`

Legacy schema layout (`tech/<TechId>/datasets/`) is not allowed.

## 3) Dataset envelope model
Collector output datasets MUST conform to envelope schema identifier:

- `schema_version: lnv.collector.dataset.v1`

Required fields in each dataset file:

- `collector`
- `source`
- `dataset`
- `item_count`
- `items`

And:

- `item_count` MUST equal the length of `items`.
- `<datasetKey>.json` MUST map to `tech/<TechId>/<datasetSchemaPath>/<datasetKey>.schema.json`.
- Dataset keys MUST be in `spec.datasets`.

## 4) Contracts pack compatibility
Collector-contract tech validation assumes contracts pack version `>=2.0.0 <3.0.0` via `contracts.snapshot.json`.

## 5) Migration behavior (Core compatibility path)
Until all modules emit the envelope natively, Core may migrate legacy wrapper payloads (`{ schemaVersion, items }`) into the required envelope shape.
This compatibility path is transitional and should be removed after all collectors emit native envelope output.

## 6) Machine-readable onboarding plan
For zero-context agent onboarding and implementation planning, see:

- `docs/codex.collector-contracts.onboarding.plan.v1.yaml`
