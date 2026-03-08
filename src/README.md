# Assembler runtime source

Planned runtime stages:
1. Load bundle and contracts
2. Validate bundle + mapping compatibility
3. Build render model per target/system scope
4. Execute SDT rendering pipeline
5. Emit render report and diagnostics

## Runtime direction

Assembler bootstrap runtime direction is **PowerShell 7-based**.

Initial runnable entrypoint:
- `scripts/Invoke-AssemblerPipeline.ps1`

This script currently performs bootstrap ingestion + minimum solution plan contract checks and emits a machine-readable report with stage diagnostics.
