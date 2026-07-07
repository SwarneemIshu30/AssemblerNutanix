# Lenovo XCC Host-Skeleton Contribution Blueprint

XCC contributes blocks to another technology's skeleton; it does not own a
standalone production skeleton. Host skeleton authors may place any canonical
`LNV.Lenovo.XCC.*` tag where server management-controller evidence is required.

Recommended order:

1. Vital product data and server identity
2. Firmware baseline
3. Processor, memory, and storage summary
4. Management Ethernet, host Ethernet, and FC ports
5. Optional topology graph inputs
6. Diagnostic appendices when explicitly requested

Required datasets use `emptyBehavior: error`. Optional datasets use a controlled
placeholder. `host-fc-ports` renders `No FC adapters discovered` when no FC
adapter/function is present. Raw Redfish evidence, collection status, PCIe raw
tables, detailed sensors, empty virtual-media slots, and duplicate adapter-port
views are diagnostic output and are not part of the preferred `Document.*`
projection set.

The contribution contract deliberately does not define cross-technology render
orchestration. The Assembler must eventually support applying multiple technology
mappings to one host skeleton while preserving each technology's namespace.
