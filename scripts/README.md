# Assembler scripts

Runtime direction is **PowerShell 7**.

Implemented bootstrap script:
- `Invoke-AssemblerPipeline.ps1` - ingests required Direct-v1 bundle inputs, loads `solution.plan` schema, applies minimum contract checks, and emits JSON diagnostics/report

Planned additional scripts:
- `Test-AssemblerContracts.ps1` - validates input contracts/mappings
- `New-AssemblerRenderPlan.ps1` - emits normalized render plan JSON
