# Lenovo XCC Host-Skeleton Contribution Blueprint

XCC contributes blocks to another technology's skeleton; it does not own a
standalone production skeleton. Host skeleton authors may place any canonical
`LNV.Lenovo.XCC.*` tag where server management-controller evidence is required.

Recommended order:

1. XCC system summary and collection status
2. Manager, chassis, and firmware
3. Processor, memory, and network inventory
4. Storage inventory
5. Power and thermal state
6. Security, users, and event-log appendices

Required datasets use `emptyBehavior: error`. Optional datasets use a controlled
placeholder. Raw Redfish evidence is never mapped to document-facing tags.

The contribution contract deliberately does not define cross-technology render
orchestration. The Assembler must eventually support applying multiple technology
mappings to one host skeleton while preserving each technology's namespace.
