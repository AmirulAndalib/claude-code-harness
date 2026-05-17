#!/bin/bash
# Validate Harness skill orchestration metadata.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MANIFEST_JSON="${TMP_DIR}/skill-manifest.json"
(cd "$ROOT_DIR" && bash scripts/generate-skill-manifest.sh --output "$MANIFEST_JSON" >/dev/null)

node - "$MANIFEST_JSON" <<'NODE'
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const manifestPath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const repoRoot = manifest.repo_root;

const coreSkills = new Set([
  'harness-plan',
  'harness-work',
  'harness-review',
  'harness-loop',
  'breezing',
  'harness-sync',
  'harness-setup',
  'harness-release',
  'harness-release-internal',
]);

const requiredFields = ['kind', 'purpose', 'trigger', 'shape', 'role', 'owner', 'since'];
const knownNames = new Set(manifest.skills.map((skill) => skill.name));
const errors = [];
const requiredCoreDocs = [
  'docs/architecture/hokage-core.md',
  'docs/tool-capability-matrix.md',
];
const officialRuntimeFields = new Set(manifest.official_runtime_fields || []);
const harnessMetadataFields = new Set(manifest.harness_metadata_fields || []);
const hokageCoreDoc = 'docs/architecture/hokage-core.md';
const capabilityMatrixDoc = 'docs/tool-capability-matrix.md';
const requiredCapabilities = [
  'skill_loading',
  'bootstrap_notice',
  'prompt_routing',
  'pre_use_guard',
  'post_use_gate',
  'review_artifact',
  'memory_bridge',
];

if (officialRuntimeFields.size === 0) {
  errors.push('skill manifest missing official_runtime_fields');
}
if (harnessMetadataFields.size === 0) {
  errors.push('skill manifest missing harness_metadata_fields');
}
for (const field of officialRuntimeFields) {
  if (harnessMetadataFields.has(field)) {
    errors.push(`skill manifest mixes official runtime field with Harness metadata: ${field}`);
  }
}

const hokageCorePath = path.join(repoRoot, hokageCoreDoc);
let hokageCoreText = '';
if (!fs.existsSync(hokageCorePath)) {
  errors.push(`missing Hokage Core contract doc: ${hokageCoreDoc}`);
} else {
  hokageCoreText = fs.readFileSync(hokageCorePath, 'utf8');
  for (const capability of requiredCapabilities) {
    if (!hokageCoreText.includes(`\`${capability}\``)) {
      errors.push(`${hokageCoreDoc}: missing capability matrix entry: ${capability}`);
    }
  }
  if (!hokageCoreText.includes('Do not add adapter manifest files unless')) {
    errors.push(`${hokageCoreDoc}: missing adapter manifest boundary rejection`);
  }
  if (!hokageCoreText.includes('Do not make Claude plugin releases hard-block on non-shipping adapter checks')) {
    errors.push(`${hokageCoreDoc}: missing non-shipping adapter release gate boundary`);
  }
}

let trackedAdapterManifests = [];
try {
  const output = execFileSync('git', [
    '-C',
    repoRoot,
    'ls-files',
    '-z',
    '--',
    'adapters/*/manifest.yaml',
    'adapters/*/manifest.yml',
  ], { encoding: 'buffer' }).toString('utf8');
  trackedAdapterManifests = output.split('\0').filter(Boolean);
} catch (error) {
  errors.push(`unable to inspect adapter manifests: ${error.message}`);
}
for (const file of trackedAdapterManifests) {
  errors.push(`${file}: adapter manifests are blocked until setup/docs/preflight consume them in the same phase`);
}

for (const skill of manifest.skills) {
  const officialRuntime = skill.official_runtime || {};
  const harnessMetadata = skill.harness_metadata || {};
  for (const field of harnessMetadataFields) {
    if (Object.prototype.hasOwnProperty.call(officialRuntime, field)) {
      errors.push(`${skill.path}: official_runtime contains Harness metadata field: ${field}`);
    }
  }
  for (const field of officialRuntimeFields) {
    if (Object.prototype.hasOwnProperty.call(harnessMetadata, field)) {
      errors.push(`${skill.path}: harness_metadata contains official runtime field: ${field}`);
    }
  }

  if (!coreSkills.has(skill.name)) continue;
  if (skill.surface === 'opencode/skills') continue;

  for (const field of requiredFields) {
    if (skill[field] === null || skill[field] === '') {
      errors.push(`${skill.path}: missing design metadata field: ${field}`);
    }
    if (harnessMetadata[field] !== skill[field]) {
      errors.push(`${skill.path}: flat design metadata differs from harness_metadata.${field}`);
    }
  }

  if (skill.core_contract_document !== hokageCoreDoc) {
    errors.push(`${skill.path}: missing core contract document pointer`);
  }
  if (skill.capability_matrix_document !== capabilityMatrixDoc) {
    errors.push(`${skill.path}: missing capability matrix document pointer`);
  }

  if ((skill.base !== null && !knownNames.has(skill.base)) || (skill.pair !== null && !knownNames.has(skill.pair))) {
    if (skill.base !== null && !knownNames.has(skill.base)) {
      errors.push(`${skill.path}: base references unknown skill: ${skill.base}`);
    }
    if (skill.pair !== null && !knownNames.has(skill.pair)) {
      errors.push(`${skill.path}: pair references unknown skill: ${skill.pair}`);
    }
  }

  if (skill.shape === 'wrap' && (skill.base === null || skill.base === '')) {
    errors.push(`${skill.path}: shape=wrap requires base`);
  }

  if (skill.role === 'evaluator') {
    const mutating = (skill.allowed_tools || []).filter((tool) =>
      ['Write', 'Edit', 'Append', 'NotebookEdit', 'spawn_agent', 'send_input'].includes(tool)
    );
    if (mutating.length > 0) {
      errors.push(`${skill.path}: evaluator role allows mutating tools: ${mutating.join(', ')}`);
    }
    if (skill.context !== 'fork') {
      errors.push(`${skill.path}: evaluator role must use context: fork`);
    }
  }
}

for (const docPath of requiredCoreDocs) {
  if (!fs.existsSync(path.join(repoRoot, docPath))) {
    errors.push(`missing core workflow contract doc: ${docPath}`);
  }
}

if (fs.existsSync(path.join(repoRoot, 'adapters'))) {
  const adapterManifestPaths = [];
  const stack = [path.join(repoRoot, 'adapters')];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (entry.name === 'manifest.yaml' || entry.name === 'manifest.yml') {
        adapterManifestPaths.push(path.relative(repoRoot, fullPath).split(path.sep).join('/'));
      }
    }
  }
  if (adapterManifestPaths.length > 0) {
    errors.push(`adapter manifest files require same-phase setup/docs/preflight consumers: ${adapterManifestPaths.join(', ')}`);
  }
}

const hokageCoreDocText = fs.existsSync(hokageCorePath)
  ? fs.readFileSync(hokageCorePath, 'utf8')
  : '';
if (!hokageCoreDocText.includes('Do not add adapter manifest files unless setup, docs generation, or release')) {
  errors.push('docs/architecture/hokage-core.md must keep the adapter manifest consumer boundary');
}
if (!hokageCoreDocText.includes('Core must not depend directly on')) {
  errors.push('docs/architecture/hokage-core.md must distinguish official runtime fields from Harness metadata');
}

if (errors.length > 0) {
  console.error('Skill design contract violations:');
  for (const error of errors) {
    console.error(`  - ${error}`);
  }
  process.exit(1);
}
NODE

echo "test-skill-design-contract: ok"
