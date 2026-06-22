# AGENTS.md

## Scope
This file applies to the entire repository tree rooted at `/workspace/LNV.AsBuiltDoc.Assembler`.

## Repository intent
- This repo owns the **assembler runtime**, skeleton assets, tests, and assembler-focused documentation.
- This repo does **not** own the long-term source of truth for contracts under `.deps/contracts`; that content is owned by the contracts repo and is only mirrored here as a synced runtime dependency.

## Working rules for agents
- Prefer contract-driven designs over adding technology-specific logic to `scripts/Invoke-AssemblerSdtRender.ps1` or other invoke/orchestration scripts.
- Treat `.deps/contracts` as a **runtime snapshot**, not the canonical authoring location.
- If you must modify or add files under `.deps/contracts` in this repo, mirror owned handoff artifacts in the contributing/owner repository's `exports/LNV.AsBuiltDoc.Contracts/...` tree, not in this assembler repo. For Lenovo.XCC, that export mirror belongs under the XCC/Core repo.
- Keep assembler docs aligned with the current contract-driven projection model:
  - mapping entries can declare render intent (`renderAs`, `projectionRef`, `view`, and related hints)
  - projection contracts define shaping/filters/columns and rendering behavior
  - dataset presentation sidecars under `tech/<techId>/dataset/*.assembler.meta.json` describe document intent upstream
  - raw JSON is evidence/debug output, not the default rendering for document-facing table SDTs

## Documentation expectations
When updating docs for projection/render behavior, ensure they cover these facts where relevant:
- The assembler should remain generic and consume declarative contract intent.
- Collector-facing normalization should be represented in contracts and dataset presentation metadata, not re-implemented as ad hoc renderer logic.
- `templates/skeletons/<tech>/...mapping.json` is runtime-facing and should stay aligned with the authoritative contract mapping in `.deps/contracts/tech/<techId>/mapping.dataset-to-sdt.v1.yaml`.
- If `.deps/contracts` content is edited here for handoff, note that the owner-repo export mirror exists specifically so those changes can be moved offline into the contracts repo.

## Safety / quality
- Do not silently introduce new renderer fallbacks that turn structured document-facing data into raw JSON.
- Prefer fail-closed or explicit contract policy for table/list/scalar rendering.
- Keep examples and docs consistent with existing repo paths and current runtime behavior.
