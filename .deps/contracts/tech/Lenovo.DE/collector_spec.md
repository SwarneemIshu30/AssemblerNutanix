# Lenovo.DE Collector Spec (Direct-v1)

## Overview
This technology defines collection for **Lenovo DE-series** storage arrays using
**SANtricity Embedded REST** (direct controller `/devmgr` API), without SMcli/Java proxy.

Supported embedded REST platforms (mapped from NetApp E/EF lineage):
- DE2000H (E2800) / DE4000F (EF280) — SANtricity 11.30+
- DE6000H (E5700) / DE6000F (EF570) — SANtricity 11.40+
- DE6400 (EF300) / DE6600 (EF600) — SANtricity 11.60+
- DE4200H–DE4800H/F (E4000) — SANtricity 11.90+

## Collector Module
- `techId`: `Lenovo.DE`
- Module path (PowerShell): `LNV.AsBuiltDoc.Lenovo.DE`
- Entrypoint: `Invoke-LnvAsBuiltDoc.Lenovo.DE`

## Authentication
Collectors MUST NOT store secrets in plans.
Plans reference credentials via `collectors[].authRef` and `plan.auth[<authRef>]`.

Minimum auth material required (resolved from authRef outside the plan):
- `username`
- `password`

Expected SANtricity permissions:
- Read-only / monitoring privileges sufficient to query system inventory and configuration.
- If audit/event APIs are added later, additional privileges might be required.

## Plan Conventions (Plan Schema v1)
Targets are typed by `kind: Lenovo.DE`.

### Required fields
- `targets[].kind`: `Lenovo.DE`
- `targets[].key`: stable identifier (referenced by collectors)
- `targets[].endpoints.mgmt`: controller **management** IP/FQDN (NOT data/iSCSI)

### Optional parameters (targets[].params)
- `port` (int, default `8443`): HTTPS port (commonly `443` or `8443`)
- `apiBasePath` (string, default `/devmgr`)
- `timeoutSec` (int, default `60`)
- `skipTlsVerify` (bool, default `false`) diagnostic only

Tech semantic validation is defined in `plan_validation.yaml`.

## Plan semantic validation ruleset

This technology includes a machine-readable semantic validation ruleset:

- `plan_validation.yaml`

This ruleset defines:
- defaults (port, apiBasePath, timeouts)
- required fields for `kind: Lenovo.DE`
- semantic checks (types/ranges, hostname/IP validation)
- unknown-field policy (warn/error)
- optional preflight steps (TCP probe, HTTPS probe, login) for GUI/Core implementations

## Collection Scope (v1)
The collector SHOULD collect and emit both **raw** and **normalized** datasets.

### Key datasets (logical)
- `systems`: array inventory of storage systems visible to the controller
- `drives`: physical drives inventory
- `storage-containers`: normalized union of:
  - Volume Groups (traditional RAID groups)
  - Disk Pools (DDP)
- `volumes`: volumes/LUNs and their container references (VG or disk pool)

### Important modeling note: VG vs DDP
SANtricity may represent capacity containers as either:
- Volume Groups (RAID level like raid6), or
- Disk Pools (DDP), where RAID semantics differ.

Direct-v1 normalizes both under `storage-containers` with:
- `containerType` (e.g., `VolumeGroup` | `DiskPool`)
- `containerRef` (stable ID)
- `raidLevel` (when present)
- capacity fields normalized to bytes

Volumes should include:
- original refs (`volumeGroupRef`, `diskPoolRef`) if present
- normalized `containerRef` (first of those that exists)

## Output Contract (pre-Core wiring)
During early development, collectors may emit JSON/CSV diagnostics.
When wired into `LNV.AsBuiltDoc.Core`, collectors must emit a Direct-v1 bundle:
- `manifest.json` (Bundle Manifest v1)
- `config_used.json`
- `datasets/*` (normalized + evidence/raw as required)

## Evidence/Raw Guidance
Raw payloads SHOULD be emitted for troubleshooting and auditability, but treated as evidence.
Examples:
- `systems.raw.json`, `drives.raw.json`, `storage-containers.raw.json`, `volumes.raw.json`

## Known Constraints / Operational Notes
- TLS: some arrays use self-signed certs; `skipTlsVerify` is diagnostic-only.
- Management endpoint validation: probe `/devmgr/v2/storage-systems` (401/403 acceptable pre-auth).
- Multi-controller: endpoint may be A or B; future enhancement may try both.