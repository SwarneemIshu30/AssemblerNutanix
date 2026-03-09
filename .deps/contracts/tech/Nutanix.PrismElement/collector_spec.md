# Nutanix.PrismElement — AsBuiltDoc Direct-v1 Collector Contract (LOCKED)

## Status
**LOCKED**  
Changes require ADR + version bump.

---

## 1. Scope & Intent

This document defines the **canonical dataset contract** for the
`Nutanix.PrismElement` AsBuiltDoc Direct-v1 collector.

The collector:
- Reuses `AsBuiltReport.Nutanix.PrismElement` collection logic
- Emits **JSON datasets (Bundle Schema v1)** as the primary output
- May optionally render PScribo reports (legacy / transitional)

The assembler **MUST NOT** parse PScribo output.  
All structured data is captured **before rendering**.

---

## 2. Runtime & Execution Model

- Runtime: **PowerShell 7**
- Execution: serial (parallel opt-in later)
- API access: Nutanix Prism Element (REST)

---

## 3. Output Modes

Collector MUST support:

- `-OutputMode report | datasets | both`
- `-BundlePath <path>` (required for `datasets | both`)

| Mode     | Behaviour |
|--------- |----------|
| report   | PScribo report only (legacy behaviour) |
| datasets | JSON bundle only |
| both     | JSON bundle + PScribo report |

---

## 4. InfoLevel & Gating Model

- **InfoLevel controls collection depth only**
- Render-time gating is handled by the AsBuiltDoc Assembler
- Collector records:
  - `requestedInfoLevel`
  - `effectiveInfoLevel`
- Missing datasets due to permission or gating:
  - MUST be recorded in `coverage`
  - MUST NOT fail the run

---

## 5. Canonical Dataset Layout

All datasets are written under:

```
datasets/Nutanix.PrismElement/
```

Deterministic ordering and redaction are mandatory.

---

## Plan semantic validation ruleset

This technology includes a machine-readable semantic validation ruleset:

- `plan_validation.yaml`

This ruleset defines:
- defaults (port 9440, TLS verification)
- required fields for `kind: Nutanix.PrismElement`
- semantic checks (types/ranges, hostname/IP validation)
- unknown-field policy (warn/error)
- optional preflight steps (TCP probe, HTTPS probe, API probe) for GUI/Core implementations

---

## 6. P0 Datasets (Mandatory)

These datasets MUST be emitted when permissions allow.

| Dataset file | Source API | Primary key | Notes |
|-------------|------------|-------------|------|
| cluster.json | /cluster | uuid (or name) | Cluster identity & version |
| cluster_fault_tolerance.json | /cluster/domain_fault_tolerance_status | domain | RF / FT posture |
| hosts.json | /hosts | uuid | Node inventory |
| networks.json | /networks | uuid | VLAN / network inventory |
| storage_containers.json | /storage_containers | storage_container_uuid | Core storage inventory |
| storage_pools.json | /storage_pools | uuid | Disk pool inventory |
| vms.json | /vms (filtered) | uuid | Workload VMs (non-CVM, NDFS only) |
| cvms.json | /vms (filtered) | uuid | Controller VMs |
| volume_groups.json | /volume_groups | uuid | Block storage |
| protection_domains.json | /protection_domains | name or uuid | DR policies |
| remote_sites.json | /remote_sites | name or uuid | Replication targets |
| licensing.json | /license/ | n/a | Feature & license state |
| datastores.json | /storage_containers/datastores | uuid or name | Conditional — VMware only |

---

## 7. P1 Datasets (Optional / Extended)

| Dataset file | Source API | Notes |
|--------------|-----------|------|
| disks.json | /disks | Physical disk inventory |
| health_checks.json | /health_checks | Health posture |
| alerts_configuration.json | alerts/configuration | Alerting setup |
| smtp_config.json | /cluster/smtp | Redaction required |
| snmp_config.json | /snmp | Redaction required |
| auth_config.json | /authconfig | Redaction required |
| nfs_whitelist.json | /cluster/nfs_whitelist | NFS access |
| witness.json | /cluster/metro_witness | Metro witness |
| images.json | /images | Image library |
| snapshots.json | /snapshots | Snapshot inventory |
| virtual_disks.json | /virtual_disks | vDisk inventory |
| pd_replications.json | /protection_domains/replications | PD replication state |
| dr_snapshots.json | /remote_sites/dr_snapshots | DR snapshots |
| unprotected_vms.json | /protection_domains/unprotected_vms | DR coverage gaps |
| vm_nics.json | /vms/{uuid}/nics | Flattened per-VM NIC list |

---

## 8. Object Index Dataset (Recommended)

The collector SHOULD emit:

```
object_index.json
```

Purpose: stable UUID → display name mapping for assembler / SDT resolution.

Recommended contents:
- Hosts: uuid → hypervisor_address
- Networks: uuid → name, uuid → vlan_id
- Storage containers: uuid → name
- VMs: uuid → vmName

---

## 9. Coverage & Manifest Requirements

The collector MUST record coverage per dataset:
- status: OK | MISSING | ERROR
- count: number of objects collected
- notes: permission or gating reason

The following MUST be recorded:
- requestedInfoLevel
- effectiveInfoLevel

---

## 10. Deterministic Ordering Rules

Before writing datasets:
- Hosts → name
- Networks → name
- Storage containers → name
- Storage pools → name
- VMs / CVMs → vmName
- Disks → id

Volatile fields SHOULD be normalised or removed before hashing.

---

## 11. Redaction Policy

Secrets MUST NOT be written to disk.

Mandatory redaction targets:
- SMTP credentials
- SNMP community strings / auth secrets
- Authentication bind passwords or tokens

Redaction MUST be applied centrally via LNV.AsBuiltDoc.Core.

---

## 12. Compatibility & Stability Guarantees

- Dataset filenames and semantics are stable
- Fields may be added, not removed
- Breaking changes require ADR + versioned contract update

---

## 13. Non-Goals

- Parsing or scraping PScribo output
- Enforcing render-time gating
- Parallel execution

---

## 14. Notes

This contract intentionally prefers over-collection.
Missing data due to permissions is expected and handled via coverage.
