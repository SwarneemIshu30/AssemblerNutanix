# Nutanix.PrismElement — Skeleton Section Blueprint v1 (STUB)

## Status
**STUB** — use to author the first Nutanix technology skeleton module.  
After first end-to-end assembly (datasets → assembler → DOCX), promote to **LOCKED**.

---

## 1. Purpose

This blueprint is a **layout guide** for placing Nutanix.PrismElement SDTs inside the
**AsBuiltDoc common spine**.

It does **not** define styles; it defines:
- headings (H1/H2/H3) to create
- where SDTs should be placed
- what goes to Main vs Appendix

Reference:
- `collector_spec.md` (dataset contract)
- `manifest.yaml` (assembler mapping contract)
- `sdt_inventory.md` (SDT tag list)

---

## 2. Placement Model

- **Main body:** summaries + key configuration tables + DR posture
- **Appendices:** large inventories + evidence + deep operational tables

---

## 3. Technology Module Insertion Point (Common Spine)

Insert the Nutanix module under the common spine’s technology section, e.g.:

- **4. Technology**
  - **4.X Nutanix Prism Element**  *(this module)*

> Exact numbering is handled by the common spine; use heading levels consistently.

---

## 4. Nutanix Prism Element Module Layout (Main)

### H2: Nutanix Prism Element

Brief intro text (1–2 paragraphs):
- what was collected
- Prism Element endpoint(s)
- collection date/time (if you surface it)
- any notable limitations (from coverage)

#### H3: Overview

Place:
- **SDT:** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Summary`

Optional:
- Findings paragraph under it:
  - **SDT:** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Findings`

#### H3: Cluster Configuration

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.ClusterConfig`
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.FaultTolerance`
- **SDT (table):** `LNV.Nutanix.PrismElement.Licensing[<ClusterKey>].Tables.Licenses`

#### H3: Hosts

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Hosts`

Author note:
- Keep this as the “summary host table”.
- Host-by-host detail belongs in Appendix v1.

#### H3: Networking

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Networks`

#### H3: Storage

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.StorageContainers`
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.StoragePools`

#### H3: Virtual Machines

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.VMs`

#### H3: Protection and Disaster Recovery

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.ProtectionDomains`
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.RemoteSites`

---

## 5. Nutanix Appendices

> Appendices live in the common spine’s Appendix section.
> Add a Nutanix-specific appendix heading to group Nutanix inventories.

### H2 (Appendix): Appendix — Nutanix Prism Element

#### H3: Host Detail

Preferred v1 approach:
- Use **one** appendix table or a small set of tables rather than repeating per-host subsections.
- If you *do* implement per-host sections, keep them minimal.

Place either:

**Option A (simple, recommended):** one “Host detail” table SDT
- **SDT:** `LNV.Nutanix.PrismElement.Host[<HostKey>].Tables.HostConfig`
  - (Assembler will need to support emitting a consolidated view. If not supported, stick to Option B.)

**Option B (repeatable sections):** per-host subsections
- **Heading:** `Host: <Host Display Name>`
- **SDT:** `LNV.Nutanix.PrismElement.Host[<HostKey>].Summary`
- **SDT:** `LNV.Nutanix.PrismElement.Host[<HostKey>].Tables.HostConfig`
- **SDT:** `LNV.Nutanix.PrismElement.Host[<HostKey>].Evidence.Placeholder` *(optional)*

> If Word authoring effort is high, start with Main-body host summary only and defer host detail to v2.

#### H3: Controller VMs (CVMs)

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.CVMs`

#### H3: VM Networking (NICs)

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.VMNics`

#### H3: Datastores (VMware only)

Conditional section (include the heading; assembler may leave it empty if dataset missing):

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Datastores`

#### H3: Volume Groups

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.VolumeGroups`

#### H3: Disks

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Tables.Disks`

#### H3: Health Checks

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Health[<ClusterKey>].Tables.HealthChecks`

#### H3: Alerts and Notifications

Place:
- **SDT (table):** `LNV.Nutanix.PrismElement.Alerts[<ClusterKey>].Tables.AlertConfiguration`
- **SDT (table):** `LNV.Nutanix.PrismElement.Smtp[<ClusterKey>].Tables.SmtpConfig`
- **SDT (table):** `LNV.Nutanix.PrismElement.Snmp[<ClusterKey>].Tables.SnmpConfig`
- **SDT (table):** `LNV.Nutanix.PrismElement.Auth[<ClusterKey>].Tables.AuthConfig`

---

## 6. Evidence & Operator Notes

At the end of the Nutanix appendix section, add:

#### H3: Evidence and Notes

Place:
- **SDT:** `LNV.Nutanix.PrismElement.Cluster[<ClusterKey>].Evidence.Placeholder`

Optional (if you add per-host sections):
- per-host evidence placeholder tags as listed in `sdt_inventory.md`

---

## 7. Skeleton Authoring Rules (v1)

- SDT **Tag** is the stable ID; set Tag exactly to the values listed.
- SDT Titles can be friendly; Titles are not relied upon.
- Don’t use Word repeaters unless explicitly supported by the assembler.
- Prefer fixed SDT locations and “table-first” rendering for inventories.

---

## 8. v1 Acceptance Checklist

A Nutanix skeleton is considered “good enough” when:

- All Main-body SDTs exist and are in the expected headings
- Appendix contains the major inventory SDTs
- Assembly produces a DOCX with:
  - no missing SDT tags reported (except where dataset is legitimately missing)
  - sensible empty handling for conditional sections (e.g., Datastores)
  - tables render with LNV table style normalization applied by Tools add-in

---
