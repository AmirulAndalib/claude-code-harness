#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPANION="${ROOT_DIR}/scripts/codex-companion.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_HOME="${TMP_DIR}/home"
PLUGIN_ROOT="${FAKE_HOME}/.codex/plugins/openai-codex/codex/1.0.6"
mkdir -p "${PLUGIN_ROOT}/scripts" "${TMP_DIR}/bin"

# The fake official companion captures its argv and the per-run endpoint. It
# exits without contacting a provider; the fake codex below only emulates the
# app-server process lifecycle.
cat > "${PLUGIN_ROOT}/scripts/codex-companion.mjs" <<'NODE'
import fs from "node:fs";
import net from "node:net";
if (process.env.COMPANION_STUB_ARGS_FILE) {
  fs.writeFileSync(process.env.COMPANION_STUB_ARGS_FILE, process.argv.slice(2).join("\n") + "\n");
}
if (process.env.COMPANION_STUB_ENV_FILE) {
  fs.writeFileSync(process.env.COMPANION_STUB_ENV_FILE, `${process.env.CODEX_COMPANION_APP_SERVER_ENDPOINT ?? ""}\n`);
}
if (process.env.COMPANION_STUB_PID_FILE) {
  fs.writeFileSync(process.env.COMPANION_STUB_PID_FILE, `${process.pid}\n`);
}
if (process.env.COMPANION_STUB_IGNORE_TERM === "1") {
  process.on("SIGTERM", () => {});
}
const endpoint = process.env.CODEX_COMPANION_APP_SERVER_ENDPOINT ?? "";
if (endpoint.startsWith("unix:")) {
  // This is a bounded protocol-exchange timeout, not a readiness sleep. A
  // loaded CI host can take longer than one second to exec the fake Node
  // app-server after the proxy publishes its socket; the contract remains
  // finite and failures still surface rather than hanging the test.
  const exchangeTimeoutMs = Number(process.env.COMPANION_STUB_EXCHANGE_TIMEOUT_MS ?? "5000");
  await new Promise((resolve, reject) => {
    const socket = net.createConnection(endpoint.slice("unix:".length));
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error); else resolve();
    };
    const timer = setTimeout(() => {
      socket.destroy();
      finish(new Error("companion app-server exchange timed out"));
    }, exchangeTimeoutMs);
    let received = "";
    socket.on("connect", () => socket.write("companion-ping\n"));
    socket.on("data", (chunk) => {
      received += chunk.toString();
      if (received.includes("companion-ping\n")) {
        socket.end();
        finish();
      }
    });
    socket.on("error", finish);
  });
}
await new Promise((resolve) => setTimeout(resolve, Number(process.env.COMPANION_STUB_WAIT_MS ?? "200")));
process.stdout.write('{"review":"fake","target":"preserved"}\n');
NODE

cat > "${TMP_DIR}/bin/codex" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" != "app-server" ]; then
  printf '%s\n' "$@" > "${CODEX_STUB_ARGS_FILE}"
  exit 97
fi
printf '%s\n' "$@" > "${APP_SERVER_ARGS_FILE}"
if [ "${FAKE_APP_SERVER_MODE:-ok}" = "fail" ]; then
  exit 23
fi
printf '%s\n' "$$" > "${APP_SERVER_SOCKET_FILE}"
if [ "${FAKE_APP_SERVER_MODE:-ok}" = "stubborn" ]; then
  exec node -e 'process.stdin.on("data", (chunk) => process.stdout.write(chunk)); process.stdin.resume(); process.on("SIGTERM", () => {}); setInterval(() => {}, 50);'
elif [ "${FAKE_APP_SERVER_MODE:-ok}" = "crash" ]; then
  exec node -e 'setTimeout(() => process.exit(9), 75); process.stdin.resume();'
elif [ "${FAKE_APP_SERVER_MODE:-ok}" = "clean" ]; then
  exec node -e 'process.stdin.on("data", (chunk) => process.stdout.write(chunk)); process.stdin.on("end", () => process.exit(0)); process.stdin.resume();'
else
  exec node -e 'process.stdin.on("data", (chunk) => process.stdout.write(chunk)); process.stdin.resume(); process.on("SIGTERM", () => process.exit(0));'
fi
EOF
chmod +x "${TMP_DIR}/bin/codex"

expect_arg() {
  local args_file="$1"
  local expected="$2"
  grep -qx -- "${expected}" "${args_file}" || {
    echo "review companion argv must contain: ${expected}"
    exit 1
  }
}

expect_pair() {
  local args_file="$1"
  local first="$2"
  local second="$3"
  awk -v first="${first}" -v second="${second}" '
    previous == first && $0 == second { found = 1 }
    { previous = $0 }
    END { exit(found ? 0 : 1) }
  ' "${args_file}" || {
    echo "review companion argv must preserve pair: ${first} ${second}"
    exit 1
  }
}

assert_process_gone() {
  local pid="${1:-}"
  local state=""
  [ -n "${pid}" ] || return 0
  for _ in $(seq 1 80); do
    state="$(ps -p "${pid}" -o stat= 2>/dev/null | tr -d '[:space:]' || true)"
    case "${state}" in
      ""|Z*) return 0 ;;
    esac
    sleep 0.05
  done
  echo "process ${pid} must be gone (state=${state})"
  exit 1
}

monotonic_ms() {
  node -e 'process.stdout.write(String(Math.floor(performance.now())))'
}

run_review() {
  local companion_args_file="$1"
  local companion_env_file="$2"
  local app_server_args_file="$3"
  local app_server_socket_file="$4"
  local output_file="$5"
  shift 5
  CODEX_STUB_ARGS_FILE="${TMP_DIR}/unexpected-codex-args.txt" \
  COMPANION_STUB_ARGS_FILE="${companion_args_file}" \
  COMPANION_STUB_ENV_FILE="${companion_env_file}" \
  APP_SERVER_ARGS_FILE="${app_server_args_file}" \
  APP_SERVER_SOCKET_FILE="${app_server_socket_file}" \
  HARNESS_ORCHESTRATION_LEDGER="${TMP_DIR}/routed-ledger.jsonl" \
  HOME="${FAKE_HOME}" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="worker" \
    bash "${COMPANION}" "$@" >"${output_file}"
}

default_args="${TMP_DIR}/default-companion-args.txt"
default_env="${TMP_DIR}/default-companion-env.txt"
default_app_args="${TMP_DIR}/default-app-server-args.txt"
default_socket_file="${TMP_DIR}/default-socket.txt"
default_output="${TMP_DIR}/default-output.txt"
run_review "${default_args}" "${default_env}" "${default_app_args}" "${default_socket_file}" "${default_output}" \
  review --base main --json

expect_pair "${default_app_args}" -c 'model="gpt-6-astra"'
expect_pair "${default_app_args}" -c 'review_model="gpt-6-astra"'
expect_pair "${default_app_args}" -c 'model_reasoning_effort="xhigh"'
expect_arg "${default_app_args}" app-server
expect_arg "${default_app_args}" --stdio
expect_pair "${default_args}" --model gpt-6-astra
expect_arg "${default_args}" --base
expect_arg "${default_args}" main
grep -Eq '^unix:.+/review\.sock$' "${default_env}" || {
  echo "review companion must receive the per-run unix endpoint"
  exit 1
}
grep -Fq -- '"target":"preserved"' "${default_output}" || {
  echo "review output must preserve the companion envelope"
  exit 1
}
assert_process_gone "$(cat "${default_socket_file}")"

stubborn_args="${TMP_DIR}/stubborn-companion-args.txt"
stubborn_env="${TMP_DIR}/stubborn-companion-env.txt"
stubborn_app_args="${TMP_DIR}/stubborn-app-server-args.txt"
stubborn_pid_file="${TMP_DIR}/stubborn-pid.txt"
stubborn_output="${TMP_DIR}/stubborn-output.txt"
FAKE_APP_SERVER_MODE=stubborn run_review "${stubborn_args}" "${stubborn_env}" "${stubborn_app_args}" "${stubborn_pid_file}" "${stubborn_output}" \
  review --base main --json
assert_process_gone "$(cat "${stubborn_pid_file}")"

adversarial_args="${TMP_DIR}/adversarial-companion-args.txt"
adversarial_env="${TMP_DIR}/adversarial-companion-env.txt"
adversarial_app_args="${TMP_DIR}/adversarial-app-server-args.txt"
adversarial_socket_file="${TMP_DIR}/adversarial-socket.txt"
adversarial_output="${TMP_DIR}/adversarial-output.txt"
run_review "${adversarial_args}" "${adversarial_env}" "${adversarial_app_args}" "${adversarial_socket_file}" "${adversarial_output}" \
  adversarial-review --uncommitted --json 'focus on boundary checks'
expect_pair "${adversarial_args}" --scope working-tree
expect_arg "${adversarial_args}" 'focus on boundary checks'
expect_pair "${adversarial_args}" --model gpt-6-astra

commit_args="${TMP_DIR}/commit-companion-args.txt"
commit_env="${TMP_DIR}/commit-companion-env.txt"
commit_app_args="${TMP_DIR}/commit-app-server-args.txt"
commit_socket_file="${TMP_DIR}/commit-socket.txt"
commit_output="${TMP_DIR}/commit-output.txt"
commit_status=0
if run_review "${commit_args}" "${commit_env}" "${commit_app_args}" "${commit_socket_file}" "${commit_output}" \
  review --commit deadbeef --json >"${commit_output}" 2>&1; then
  commit_status=0
else
  commit_status=$?
fi
[ "${commit_status}" -eq 2 ] || {
  echo "review --commit must fail closed with rc=2"
  exit 1
}
grep -Fq -- "review --commit target is unsupported" "${commit_output}" || {
  echo "review --commit rejection must explain unsupported target semantics"
  exit 1
}
[ ! -e "${commit_args}" ] || {
  echo "unsupported review --commit must not invoke companion"
  exit 1
}

explicit_model_args="${TMP_DIR}/explicit-model-companion-args.txt"
explicit_model_env="${TMP_DIR}/explicit-model-companion-env.txt"
explicit_model_app_args="${TMP_DIR}/explicit-model-app-server-args.txt"
explicit_model_socket_file="${TMP_DIR}/explicit-model-socket.txt"
explicit_model_output="${TMP_DIR}/explicit-model-output.txt"
run_review "${explicit_model_args}" "${explicit_model_env}" "${explicit_model_app_args}" "${explicit_model_socket_file}" "${explicit_model_output}" \
  review --model custom-review-model --base main --json
expect_pair "${explicit_model_args}" --model custom-review-model
expect_pair "${explicit_model_app_args}" -c 'model="custom-review-model"'
expect_pair "${explicit_model_app_args}" -c 'review_model="custom-review-model"'
expect_pair "${explicit_model_app_args}" -c 'model_reasoning_effort="xhigh"'
if grep -qx -- 'gpt-6-astra' "${explicit_model_args}"; then
  echo "explicit review model must not be overridden in companion argv"
  exit 1
fi

invalid_model_args="${TMP_DIR}/invalid-model-companion-args.txt"
invalid_model_env="${TMP_DIR}/invalid-model-companion-env.txt"
invalid_model_app_args="${TMP_DIR}/invalid-model-app-server-args.txt"
invalid_model_socket_file="${TMP_DIR}/invalid-model-socket.txt"
invalid_model_output="${TMP_DIR}/invalid-model-output.txt"
invalid_model_status=0
if run_review "${invalid_model_args}" "${invalid_model_env}" "${invalid_model_app_args}" "${invalid_model_socket_file}" "${invalid_model_output}" \
  review --model 'custom"review-model' --base main --json >"${invalid_model_output}" 2>&1; then
  invalid_model_status=0
else
  invalid_model_status=$?
fi
[ "${invalid_model_status}" -eq 2 ] || {
  echo "unsafe explicit review model must fail closed with rc=2"
  exit 1
}
grep -Fq -- "invalid review model" "${invalid_model_output}" || {
  echo "unsafe explicit review model must explain the rejection"
  exit 1
}
[ ! -e "${invalid_model_app_args}" ] || {
  echo "unsafe explicit review model must not start app-server"
  exit 1
}

explicit_effort_args="${TMP_DIR}/explicit-effort-companion-args.txt"
explicit_effort_env="${TMP_DIR}/explicit-effort-companion-env.txt"
explicit_effort_app_args="${TMP_DIR}/explicit-effort-app-server-args.txt"
explicit_effort_socket_file="${TMP_DIR}/explicit-effort-socket.txt"
explicit_effort_output="${TMP_DIR}/explicit-effort-output.txt"
run_review "${explicit_effort_args}" "${explicit_effort_env}" "${explicit_effort_app_args}" "${explicit_effort_socket_file}" "${explicit_effort_output}" \
  review --effort high --base main --json
expect_pair "${explicit_effort_app_args}" -c 'model_reasoning_effort="high"'
if grep -qx -- '--effort' "${explicit_effort_args}"; then
  echo "review effort must be normalized into the app-server config"
  exit 1
fi
# A failed app-server must stop before the companion child is started.
failed_args="${TMP_DIR}/failed-companion-args.txt"
failed_env="${TMP_DIR}/failed-companion-env.txt"
failed_app_args="${TMP_DIR}/failed-app-server-args.txt"
failed_socket_file="${TMP_DIR}/failed-socket.txt"
failed_output="${TMP_DIR}/failed-output.txt"
failed_status=0
if CODEX_STUB_ARGS_FILE="${TMP_DIR}/unexpected-failed-codex-args.txt" \
  COMPANION_STUB_ARGS_FILE="${failed_args}" \
  COMPANION_STUB_ENV_FILE="${failed_env}" \
  APP_SERVER_ARGS_FILE="${failed_app_args}" \
  APP_SERVER_SOCKET_FILE="${failed_socket_file}" \
  HARNESS_ORCHESTRATION_LEDGER="${TMP_DIR}/routed-ledger.jsonl" \
  FAKE_APP_SERVER_MODE=fail \
  HOME="${FAKE_HOME}" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="worker" \
    bash "${COMPANION}" review --base main >"${failed_output}" 2>&1; then
  failed_status=0
else
  failed_status=$?
fi
[ "${failed_status}" -ne 0 ] || {
  echo "review app-server start failure must return nonzero"
  exit 1
}
# A child can race the readiness marker; the wrapper's nonzero status is the
# contract even if the companion briefly starts before the failure is observed.

# A transport that dies after readiness must still make the wrapper fail; a
# successful companion envelope cannot mask an app-server failure.
crash_args="${TMP_DIR}/crash-companion-args.txt"
crash_env="${TMP_DIR}/crash-companion-env.txt"
crash_app_args="${TMP_DIR}/crash-app-server-args.txt"
crash_socket_file="${TMP_DIR}/crash-socket.txt"
crash_output="${TMP_DIR}/crash-output.txt"
crash_status=0
if FAKE_APP_SERVER_MODE=crash run_review "${crash_args}" "${crash_env}" "${crash_app_args}" "${crash_socket_file}" "${crash_output}" \
  review --base main --json >"${crash_output}" 2>&1; then
  crash_status=0
else
  crash_status=$?
fi
[ "${crash_status}" -ne 0 ] || {
  echo "app-server crash after readiness must return nonzero"
  exit 1
}

ledger_count="$(wc -l <"${TMP_DIR}/routed-ledger.jsonl" | tr -d ' ')"
[ "${ledger_count}" -eq 5 ] || {
  echo "only valid routed review/adversarial calls must emit exactly one ledger line each"
  exit 1
}

# TERM at the wrapper must clean up the helper and its descendant rather than
# relying on the caller to reap the app-server process.
term_args="${TMP_DIR}/term-companion-args.txt"
term_env="${TMP_DIR}/term-companion-env.txt"
term_app_args="${TMP_DIR}/term-app-server-args.txt"
term_socket_file="${TMP_DIR}/term-socket.txt"
term_output="${TMP_DIR}/term-output.txt"
term_companion_pid_file="${TMP_DIR}/term-companion.pid"
COMPANION_STUB_WAIT_MS=10000 \
COMPANION_STUB_IGNORE_TERM=1 \
COMPANION_STUB_PID_FILE="${term_companion_pid_file}" \
CODEX_STUB_ARGS_FILE="${TMP_DIR}/term-unexpected-codex.txt" \
COMPANION_STUB_ARGS_FILE="${term_args}" \
COMPANION_STUB_ENV_FILE="${term_env}" \
APP_SERVER_ARGS_FILE="${term_app_args}" \
APP_SERVER_SOCKET_FILE="${term_socket_file}" \
HARNESS_ORCHESTRATION_LEDGER="${TMP_DIR}/term-ledger.jsonl" \
HOME="${FAKE_HOME}" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="worker" \
  bash "${COMPANION}" review --base main --json >"${term_output}" 2>&1 &
term_wrapper_pid=$!
for _ in $(seq 1 200); do
  [ -e "${term_socket_file}" ] && [ -e "${term_companion_pid_file}" ] && break
  sleep 0.05
done
[ -e "${term_socket_file}" ] && [ -e "${term_companion_pid_file}" ] || {
  echo "review TERM fixture did not start its app-server child"
  kill -TERM "${term_wrapper_pid}" 2>/dev/null || true
  wait "${term_wrapper_pid}" 2>/dev/null || true
  exit 1
}
term_start_ms="$(monotonic_ms)"
kill -TERM "${term_wrapper_pid}" 2>/dev/null || true
wait "${term_wrapper_pid}" 2>/dev/null || true
term_elapsed_ms=$(( $(monotonic_ms) - term_start_ms ))
[ "${term_elapsed_ms}" -le 5000 ] || {
  echo "review TERM must not wait for an ignoring companion (elapsed ${term_elapsed_ms}ms)"
  exit 1
}
assert_process_gone "$(cat "${term_companion_pid_file}")"
assert_process_gone "$(cat "${term_socket_file}")"

# TERM during endpoint readiness must use the same scoped cleanup path as a
# running review. The artificial proxy delay keeps the wrapper in startup
# polling long enough to exercise that window without invoking a provider.
startup_args="${TMP_DIR}/startup-companion-args.txt"
startup_app_args="${TMP_DIR}/startup-app-server-args.txt"
startup_socket_file="${TMP_DIR}/startup-socket.txt"
startup_output="${TMP_DIR}/startup-output.txt"
CODEX_REVIEW_PROXY_READY_DELAY_MS=2000 \
CODEX_STUB_ARGS_FILE="${TMP_DIR}/startup-unexpected-codex.txt" \
COMPANION_STUB_ARGS_FILE="${startup_args}" \
APP_SERVER_ARGS_FILE="${startup_app_args}" \
APP_SERVER_SOCKET_FILE="${startup_socket_file}" \
HARNESS_ORCHESTRATION_LEDGER="${TMP_DIR}/startup-ledger.jsonl" \
HOME="${FAKE_HOME}" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="worker" \
  bash "${COMPANION}" review --base main --json >"${startup_output}" 2>&1 &
startup_wrapper_pid=$!
for _ in $(seq 1 200); do
  [ -e "${startup_socket_file}" ] && break
  sleep 0.05
done
[ -e "${startup_socket_file}" ] || {
  echo "startup TERM fixture did not start its app-server child"
  kill -TERM "${startup_wrapper_pid}" 2>/dev/null || true
  wait "${startup_wrapper_pid}" 2>/dev/null || true
  exit 1
}
kill -TERM "${startup_wrapper_pid}" 2>/dev/null || true
wait "${startup_wrapper_pid}" 2>/dev/null || true
assert_process_gone "$(cat "${startup_socket_file}")"
[ ! -e "${startup_args}" ] || {
  echo "startup TERM must not launch the official companion"
  exit 1
}

# Routing-disabled mode keeps the historical official companion behavior.
disabled_args="${TMP_DIR}/disabled-companion-args.txt"
COMPANION_STUB_ARGS_FILE="${disabled_args}" \
HOME="${FAKE_HOME}" \
PATH="${TMP_DIR}/bin:${PATH}" \
HARNESS_DISABLE_MODEL_ROUTING=1 \
HARNESS_ORCHESTRATION_LEDGER="${TMP_DIR}/disabled-ledger.jsonl" \
  bash "${COMPANION}" review --base main --json >/dev/null
expect_arg "${disabled_args}" review
disabled_ledger_count="$(wc -l <"${TMP_DIR}/disabled-ledger.jsonl" | tr -d ' ')"
[ "${disabled_ledger_count}" -eq 1 ] || {
  echo "routing-disabled review must emit exactly one ledger line"
  exit 1
}

# Exercise the byte proxy independently of the shell wrapper. This proves the
# endpoint carries app-server bytes and that TERM removes both proxy and child.
direct_proxy_dir="${TMP_DIR}/direct-proxy"
mkdir -p "${direct_proxy_dir}"
direct_socket="${direct_proxy_dir}/review.sock"
direct_ready="${direct_proxy_dir}/ready"
direct_args="${direct_proxy_dir}/app-server-args.txt"
direct_child_pid="${direct_proxy_dir}/child.pid"
direct_status="${direct_proxy_dir}/status"
APP_SERVER_ARGS_FILE="${direct_args}" \
APP_SERVER_SOCKET_FILE="${direct_child_pid}" \
FAKE_APP_SERVER_MODE=clean \
  node "${ROOT_DIR}/scripts/codex-review-app-server-proxy.mjs" \
    --endpoint "unix:${direct_socket}" --ready-file "${direct_ready}" \
    --codex "${TMP_DIR}/bin/codex" --status-file "${direct_status}" \
    --config 'model="gpt-6-astra"' &
direct_proxy_pid=$!
for _ in $(seq 1 200); do
  [ -e "${direct_ready}" ] && break
  sleep 0.05
done
[ -e "${direct_ready}" ] || {
  echo "byte proxy must publish a ready endpoint"
  kill -TERM "${direct_proxy_pid}" 2>/dev/null || true
  wait "${direct_proxy_pid}" 2>/dev/null || true
  exit 1
}
node - "${direct_socket}" <<'NODE'
const net = require("node:net");
const socketPath = process.argv[2];
const socket = net.createConnection(socketPath);
let received = "";
const timer = setTimeout(() => {
  socket.destroy();
  process.exit(1);
}, 2000);
socket.on("connect", () => socket.write("proxy-ping\n"));
socket.on("data", (chunk) => {
  received += chunk.toString();
  if (received.includes("proxy-ping\n")) {
    clearTimeout(timer);
    socket.end();
    process.exit(0);
  }
});
NODE
kill -TERM "${direct_proxy_pid}" 2>/dev/null || true
wait "${direct_proxy_pid}" 2>/dev/null || true
assert_process_gone "$(cat "${direct_child_pid}")"
[ ! -e "${direct_socket}" ] || {
  echo "byte proxy TERM must remove its unix endpoint"
  exit 1
}
[ -f "${direct_status}" ] && grep -Fqx '0' "${direct_status}" || {
  echo "clean proxy shutdown must leave a zero status marker"
  exit 1
}

echo "OK"
