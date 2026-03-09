# Echo Collector Spec (Harness)

**TechId:** EchoC  
**Purpose:** Harness/reference collector used to validate the AsBuiltDoc Core execution pipeline.

## Entry point
- Default function: `Invoke-LnvCollector.EchoC`

## Expected outputs (per target)
- Dataset: `datasets/EchoC/echo/<targetKey>/hello.json`
- Coverage: `datasets/EchoC/core/<targetKey>/coverage.json`
- Object index: `objectIndex.json` contains one entry per target:
  - `{ techId: "EchoC", kind: <target.kind>, key: <target.key>, displayName: <target.displayName> }`

## Fault injection (test only)
Collectors MAY support `collector.params.forceFail = true` to throw intentionally for CI validation of failure isolation.
