# Lenovo.DE collector token audit

## Scope
- Template: `templates/skeletons/Lenovo.DE/DE-SDT-Collector.template.txt`
- Runtime mapping: `templates/skeletons/Lenovo.DE/DE-SDT-Collector.mapping.json`
- Contract mapping: `.deps/contracts/tech/Lenovo.DE/mapping.dataset-to-sdt.v1.yaml`
- Projection contract: `.deps/contracts/tech/Lenovo.DE/assembler.projections.v1.json`

## Current token inventory grouped by prefix
### Summary (1)
- `LNV.Lenovo.DE.System[ArrayName].Summary`
### Tables (21)
- `LNV.Lenovo.DE.Drive[DriveID].Tables.Inventory`
- `LNV.Lenovo.DE.Pool[PoolName].Tables.Inventory`
- `LNV.Lenovo.DE.System[ArrayName].Tables.AutoSupport`
- `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesKeyFeatures`
- `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesLimits`
- `LNV.Lenovo.DE.System[ArrayName].Tables.CapabilitiesSummary`
- `LNV.Lenovo.DE.System[ArrayName].Tables.Controllers`
- `LNV.Lenovo.DE.System[ArrayName].Tables.DNS`
- `LNV.Lenovo.DE.System[ArrayName].Tables.HostGroups`
- `LNV.Lenovo.DE.System[ArrayName].Tables.HostGroupsToVolumes`
- `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC`
- `LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsiSCSI`
- `LNV.Lenovo.DE.System[ArrayName].Tables.Hosts`
- `LNV.Lenovo.DE.System[ArrayName].Tables.HostsToHostGroups`
- `LNV.Lenovo.DE.System[ArrayName].Tables.HostsToVolumes`
- `LNV.Lenovo.DE.System[ArrayName].Tables.ManagementInterfaces`
- `LNV.Lenovo.DE.System[ArrayName].Tables.Time`
- `LNV.Lenovo.DE.System[ArrayName].Tables.Transport`
- `LNV.Lenovo.DE.System[ArrayName].Tables.Trays`
- `LNV.Lenovo.DE.System[ArrayName].Tables.VolumeMappings`
- `LNV.Lenovo.DE.Volume[VolumeName].Tables.Inventory`
### Config (0)
- _None_
### Evidence (0)
- _None_

## Runtime mapping + contract comparison
- Unique template SDT tokens: **22**
- Matched by runtime mapping/contract tags: **22**
- Unmatched tokens: **0**

## Projection alignment
- Projection tags (including aliases): **25**
- Template tokens present in projection tag surface: **21**
- Template tokens not in projection tag surface: **1**
- `LNV.Lenovo.DE.System[ArrayName].Summary`
