# Assembler docs

This folder holds repository-specific documentation such as:
- architecture notes
- lifecycle details
- operator runbooks
- troubleshooting

Key current topics that should be documented here:
- contract-driven SDT projection/view behavior
- runtime packaging policy for bundled/pinned contracts and supported contract update paths
- sync quality-gate behavior for contract-to-runtime mapping generation (statuses, skip reasons, strict empty-generation policy)
- ownership boundaries between assembler and contracts
- offline handoff rules for mirrored contract artifacts under `exports/LNV.AsBuiltDoc.Contracts/...`

See also:
- `docs/contract-driven-projections.md`
- `docs/mapping-studio-wip.md`
- `AGENTS.md`

Stale staging and handoff artifacts have been removed from the standalone repository. Add new docs here only when they reflect current assembler ownership and runtime behavior.
