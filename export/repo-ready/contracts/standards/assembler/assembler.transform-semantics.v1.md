# Assembler Transformation Semantics (Dataset -> SDT) — v1

## Goal
Lock deterministic transformation behavior from dataset envelopes to SDT targets.

## Canonical flow
1. Resolve mapping entries for techId
2. Load dataset envelope by `dataset.key`
3. Apply selector filter (if present)
4. Build projection rows/values for target SDT
5. Apply grouping and ordering
6. Emit render units

## Selector semantics
- Selectors are applied in listed order (left-to-right)
- Selector evaluation is AND-composed by default
- Unknown selector fields in strict mode => error

## Grouping semantics
- Group key must be explicit in mapping notes/metadata
- Missing group key values map to `_ungrouped`
- Group ordering is lexical unless explicit order list is provided

## Ordering semantics
Default row order precedence:
1. Explicit mapped sort keys
2. Stable natural key (`id`, `name`, `key`) if present
3. Original dataset order as final fallback

## Null and empty rendering
- `null` -> empty field (not string "null")
- missing property -> empty field + warning only if required
- empty arrays -> section/table with zero rows unless profile suppresses empty blocks

## Required mapping behavior
- `required=true` and unresolved dataset => error
- `required=true` with zero items => warning or error per profile policy
- `required=false` unresolved => warn/skipped

## Multi-target scoping
- Mapping operations are scoped by target context unless explicitly global
- Cross-target merges require explicit merge directive

## Formatting
- Byte, duration, and datetime formatting rules must be profile-defined and deterministic
- Booleans should use profile standard labels (e.g., Yes/No)
