# Assembler scripts

Runtime direction is **PowerShell 7**.

Implemented bootstrap script:
- `Invoke-AssemblerPipeline.ps1` - ingests required Direct-v1 bundle inputs, loads `solution.plan` schema, applies minimum contract checks, and emits JSON diagnostics/report

## Runtime parameters

### `-BundleRoot` (required)
Path to the Direct-v1 bundle root.

Required files under this root:
- `manifest.json`
- `objectIndex.json`
- `config/solution.plan.json`

### `-ContractsRoot` (required)
Path to contracts root containing:
- `standards/solution.plan.schema.v1.json`

### `-OutputPath` (optional)
Path to write the resulting JSON report.

Behavior:
- If supplied: writes JSON report to file.
- If omitted: writes JSON report to stdout.

## Output contract (bootstrap)

Current report shape:
- `schemaVersion`
- `status` (`ok` or `error`)
- `bundle` (present when successful)
  - `root`
  - `manifestSchemaVersion`
  - `objectCount`
  - `solutionId`
  - `targetCount`
  - `collectorCount`
- `diagnostics[]`
  - `tsUtc`
  - `stage`
  - `level`
  - `code`
  - `message`

## Exit codes

- `0`: successful bootstrap ingest (`status=ok`)
- `1`: failed bootstrap ingest (`status=error`)

## Examples

```powershell
pwsh ./scripts/Invoke-AssemblerPipeline.ps1 \
  -BundleRoot ./sample/bundle \
  -ContractsRoot ./export/repo-ready/contracts
```

```powershell
pwsh ./scripts/Invoke-AssemblerPipeline.ps1 \
  -BundleRoot ./sample/bundle \
  -ContractsRoot ./export/repo-ready/contracts \
  -OutputPath ./out/assembler-bootstrap-report.json
```

Planned additional scripts:
- `Test-AssemblerContracts.ps1` - validates input contracts/mappings
- `New-AssemblerRenderPlan.ps1` - emits normalized render plan JSON
