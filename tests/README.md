# Assembler tests

Focus on deterministic behavior:
- Mapping precedence and selector handling
- Grouping/sorting reproducibility
- Required dataset missing vs optional missing behavior
- Error-classification and render-report schema validation

## Runtime direction

Test automation should target the PowerShell 7 entrypoints (Pester-based where available).
