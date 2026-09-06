# Release Contract (harness release)

You drive a change from "ready to integrate" to "published", but you keep two
states strictly separate and never take an irreversible public action without
explicit confirmation.

First establish the requested artifact, target version or branch, existing
approval, and required release evidence. Reuse verified checks for the same
artifact; rerun them when changes or unresolved concerns invalidate the result.
Prepare the concrete local result within the authorized scope before asking
for a remaining public action. Do not treat a request for a release assessment
as authorization to publish.

## PR-ready vs release-ready (do not conflate)
- **PR-ready**: the work is reviewed (`APPROVE`) and could be merged. This does
  NOT bump the version or publish anything.
- **Release-ready**: a new version is actually being cut. A release is complete
  only when the work AND the version bump are merged to the default branch, the
  release tag points at a commit reachable from that branch, and the GitHub
  Release publishes that tag. "Made a tag" alone is not a release.

## Cutting a release
When (and only when) cutting a release:
1. Bump the version in all THREE surfaces together — `VERSION`,
   `.claude-plugin/plugin.json`, and `harness.toml`. They must stay in sync;
   bumping one without the others is a drift bug.
2. Promote the CHANGELOG: move the `[Unreleased]` section to `[X.Y.Z]` with the
   date, and add a fresh empty `[Unreleased]` for future entries. The changelog
   follows Keep a Changelog format.
3. Decide the bump level (patch/minor/major) from what `[Unreleased]` contains,
   and state the reason.

For a normal feature/docs PR (not a release), leave all three version files
UNCHANGED and record the change under the CHANGELOG `[Unreleased]` section.

## Confirmation gate (hard rule)
Present the full plan once — bump level + reason, changelog preview, and the
final actions — and get explicit confirmation BEFORE the gated actions below.
If those exact actions already have explicit approval, preserve that approval
instead of asking again. Local preparation does not authorize publication. Never
auto-run `git push`, `gh pr create`, a branch merge, or a tag/Release publish
without that confirmation. Do not proceed with a dirty working tree; commit or
isolate the authorized work first, preserving unrelated changes. Never
force-push or delete tags (published versions are immutable).

## Output
Emit the release plan: detected bump level and why, the CHANGELOG diff preview,
the version-triple changes, and the ordered list of actions that will run after
confirmation (commit -> push -> PR/merge -> tag -> GitHub Release).
Distinguish prepared, executed, and independently verified states. When a gate
blocks a step, name its source, the pending action, and the evidence still
needed. Give concise decision reasons without an internal reasoning transcript.
