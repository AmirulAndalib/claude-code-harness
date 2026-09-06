#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTER="${ROOT_DIR}/scripts/model-routing.sh"

assert_route() {
  local host="$1" tier="$2" model="$3" effort="$4" actual
  actual="$(env -u HARNESS_BRAIN_MODEL bash "$ROUTER" --host "$host" --tier "$tier" | jq -er '.model + "/" + .effort')"
  [ "$actual" = "$model/$effort" ] || {
    echo "$host/$tier: expected $model/$effort, got $actual" >&2
    exit 1
  }
}

# Current frontier roles change models while the small-worker and effort
# contracts remain explicit. These are the defaults when no brain is selected.
for tier in deep advisor review; do
  assert_route claude "$tier" claude-fable-5-1 high
done
assert_route claude standard claude-sonnet-5 medium
assert_route claude lite claude-haiku-4-5 low

for tier in standard deep review advisor; do
  assert_route codex "$tier" gpt-6-astra xhigh
done
for tier in release long-context; do
  assert_route codex "$tier" gpt-6-astra high
done
assert_route codex worker gpt-5.6-luna max
assert_route codex lite gpt-5.6-luna low

# An explicit historical brain retains its effort and affects brain roles only.
for brain in opus opus5 fable; do
  if [ "$brain" = fable ]; then
    expected="claude-fable-5-1/high"
  else
    expected="claude-opus-5/xhigh"
  fi
  for tier in deep advisor; do
    actual="$(HARNESS_BRAIN_MODEL="$brain" bash "$ROUTER" --host claude --tier "$tier" | jq -er '.model + "/" + .effort')"
    [ "$actual" = "$expected" ] || {
      echo "claude/$tier with $brain: expected $expected, got $actual" >&2
      exit 1
    }
  done
  actual="$(HARNESS_BRAIN_MODEL="$brain" bash "$ROUTER" --host claude --tier review | jq -er '.model + "/" + .effort')"
  [ "$actual" = "claude-fable-5-1/high" ] || {
    echo "explicit brain must not retune the Claude review route" >&2
    exit 1
  }
done

claude_args="$(env -u HARNESS_BRAIN_MODEL bash "$ROUTER" --host claude --role advisor --format args)"
[ "$claude_args" = $'--model\nclaude-fable-5-1\n--effort\nhigh' ] || {
  echo "Claude advisor argv must carry Fable 5.1 and high effort" >&2
  exit 1
}
codex_args="$(env -u HARNESS_BRAIN_MODEL bash "$ROUTER" --host codex --role reviewer --format args)"
[ "$codex_args" = $'--model\ngpt-6-astra\n-c\nmodel_reasoning_effort="xhigh"' ] || {
  echo "Codex reviewer argv must carry astra and the existing xhigh effort" >&2
  exit 1
}

advisor_model="$(awk '/^model:/ { print $2; exit }' "${ROOT_DIR}/agents/advisor.md")"
advisor_effort="$(awk '/^effort:/ { print $2; exit }' "${ROOT_DIR}/agents/advisor.md")"
[ "$advisor_model/$advisor_effort" = "claude-fable-5-1/high" ] || {
  echo "native Claude advisor must select claude-fable-5-1/high" >&2
  exit 1
}
reviewer_model="$(awk '/^model:/ { print $2; exit }' "${ROOT_DIR}/agents/reviewer.md")"
[ "$reviewer_model" = claude-sonnet-5 ] || {
  echo "the isolated native Claude security reviewer must retain Sonnet 5" >&2
  exit 1
}

echo "PASS: frontier catalog, explicit brain, argv, and native Claude roles"
