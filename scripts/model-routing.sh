#!/usr/bin/env bash
# Resolve Harness model/effort routing from a small role-tier contract.

set -euo pipefail

HOST="codex"
TIER=""
ROLE=""
FIELD=""
FORMAT="json"

usage() {
  cat <<'EOF'
Usage:
  scripts/model-routing.sh --host codex|claude --tier TIER [--format json|args|env] [--field model|effort]
  scripts/model-routing.sh --host codex|claude --role ROLE [--format json|args|env] [--field model|effort]

Tiers: lite, standard, deep, review, advisor, release, long-context, spark
Roles: explorer, worker, reviewer, advisor, plan, release, operator, long-context
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --host=*) HOST="${1#*=}"; shift ;;
    --tier) TIER="${2:-}"; shift 2 ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    --role) ROLE="${2:-}"; shift 2 ;;
    --role=*) ROLE="${1#*=}"; shift ;;
    --field) FIELD="${2:-}"; shift 2 ;;
    --field=*) FIELD="${1#*=}"; shift ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

role_to_tier() {
  case "$1" in
    explorer|reader|search|lite) printf 'lite\n' ;;
    worker|implementer|setup|standard) printf 'standard\n' ;;
    plan|planner|architect|deep) printf 'deep\n' ;;
    reviewer|review|adversarial-review) printf 'review\n' ;;
    advisor) printf 'advisor\n' ;;
    release|closeout) printf 'release\n' ;;
    operator) printf 'standard\n' ;;
    long-context|long_context) printf 'long-context\n' ;;
    spark) printf 'spark\n' ;;
    *) echo "ERROR: unknown role: $1" >&2; exit 2 ;;
  esac
}

if [ -z "$TIER" ]; then
  if [ -n "$ROLE" ]; then
    TIER="$(role_to_tier "$ROLE")"
  else
    TIER="standard"
  fi
fi

case "$HOST" in
  codex|claude) ;;
  *) echo "ERROR: unsupported host: $HOST" >&2; exit 2 ;;
esac

MODEL=""
EFFORT=""

if [ "$HOST" = "codex" ]; then
  case "$TIER" in
    lite) MODEL="gpt-5.4-mini"; EFFORT="low" ;;
    standard) MODEL="gpt-5.5"; EFFORT="medium" ;;
    deep) MODEL="gpt-5.5"; EFFORT="high" ;;
    review|advisor) MODEL="gpt-5.5"; EFFORT="xhigh" ;;
    release|long-context) MODEL="gpt-5.5"; EFFORT="high" ;;
    spark) MODEL="gpt-5.3-codex-spark"; EFFORT="low" ;;
    *) echo "ERROR: unknown codex tier: $TIER" >&2; exit 2 ;;
  esac
else
  case "$TIER" in
    lite) MODEL="claude-haiku-4-5"; EFFORT="low" ;;
    standard) MODEL="claude-sonnet-4-6"; EFFORT="medium" ;;
    deep|advisor) MODEL="claude-opus-4-7"; EFFORT="xhigh" ;;
    review) MODEL="claude-sonnet-4-6"; EFFORT="xhigh" ;;
    release) MODEL="claude-sonnet-4-6"; EFFORT="high" ;;
    long-context) MODEL="sonnet[1m]"; EFFORT="high" ;;
    spark) echo "ERROR: spark tier is codex-only" >&2; exit 2 ;;
    *) echo "ERROR: unknown claude tier: $TIER" >&2; exit 2 ;;
  esac
fi

case "$FIELD" in
  "") ;;
  model) printf '%s\n' "$MODEL"; exit 0 ;;
  effort) printf '%s\n' "$EFFORT"; exit 0 ;;
  *) echo "ERROR: unsupported field: $FIELD" >&2; exit 2 ;;
esac

case "$FORMAT" in
  json)
    printf '{"host":"%s","tier":"%s","model":"%s","effort":"%s"}\n' "$HOST" "$TIER" "$MODEL" "$EFFORT"
    ;;
  args)
    if [ "$HOST" = "codex" ]; then
      printf '%s\n' "--model" "$MODEL" "-c" "model_reasoning_effort=\"$EFFORT\""
    else
      printf '%s\n' "--model" "$MODEL" "--effort" "$EFFORT"
    fi
    ;;
  env)
    if [ "$HOST" = "codex" ]; then
      printf 'CODEX_MODEL=%s\nCODEX_EFFORT=%s\n' "$MODEL" "$EFFORT"
    else
      printf 'CLAUDE_MODEL=%s\nCLAUDE_EFFORT=%s\n' "$MODEL" "$EFFORT"
    fi
    ;;
  *) echo "ERROR: unsupported format: $FORMAT" >&2; exit 2 ;;
esac
