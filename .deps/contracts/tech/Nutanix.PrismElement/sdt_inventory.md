# Nutanix.PrismElement — Skeleton SDT Inventory v1 (STUB) (LOCKED INTENT)

## Status
**STUB** (intended for first Nutanix skeleton build)  
Once the Nutanix DOCX skeleton is produced and validated end-to-end, mark this document **LOCKED**.

---

## 1. Purpose

Defines the **Content Control (SDT) tags** the Nutanix.PrismElement technology skeleton must contain,
so the AsBuiltDoc Assembler can populate content deterministically from datasets.

This inventory is aligned to the AsBuiltDoc common spine (Front Matter → Exec Summary → Core Ops → Appendices).

---

## 2. Tag Taxonomy

**Base taxonomy:**

```
LNV.Nutanix.PrismElement.<Domain>[<Key>].<BlockType>
```

Where:
- `<Domain>` ∈ `Cluster | Host | Network | StorageContainer | StoragePool | VM | CVM | VolumeGroup | ProtectionDomain | RemoteSite | Licensing | Health | Alerts | Smtp | Snmp | Auth`
- `<Key>` = stable object key (uuid preferred; else name)
- `<BlockType>` ∈ `Summary | Config | Tables.<Name> | Findings | Evidence`

**Examples**
- `LNV.Nutanix.PrismElement.Cluster[3f2a...].Summary`
- `LNV.Nutanix.PrismElement.Cluster[3f2a...].Tables.Hosts`
- `LNV.Nutanix.PrismElement.Host[9a11...].Tables.StorageAdapters`

---

## 3. Keying Rules

Preferred keys (to keep tags stable):
- Cluster: `uuid`
- Host: `uuid`
- Network: `uuid`
- StorageContainer: `storage_container_uuid`
- StoragePool: `uuid`
- VM/CVM: `uuid`
- VolumeGroup: `uuid`
- ProtectionDomain: `name` (use `uuid` if available in dataset)
- RemoteSite: `name` (use `uuid` if available in dataset)

---

## 4. Spine Placement

### 4.1 Main Body (Core Spine)
Main body should contain:
- concise summaries
- high-value config tables
- key findings

Large inventories go to Appendices.

### 4.2 Appendices
Appendices contain:
- large inventory tables (VMs, disks, NICs)
- deep evidence (health checks, alert configs, sensitive-but-redacted configs)

---

## 5. Required SDTs (Minimum Viable)

> NOTE: The Nutanix technology skeleton should include a **technology module section** in the common spine.
> These SDTs live within that module.

### 5.1 Cluster (Main)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Summary` | Summary | Paragraphs |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.ClusterConfig` | Tables.ClusterConfig | Table |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.FaultTolerance` | Tables.FaultTolerance | Table |
| `LNV.Nutanix.PrismElement.Licensing[<ClusterKey>].Tables.Licenses` | Tables.Licenses | Table |

Optional (Main):
- `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Findings`

### 5.2 Hosts (Main)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Hosts` | Tables.Hosts | Table |

### 5.3 Networks (Main)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Networks` | Tables.Networks | Table |

### 5.4 Storage (Main)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.StorageContainers` | Tables.StorageContainers | Table |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.StoragePools` | Tables.StoragePools | Table |

### 5.5 Virtual Machines (Main)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.VMs` | Tables.VMs | Table |

### 5.6 Protection / DR (Main)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.ProtectionDomains` | Tables.ProtectionDomains | Table |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.RemoteSites` | Tables.RemoteSites | Table |

---

## 6. Appendix SDTs (Recommended)

### 6.1 Host Detail (Appendix)

These are **repeatable** blocks (one per Host). The skeleton can either:
- provide per-host subsections with fixed SDTs (preferred for v1), or
- provide a single placeholder SDT for repeated insertion (assembler-dependent)

Minimum per-host tags:

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Host[<HostKey>].Summary` | Summary | Paragraphs |
| `LNV.Nutanix.PrismElement.Host[<HostKey>].Tables.HostConfig` | Tables.HostConfig | Table |

Optional per-host (as data becomes available / useful):
- `...Tables.NetworkAdapters`
- `...Tables.Storage`
- `...Evidence`

### 6.2 CVMs (Appendix)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.CVMs` | Tables.CVMs | Table |

### 6.3 VM NICs (Appendix)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.VMNics` | Tables.VMNics | Table |

### 6.4 Datastores (Conditional) (Appendix)

Only for VMware environments / if `datastores.json` exists.

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Datastores` | Tables.Datastores | Table |

### 6.5 Volume Groups (Appendix)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.VolumeGroups` | Tables.VolumeGroups | Table |

### 6.6 Disks (Appendix)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Disks` | Tables.Disks | Table |

### 6.7 Health Checks (Appendix)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Health[<ClusterKey>].Tables.HealthChecks` | Tables.HealthChecks | Table |

### 6.8 Alerts / Notifications (Appendix)

| SDT Tag | Block Type | Intended Render |
|--------|------------|-----------------|
| `LNV.Nutanix.PrismElement.Alerts[<ClusterKey>].Tables.AlertConfiguration` | Tables.AlertConfiguration | Table |
| `LNV.Nutanix.PrismElement.Smtp[<ClusterKey>].Tables.SmtpConfig` | Tables.SmtpConfig | Table |
| `LNV.Nutanix.PrismElement.Snmp[<ClusterKey>].Tables.SnmpConfig` | Tables.SnmpConfig | Table |
| `LNV.Nutanix.PrismElement.Auth[<ClusterKey>].Tables.AuthConfig` | Tables.AuthConfig | Table |

---

## 7. Evidence Placeholders

For each major domain, the skeleton SHOULD include an evidence placeholder SDT to support:
- raw JSON excerpts (sanitized)
- screenshots references
- operator notes

Recommended tags:
- `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Evidence.Placeholder`
- `LNV.Nutanix.PrismElement.Host[<HostKey>].Evidence.Placeholder`

---

## 8. Implementation Notes (Skeleton Authoring)

- SDTs must use **Tag** (not Title) as the stable identifier
- Tag strings must match exactly (case-sensitive)
- Avoid Word repeating controls unless assembler explicitly supports repeaters
- Prefer “fixed SDT positions” in v1:
  - cluster-level SDTs are singletons
  - host-level SDTs can be present as a template section per host *or* as a single appendix table if you want v1 simpler

---

## 9. Example Rendering Notes (Mapping-Aware)

Use `tech/Nutanix.PrismElement/mapping.dataset-to-sdt.v1.yaml` as the binding source between datasets and SDT tags.

- Resolve `<ClusterKey>` from `cluster.uuid` when available (fallback: cluster name).
- Render required Section 5 SDTs first in the main spine before optional appendix SDTs.
- For table SDTs, skip empty rows but keep table headers to make “no data collected” explicit.
- Keep `required: true` mappings deterministic and non-conditional; reserve conditional logic for optional appendix renderers.

## 10. Required SDT Coverage Checklist

The following required Section 5 tags must remain covered by dataset mapping entries.

| Required SDT Tag | Source Dataset | Mapping Coverage |
|---|---|---|
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Summary` | `cluster` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.ClusterConfig` | `cluster` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.FaultTolerance` | `cluster` | ✅ |
| `LNV.Nutanix.PrismElement.Licensing[<ClusterKey>].Tables.Licenses` | `license` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Hosts` | `hosts` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Networks` | `networks` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.StorageContainers` | `storage_containers` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.StoragePools` | `storage_pools` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.VMs` | `vms` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.ProtectionDomains` | `protection_domains` | ✅ |
| `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.RemoteSites` | `remote_sites` | ✅ |

## 11. Next Refinements (Post-First Run)

After first real bundle + assembly:
- Confirm actual dataset keys for ProtectionDomain/RemoteSite (name vs uuid)
- Decide whether Host detail is per-host sections or a single “Hosts detail table”
- Add additional SDTs as customer requirements emerge (keep backwards compatible)

---
