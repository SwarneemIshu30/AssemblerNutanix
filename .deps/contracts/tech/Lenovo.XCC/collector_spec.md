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
Raw endpoint output is excluded from presentation contracts.
