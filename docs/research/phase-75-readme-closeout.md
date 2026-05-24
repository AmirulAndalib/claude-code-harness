# Phase 75 README Surface Closeout

Date: 2026-05-24
Status: copy complete, Pattern A hero images integrated

## What Changed

- `README.md` and `README_ja.md` now lead with user pain, the fastest verified
  route, command internals, workflow gates, support boundaries, migration
  safety, and deeper docs.
- Top-level README copy no longer uses internal code names, obsolete hero
  imagery, or release-history blocks as first-screen product positioning.
- The Japanese README uses Japanese section titles and shorter explanations
  around the support-tier terms.
- `docs/research/readme-visual-asset-manifest.md` defines image-generation
  constraints, official GPT Image model boundary, EN/JA asset pairs, and A/B/C
  visual directions.
- `docs/readme-visual-patterns.html` provides the approval board for image
  direction selection; the user selected Pattern A.
- Pattern A hero images were generated and integrated into `README.md` and
  `README_ja.md`.

## Evidence Sources

- Superpowers: https://github.com/obra/superpowers
- Hermes Agent: https://github.com/NousResearch/hermes-agent
- OpenAI image generation docs:
  - https://platform.openai.com/docs/guides/image-generation
  - https://platform.openai.com/docs/guides/tools-image-generation/
  - https://platform.openai.com/docs/models/gpt-image-1.5
- Local source of truth:
  - `spec.md`
  - `Plans.md`
  - `docs/research/readme-superpowers-hermes-benchmark.md`
  - `docs/research/readme-visual-asset-manifest.md`
  - `docs/tool-capability-matrix.md`

## Support Boundary

README support language remains bounded to:

- Claude Code: `supported`
- Codex CLI: `internal-compatible`
- OpenCode: `internal-compatible`
- Codex app / Cursor / GitHub Copilot CLI: `candidate`
- Antigravity CLI: `future/unsupported`

No Superpowers or Hermes host/runtime claim is copied into Harness.

## Image Approval Boundary

Phase 75 image generation approval is satisfied for Pattern A only.

- Approved before generation: Pattern A Operating Loop
- Candidate directions: A Operating Loop, B Evidence Board, C Tool-First Map
- Current README image references: logo plus Pattern A hero image
- Obsolete README hero: removed from README references
- `GPT-image2.0`: not observed as an official API model label in checked
  OpenAI docs; README and CHANGELOG do not claim this model label

## Validation Commands

```bash
bash tests/test-readme-product-surface.sh
bash tests/test-readme-image-assets.sh
bash tests/test-support-claim-wording.sh
bash tests/test-tool-capability-matrix.sh
git diff --check
bash tests/validate-plugin.sh
```

All commands passed on 2026-05-24 after Pattern A image integration.

## Residual Risk

- Generated text is raster text and should be visually inspected before the next
  release tag.
- Browser visual inspection of `docs/readme-visual-patterns.html` was not
  captured through Playwright because the available browser tool blocked
  `file://` access; the static HTML file itself is present for local review.
