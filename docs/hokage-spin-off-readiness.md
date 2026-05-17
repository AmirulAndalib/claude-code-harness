# Hokage Spin-Off Readiness

Last updated: 2026-05-17

## Conclusion

No public spin-off yet.

Claude Code Harness remains a Claude-first product. "Hokage" is currently the
v4 Go-native runtime line, and Hokage Core extraction is underway as an internal
architecture direction. Do not present `Hokage Harness` as a public cross-host
product until the gates below pass.

## Gate Scope

The spin-off gate covers only the adapters that are near enough to verify in
this repository:

- Claude Code
- Codex
- OpenCode

Cursor, Gemini, and Copilot are not public cross-host support claims in this phase.

## Claude/Codex/OpenCode Gate Status

| Gate | Current result | Verification evidence | Remaining blocker |
|---|---|---|---|
| Claude Code adapter | PARTIAL | `./tests/validate-plugin.sh` passes the current Claude-first plugin baseline; Hokage Core docs/tests exist separately | Public spin-off requires the Hokage Core contract checks to be part of the Claude adapter release gate, not only separate local tests |
| Codex adapter | PASS | `bash tests/test-codex-package.sh` passes; `docs/bootstrap-routing-contract.md` documents the Codex `AGENTS.md` route | None for the Phase 70 internal gate |
| OpenCode adapter | PASS | `node scripts/build-opencode.js`, `node scripts/validate-opencode.js`, and `bash scripts/sync-skill-mirrors.sh --check` pass with skills-primary setup and development-only MCP wording | None for the Phase 70 internal gate |
| Capability matrix | PASS | `docs/tool-capability-matrix.md` and `bash tests/test-tool-capability-matrix.sh` cover Claude/Codex/OpenCode differences and future-only hosts | None for the Phase 70 internal gate |
| Bootstrap routing | PASS | `docs/bootstrap-routing-contract.md` and `bash tests/test-bootstrap-routing-contract.sh` define static golden prompt routing and unsupported-host behavior | Runtime auto-routing proof is explicitly out of scope for this phase |
| Release preflight | PASS | `bash scripts/release-preflight.sh` includes adapter gates when adapter paths changed, release claims adapter support, or `--check-adapters` is used | CI run evidence still requires pushing the branch before a release tag |
| Positioning | PASS | README / README_ja use conservative extraction wording | Keep this wording until the other gates pass |

## Last Verification Snapshot

Local verification for this readiness decision:

| Command | Result |
|---|---|
| `./tests/validate-plugin.sh` | PASS |
| `bash tests/test-codex-package.sh` | PASS |
| `node scripts/build-opencode.js` | PASS |
| `node scripts/validate-opencode.js` | PASS |
| `bash scripts/sync-skill-mirrors.sh --check` | PASS |
| `bash tests/test-tool-capability-matrix.sh` | PASS |
| `bash tests/test-bootstrap-routing-contract.sh` | PASS |
| `bash scripts/release-preflight.sh` | PASS locally with non-blocking warnings for env/health/CI availability and existing residual-scan candidates |

## Unsupported Host Reasons

| Host | Status | Reason |
|---|---|---|
| Cursor | Unsupported for public spin-off | Existing 2-agent handoff docs are not a full adapter: no verified bootstrap route, capability matrix, release gate, or runtime safety parity |
| Gemini | Unsupported for public spin-off | No repository-owned extension manifest, setup path, bootstrap proof, or verification command set exists in this phase |
| Copilot | Unsupported for public spin-off | No repository-owned marketplace/CLI adapter, bootstrap proof, or release-preflight integration exists in this phase |

## Next Adapter Candidates

| Candidate | Why it is next | Required proof before support claim |
|---|---|---|
| OpenCode | It now has skills-primary setup, mirror generation, validation, and stale command/MCP cleanup | Add runtime bootstrap proof or keep support wording limited to packaging/static contract validation |
| Codex | It already has native skill surfaces, package tests, and documented bootstrap routing | Decide whether Codex adapter support is a public claim or remains an internal compatibility surface |
| Cursor | It has existing 2-agent workflow docs, but not adapter parity | Define whether it is a handoff integration or a real adapter before adding any support claim |

## Allowed Public Wording

Use:

```text
Claude Code Harness is Claude-first, with Hokage Core extraction underway.
```

Do not use:

```text
Describe Hokage as a public cross-host product before these gates pass.
```

## Exit Criteria

The `No public spin-off yet` conclusion can change only when all of the
following are true:

- Claude Code, Codex, and OpenCode adapter gates are green.
- Capability differences are documented and test-backed.
- Bootstrap routing has golden prompt coverage or explicit unsupported results.
- Release preflight blocks only adapters claimed by that release.
- README / README_ja can state support without implying safety parity that the
  host cannot provide.
