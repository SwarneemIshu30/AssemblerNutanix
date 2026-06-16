# Nutanix.Prism Collector Spec (Direct-v1)

## Overview
This technology defines Direct-v1 collection for Nutanix Prism environments.
The collector supports Prism Element targets for cluster-local inventory and
Prism Central targets for global inventory where the provider has contracted
dataset coverage.

## Collector Module
- `techId`: `Nutanix.Prism`
- Module path: `LNV.AsBuiltDoc.Nutanix.Prism`
- Entrypoint: `Invoke-LnvAsBuiltDoc.Nutanix.Prism`

## Authentication
Collectors must not store secrets in plans. Targets reference credentials with
`targets[].authRef`; Core resolves the referenced auth material at runtime.

Minimum resolved auth material:
- `username`
- `password`

## Plan Conventions
Targets remain executable collection units. Optional `targetGroups` are
orchestration/correlation units only.

Supported target kinds:
- `Nutanix.Prism`
- `PrismElement`
- `PrismCentral`
- `Nutanix.PrismCentral`

Supported target group kinds:
- `NutanixPrismHybrid`
- `NutanixPrismCentralOnly`
- `NutanixPrismElementOnly`

Target endpoint fields:
- `targets[].endpoints.prism` preferred
- `targets[].endpoint`, `host`, `hostname`, or `address` accepted for manual/diagnostic compatibility

Optional target params:
- `port` or `httpsPort`, default `9440`
- `timeoutSec` or `timeoutSeconds`, default `60`
- `skipTlsVerify` or `insecureSkipTlsVerify`, default `false`
- `scheme` or `protocol`, default `https`

## API Providers
Current provider support:
- Prism Element v2 for cluster-local inventory/configuration
- Prism Element v1 for legacy endpoints still required by the upstream collector behavior
- Prism Central v4 for contracted PC global datasets where available
- Prism Central v3 fallback for contracted PC global datasets

Current PC contracted datasets:
- `cluster`
- `vms`
- `categories`
- `policies`
- `alerts`
- `tasks`
- `hosts`
- `host_nics`
- `networks`
- `virtual_switches`
- `storage_containers`
- `volume_groups`
- `images`
- `templates`
- `alerts_configuration`
- `ssl_certificates`
- `license`

Provider fallback is selected per dataset. Prism Central collection attempts v4
first, records the selected source in `collection_sources`, and falls back to v3
when the v4 endpoint is unavailable. Prism Element v2 remains preferred for
cluster-local hardware and storage details.

Additional PC/global datasets must not be emitted until their schemas and
manifest entries are added.

## Dataset Rules
The collector emits native `lnv.collector.dataset.v1` envelopes for contract
datasets. Dataset keys must match this manifest and the `dataset/*.schema.json`
files.

Raw evidence is written separately under:

```text
evidence/Nutanix.Prism/<targetKey>/<apiFamily>/<dataset>.raw.json
```

Raw evidence is redacted before write and is not a contract dataset.

## Correlation
Per-target relationships are emitted under the `relationships` dataset. Hybrid
target groups may also emit group-domain relationship datasets when Prism
Central and Prism Element members can be correlated by UUID-first policy.

Unresolved relationships are retained with:
- `correlationStatus: unresolved`
- `correlationWarnings`

## Boundaries
- Do not call legacy report-generation or rendering hooks from this Direct-v1 path.
- Do not make assemblers target-group aware.
- Do not emit datasets not present in this manifest.
