# Assembler Error Model — v1

Error code prefix: `ASB-ASM-`.

Recommended classes:
- `ASB-ASM-INPUT-*` input contract failures
- `ASB-ASM-CONTRACT-*` schema/mapping compatibility failures
- `ASB-ASM-TRANSFORM-*` model-building and selector/grouping failures
- `ASB-ASM-RENDER-*` SDT merge/render failures
- `ASB-ASM-OUTPUT-*` output write/finalization failures

Severity model:
- `ERROR` terminates run when issue is fatal
- `WARN` run may continue with degraded output
- `INFO` diagnostic context only

Each issue record should include:
- code
- severity
- message
- optional path/selector/tag context
