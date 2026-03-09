# Echo Collector Spec (Harness)

**TechId:** EchoB  
**Purpose:** Harness/reference collector used to validate the AsBuiltDoc Core execution pipeline.

## Entry point
- Default function: `Invoke-LnvCollector.EchoB`

## Expected outputs (per target)
- Dataset: `datasets/EchoB/echo/<targetKey>/hello.json`
- Coverage: `datasets/EchoB/core/<targetKey>/coverage.json`
- Object index: `objectIndex.json` contains one entry per target:
  - `{ techId: "EchoB", kind: <target.kind>, key: <target.key>, displayName: <target.displayName> }`

## Fault injection (test only)
Collectors MAY support `collector.params.forceFail = true` to throw intentionally for CI validation of failure isolation.
