# Lenovo XCC Collector Contract

Direct-v1 collector contract for Lenovo ThinkSystem XClarity Controller using HTTPS Redfish.

The collector emits `lnv.collector.dataset.v1` dataset envelopes and supports plan-driven targets with `kind: lenovo.xcc`.

Required Redfish probes:

- `/redfish/v1/`
- `/redfish/v1/Systems`
- `/redfish/v1/Managers`
- `/redfish/v1/Chassis`
- `/redfish/v1/UpdateService/FirmwareInventory`

Optional Redfish domains include processors, memory, Ethernet interfaces, storage, power, thermal, event log, security, and users summary. Optional failures are represented as warnings and may produce a target status of `partial`.
