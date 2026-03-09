# Assembler GUI staging

PowerShell 7 launcher:
- `Start-AssemblerGui.ps1`

Current workflow:
- prompts for `BundleRoot` and `SkeletonRoot`
- discovers `*.mapping.json` and `*.template.txt` in the skeleton directory
- invokes `scripts/Invoke-AssemblerSdtRender.ps1`
- writes outputs under `./out` by default

Contract prerequisite:
- run `scripts/Sync-AssemblerContractsToRepo.ps1` to hydrate `.deps/contracts`
- renderer auto-resolves contracts from `-ContractsRoot`, then `.deps/contracts`, then `export/repo-ready/contracts`

MVP panels still planned:
- Bundle selection
- Contract/mapping validation summary
- Required vs optional mapping coverage
- Render execution and report viewer
