# Lenovo XCC Collector Contract

The Direct-v1 collector emits normalized `lnv.collector.dataset.v1` envelopes
under `datasets/Lenovo.XCC/collector-out/target_<key>/`.

The exported contract pack is contribution-ready:

- schemas constrain the envelope, common identity fields, and projected fields
- dataset sidecars declare target-scoped paths and presentation intent
- the mapping binds normalized datasets to `LNV.Lenovo.XCC.*` SDT tags
- projections define explicit reader-facing table columns

`network-interfaces` is retained as compatibility evidence. Its normalized twin,
`ethernet-interfaces`, is the only network dataset mapped for presentation.
The host port datasets preserve MAC, WWPN/WWNN, IQN/IP where available, and
optional switch hints for later cross-system diagram joins. Raw endpoint output
is excluded from presentation contracts.

The customer-facing `Document.*` projections are intentionally compact and
hostname-first. They repeat server identity on port rows so XCC can be joined to
OS, hypervisor, Prism, DE, DM/ONTAP, Azure, or future topology datasets without
rendering duplicate raw port inventory in the final document.

Host port link state keeps the reported Redfish value and separately exposes the
effective document-facing value, source, and conflict flag. Memory keeps raw DIMM
speed and separately exposes a display value so disabled DIMMs render as disabled
instead of presenting firmware placeholder speeds as operating speed.
