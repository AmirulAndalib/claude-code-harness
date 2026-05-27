#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="${ROOT_DIR}/benchmarks/breezing-bench/agent-eval"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}" >&2
    exit 1
  fi
}

require_cmd npm
require_cmd node

cd "${BENCH_DIR}"

# GitHub Dependabot alerts are advisory-level; npm audit reports package-level
# meta-vulnerabilities, so the counts can differ. This gate only requires that
# the tracked benchmark lockfile has no moderate-or-higher npm audit findings.
npm audit --audit-level=moderate >/tmp/breezing-agent-eval-audit.json
npm install --ignore-scripts --prefer-offline >/tmp/breezing-agent-eval-install.log

node <<'NODE'
const fs = require("fs");

const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

function versionOf(path) {
  return lock.packages?.[path]?.version || "";
}

function assertMinVersion(name, actual, minimum) {
  if (!actual) {
    fail(`${name} is missing from package-lock.json`);
    return;
  }
  const got = actual.split(".").map(Number);
  const min = minimum.split(".").map(Number);
  for (let i = 0; i < Math.max(got.length, min.length); i += 1) {
    const g = got[i] || 0;
    const m = min[i] || 0;
    if (g > m) return;
    if (g < m) {
      fail(`${name} expected >= ${minimum}, got ${actual}`);
      return;
    }
  }
}

if (pkg.dependencies?.["@vercel/agent-eval"] !== "^0.14.1") {
  fail("@vercel/agent-eval must stay on the current 0.14.x line");
}

if (pkg.overrides?.undici !== "^7.24.0") {
  fail("package.json must pin undici override to a patched range");
}

if (pkg.overrides?.minimatch !== "^10.2.4") {
  fail("package.json must pin minimatch override to a patched range");
}

if (pkg.overrides?.dockerode?.uuid !== "^11.1.1") {
  fail("package.json must pin dockerode -> uuid override to a patched range");
}

for (const [name, command] of Object.entries(pkg.scripts || {})) {
  if (name.startsWith("eval:") && /\bnpx\b/.test(command)) {
    fail(`script ${name} must use the lockfile-installed agent-eval binary, not npx`);
  }
}

assertMinVersion("@vercel/agent-eval", versionOf("node_modules/@vercel/agent-eval"), "0.14.1");
assertMinVersion("undici", versionOf("node_modules/undici"), "7.24.0");
assertMinVersion("minimatch", versionOf("node_modules/minimatch"), "10.2.4");
assertMinVersion("uuid", versionOf("node_modules/uuid"), "11.1.1");

const evalDirs = new Set(
  fs.readdirSync("evals", { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name),
);
const missing = [];
for (const file of fs.readdirSync("experiments").filter((name) => name.endsWith(".ts"))) {
  const source = fs.readFileSync(`experiments/${file}`, "utf8");
  for (const match of source.matchAll(/task-\d+/g)) {
    if (!evalDirs.has(match[0])) {
      missing.push(`${file}: ${match[0]}`);
    }
  }
}
if (missing.length > 0) {
  fail(`experiment references missing eval fixture(s): ${missing.join(", ")}`);
}

if (process.exitCode) {
  process.exit(process.exitCode);
}
NODE

npm run eval:smoke:dry >/tmp/breezing-agent-eval-smoke.log

echo "breezing agent-eval dependency audit: ok"
