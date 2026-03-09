# Echo Collector Spec (Harness)

**TechId:** EchoA  
**Purpose:** Harness/reference collector used to validate the AsBuiltDoc Core execution pipeline.

## Entry point
- Default function: `Invoke-LnvCollector.EchoA`

## Expected outputs (per target)
- Dataset: `datasets/EchoA/echo/<targetKey>/hello.json`
- Coverage: `datasets/EchoA/core/<targetKey>/coverage.json`
- Object index: `objectIndex.json` contains one entry per target:
  - `{ techId: "EchoA", kind: <target.kind>, key: <target.key>, displayName: <target.displayName> }`

## Fault injection (test only)
Collectors MAY support `collector.params.forceFail = true` to throw intentionally for CI validation of failure isolation.
