# NetApp ONTAP Collector Spec

## Identity

- Tech ID: `NetApp.ONTAP`
- Module: `LNV.AsBuiltDoc.NetApp.ONTAP`
- Entrypoint: `Invoke-LnvAsBuiltDoc.NetApp.ONTAP`
- Contract envelope: `lnv.collector.dataset.v1`

## Direct-v1 Invocation

Core invokes this collector with `BundleContext`, `Targets`, `CollectorSpec`, and `Plan`.

Targets must provide:

- `key`
- `endpoints.mgmt`
- `authRef`

Target params:

- `port`: HTTPS/ONTAP management port, default `443`.
- `skipTlsVerify`: diagnostic TLS bypass, default `false`.
- `timeoutSeconds`: REST timeout, default `60`.

Collector params:

- `enableToolkitBaseline`: default `true`.
- `enableDiagramGraphs`: default `true`.
- `netAppOntapModulePath`: optional explicit path to `NetApp.ONTAP.psd1` or its containing module directory.

## Auth

Auth resolves from `targets[].authRef` through `Plan.auth`.

Materialized local test plans may provide `username` and `password` directly under `Plan.auth.<authRef>`. Production plans should use an external secret reference resolvable by Core auth resolver shims.

Collector-level `authRef` is not part of the Direct-v1 invocation contract for this collector.

## Runtime Dependencies

The collector uses the `NetApp.ONTAP` Toolkit for the baseline command inventory. The tested provisional minimum version is `9.18.1.2601`.

Resolution order:

1. `CollectorSpec.params.netAppOntapModulePath`
2. plan repo `.deps/modules/NetApp.ONTAP/<version>/NetApp.ONTAP.psd1`
3. plan repo `.deps/modules/NetApp.ONTAP/NetApp.ONTAP.psd1`
4. installed `NetApp.ONTAP` module

REST remains in use for REST-only gap datasets such as consistency groups, S3, multi-admin approval, and mediators.

## Outputs

The collector writes one dataset envelope per manifest dataset at `datasets/NetApp.ONTAP/core/<TargetKey>/<Dataset>.json`, per-target coverage at the same canonical target root, and child identities into the Core-owned root object index. Redacted REST and Toolkit captures are evidence under `evidence/NetApp.ONTAP/<TargetKey>/`; they are not document datasets. The collector does not create `collector-out`, `target_*`, a nested manifest, or a target-local `raw` directory. Diagram rendering is not performed by the collector; graph datasets and asset contracts are assembler inputs.
