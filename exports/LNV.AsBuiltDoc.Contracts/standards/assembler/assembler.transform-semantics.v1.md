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
- Selectors are applied in listed order (left-to-right).
- Selector evaluation is AND-composed by default.
- Unknown selector fields in strict mode => error.
- A selector may resolve to zero rows, one row, many rows, or a single object value. Projection semantics below define how each outcome is normalized before rendering.

## Projection declaration semantics
### `renderAs`
- `renderAs` is the projection-level rendering intent and should be preferred over legacy `renderMode` when both are present.
- Supported intents are `scalar`, `table`, `list`, `json-evidence`, and `json-debug`.
- If both `renderAs` and `renderMode` are supplied they MUST agree after normalization; disagreement is a contract error.

### `emptyBehavior`
- `render-empty`: emit the target render unit even when the selector yields zero rows. For tables/lists this means headers with zero body rows; for scalar/object-like outputs this means an empty value.
- `omit`: do not emit the render unit when the selector yields zero rows.
- `placeholder`: emit the render unit with profile-defined placeholder content.
- `error`: treat a zero-row result as a transformation error.
- If `emptyBehavior` is omitted, the default is `render-empty`.

### `rowOrder`
- `rowOrder` is an ordered list of sort keys applied left-to-right.
- A string item is shorthand for `{ "by": "<field>", "direction": "asc", "nulls": "last" }`.
- Object items may declare `direction` (`asc` or `desc`) and null placement (`first` or `last`).
- `rowOrder` takes precedence over legacy `sortBy`. If only `sortBy` is present, it behaves as a single ascending `rowOrder` entry.
- When no explicit row ordering is declared, use the default ordering semantics defined below.

### `identityKeys`
- `identityKeys` lists fields that uniquely identify a logical row within the projection result.
- Assemblers may use these keys to stabilize row comparisons, de-duplicate repeated objects, and correlate formatting or evidence annotations.
- Identity evaluation is performed after selector filtering and before final ordering.
- If an identity key is missing from a row, the row still renders, but strict validation may emit a warning because row identity is incomplete.

### `formatProfiles`
- `formatProfiles` is an optional ordered list of named formatting profiles.
- Profiles are applied after row selection/order resolution and before final emission.
- Unknown formatting profile names are contract errors in strict mode and warnings otherwise.
- Column-level directives such as `format` still apply; `formatProfiles` augment the projection with reusable named formatting rules.

## Projection result normalization
### Selector resolves to zero rows
- Apply `emptyBehavior` exactly as declared.
- For `renderAs=table` or `renderAs=list`, zero rows is still a valid result unless `emptyBehavior=error`.
- For `renderAs=scalar`, zero rows yields an empty scalar, omission, placeholder, or error according to `emptyBehavior`.

### Selector resolves to one object
- `renderAs=table` or `renderAs=list`: normalize the single object into a one-row collection and continue.
- `renderAs=scalar`: if a single scalar-capable field/value is addressed, emit that value; if the resolved value is a structured object, apply the structured value policy.
- `renderAs=json-evidence` and `renderAs=json-debug`: emit the single object without coercing it into table cells.

### Selector resolves to many rows
- `renderAs=table` and `renderAs=list`: render each normalized row after filtering, identity assignment, and ordering.
- `renderAs=scalar`: multiple rows are a type mismatch unless an upstream mapping explicitly reduces them to one value.
- `renderAs=json-evidence` and `renderAs=json-debug`: emit the multi-row structure as JSON evidence/debug output.

### Type mismatch handling
- A type mismatch occurs when the resolved selector value cannot satisfy the declared rendering intent, such as:
  - `renderAs=table` but the selector resolves to a scalar primitive.
  - `renderAs=scalar` but the selector resolves to multiple rows or an unresolved structured object without a scalar extraction rule.
  - `renderAs=list` but the selector resolves to a primitive scalar.
- Type mismatches are transformation errors in strict mode.
- In non-strict mode, emit a warning and then:
  - apply `structuredValuePolicy` for structured-to-scalar mismatches,
  - emit placeholder content if `emptyBehavior=placeholder` and no legal coercion exists,
  - otherwise omit the render unit.

## Grouping semantics
- Group key must be explicit in mapping notes/metadata.
- Missing group key values map to `_ungrouped`.
- Group ordering is lexical unless explicit order list is provided.

## Ordering semantics
Default row order precedence:
1. Explicit `rowOrder`
2. Legacy mapped sort key via `sortBy`
3. Stable natural key from `identityKeys`
4. Stable natural key (`id`, `name`, `key`) if present
5. Original dataset order as final fallback

## Null and empty rendering
- `null` -> empty field (not string `"null"`).
- Missing property -> empty field + warning only if required.
- Empty arrays -> section/table with zero rows unless the projection `emptyBehavior` or active profile says otherwise.

## Required mapping behavior
- `required=true` and unresolved dataset => error.
- `required=true` with zero items => warning or error per profile policy.
- `required=false` unresolved => warn/skipped.

## Multi-target scoping
- Mapping operations are scoped by target context unless explicitly global.
- Cross-target merges require explicit merge directive.

## Formatting
- Byte, duration, and datetime formatting rules must be profile-defined and deterministic.
- Booleans should use profile standard labels (e.g., Yes/No).
- Projection `formatProfiles` are applied in declaration order after built-in normalization and before final value emission.
