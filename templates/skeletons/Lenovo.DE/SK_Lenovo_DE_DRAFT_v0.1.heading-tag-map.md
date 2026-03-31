# Lenovo.DE manual tag placement (DOCX headings are source of truth)

Use this as:

# Heading path in DOCX
`<SDT: tag>`

## Current mapping alignment snapshot (runtime mapping vs template tokens)

Source: `templates/skeletons/Lenovo.DE/DE-SDT-Collector.token-audit.md`

- Unique template SDT tokens: **22**
- Matched by runtime mapping/contract tags: **22**
- Unmatched tokens: **0**

### Projection surface alignment
- Projection tags (including aliases): **25**
- Template tokens present in projection tag surface: **21**
- Template tokens not in projection tag surface: **1**
  - `LNV.Lenovo.DE.System[ArrayName].Summary`

### Template token alignment checklist
- ✅ `LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory`
- ✅ `LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Summary` *(mapped; not in projection tag surface)*
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesKeyFeatures`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesLimits`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.Controllers`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.DNS`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.HostGroups`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.HostGroupsToVolumes`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.Hosts`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.HostsToHostGroups`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.HostsToVolumes`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.Time`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.Transport`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.Trays`
- ✅ `LNV.Lenovo.DE.System[ArrayName].Tables.VolumeMappings`
- ✅ `LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory`

## Replace in document order (aligned to current SK DOCX section flow)

# Platform Configuration / System Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Summary>>

# Platform Configuration / Hardware Configuration / Controller Inventory
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Controllers>>

# Platform Configuration / Hardware Configuration / Tray / Shelf Inventory
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Trays>>

# Platform Configuration / Hardware Configuration / Drive Inventory
<<SDT: LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory>>

# Platform Configuration / Controller Configuration / Management Interfaces
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces>>

# Platform Configuration / Controller Configuration / DNS Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.DNS>>

# Platform Configuration / Controller Configuration / Time Configuration
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Time>>

# Platform Configuration / Controller Configuration / Transport Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Transport>>

# Platform Configuration / Controller Configuration / Transport Summary (insert above host-port sections)
Transports configured:
<<SDT: LNV.Lenovo.DE.System[ArrayName].Narrative.ActiveTransport>>

# Platform Configuration / Controller Configuration / Host Port Configuration - iSCSI
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI>>

# Platform Configuration / Controller Configuration / Host Port Configuration - Fibre Channel
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC>>

# Platform Configuration / Storage Configuration / Storage Containers / Pools / Volume Groups
<<SDT: LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory>>

# Platform Configuration / Storage Configuration / Volumes
<<SDT: LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory>>

# Platform Configuration / Host Connectivity / Host Definitions
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.Hosts>>

# Platform Configuration / Host Connectivity / Host Groups
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostGroups>>

# Platform Configuration / Host Connectivity / Host to Host Group Relationships
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostsToHostGroups>>

# Platform Configuration / Host Connectivity / Host Group to Volume Presentation
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostGroupsToVolumes>>

# Platform Configuration / Host Connectivity / Direct Host to Volume Presentation
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.HostsToVolumes>>

# Platform Configuration / Security Configuration / Alerts & AutoSupport
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport>>

# Platform Configuration / Performance & Cache Configuration / Capabilities Summary
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary>>

# Platform Configuration / Performance & Cache Configuration / Key Features
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesKeyFeatures>>

# Platform Configuration / Performance & Cache Configuration / Feature Limits / Consumption
<<SDT: LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesLimits>>

## Available but not placed in template (for future insertion)

# System Overview / Key Design Decisions (optional future)
<<SDT: LNV.Lenovo.DE.System[ArrayName].Narrative.Config>>
