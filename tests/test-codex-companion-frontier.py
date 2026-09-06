#!/usr/bin/env python3
"""Exercise model/effort dispatch at stubbed Codex provider boundaries."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CompanionFrontierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="companion-frontier-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        plugin = self.root / "home/.codex/plugins/openai-codex/codex/1.0.6/scripts"
        plugin.mkdir(parents=True)
        (plugin / "codex-companion.mjs").write_text("""
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
const args = process.argv.slice(2);
fs.writeFileSync(process.env.TEST_COMPANION_ARGS, JSON.stringify(args));
// Companion 1.0.6 treats unknown options as prompt positionals. In particular,
// --sandbox does not set its sandbox: executeTaskRun derives that from write.
// Keep these parser semantics in the fixture so argv capture cannot hide a
// read-only request being interpreted as workspace-write by the provider.
const isTask = args[0] === 'task';
const valueOptions = new Set(isTask ? ['model', 'effort', 'cwd', 'prompt-file'] : ['base', 'scope', 'model', 'cwd']);
const booleanOptions = new Set(isTask ? ['json', 'write', 'resume-last', 'resume', 'fresh', 'background'] : ['json', 'background', 'wait']);
const aliases = {m: 'model', C: 'cwd'};
const options = {};
const positionals = [];
let passthrough = false;
for (let index = 1; index < args.length; index++) {
  const token = args[index];
  if (passthrough) { positionals.push(token); continue; }
  if (token === '--') { passthrough = true; continue; }
  if (!token.startsWith('-') || token === '-') { positionals.push(token); continue; }
  const long = token.startsWith('--');
  const [rawKey, inlineValue] = long ? token.slice(2).split('=', 2) : [token.slice(1), undefined];
  const key = aliases[rawKey] ?? rawKey;
  if (booleanOptions.has(key)) {
    options[key] = inlineValue === undefined ? true : inlineValue !== 'false';
  } else if (valueOptions.has(key)) {
    options[key] = inlineValue ?? args[index + 1];
    if (inlineValue === undefined) index++;
  } else {
    positionals.push(token);
  }
}
fs.writeFileSync(process.env.TEST_EFFECTIVE_CWD, JSON.stringify({
  cwd: fs.realpathSync(path.resolve(options.cwd ?? process.cwd())), positionals
}));
if (args[0] === 'task') {
  if (options.effort && !['none', 'minimal', 'low', 'medium', 'high', 'xhigh'].includes(options.effort)) process.exit(91);
  fs.writeFileSync(process.env.TEST_EFFECTIVE_TASK, JSON.stringify({
    sandbox: options.write ? 'workspace-write' : 'read-only', positionals
  }));
}
const endpoint = process.env.CODEX_COMPANION_APP_SERVER_ENDPOINT;
if (endpoint) {
  await new Promise((resolve, reject) => {
    const socket = net.createConnection(endpoint.slice('unix:'.length));
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('exchange timed out')); }, 3000);
    socket.on('connect', () => socket.write('ping\\n'));
    socket.on('data', () => { clearTimeout(timer); socket.end(); resolve(); });
    socket.on('error', reject);
  });
} else {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  if (args[0] === 'task' && options['prompt-file']) input = fs.readFileSync(path.resolve(options.cwd ?? process.cwd(), options['prompt-file']), 'utf8');
  fs.writeFileSync(process.env.TEST_STDIN, input);
}
process.stdout.write('{"review":"fixture","target":"preserved"}\\n');
""")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        codex = self.bin / "codex"
        codex.write_text("""#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.writeFileSync(process.env.TEST_CODEX_ARGS, JSON.stringify(args));
if (args[0] === 'app-server') {
  process.stdin.on('data', chunk => process.stdout.write(chunk));
  process.stdin.resume();
  process.on('SIGTERM', () => process.exit(0));
} else {
  let sandbox = 'read-only';
  let bypass = false;
  let cwd = process.cwd();
  const valueOptions = new Set(['--model', '-m', '--cd', '-C', '-c', '--config', '--output-schema', '--output-last-message', '-o', '--image', '-i', '--add-dir', '--color']);
  for (let index = 1; index < args.length && args[index] !== '--'; index++) {
    const arg = args[index];
    if (arg === '--cd' || arg === '-C') cwd = args[++index];
    else if (arg.startsWith('--cd=')) cwd = arg.slice('--cd='.length);
    else if (arg.startsWith('-C=')) cwd = arg.slice(3);
    else if (arg.startsWith('-C') && arg.length > 2) cwd = arg.slice(2);
    else if (arg === '--sandbox' || arg === '-s') sandbox = args[++index];
    else if (arg.startsWith('--sandbox=') || arg.startsWith('-s=')) sandbox = arg.split('=', 2)[1];
    else if (arg === '--full-auto') sandbox = 'workspace-write';
    else if (arg.startsWith('-s') && arg.length > 2) sandbox = arg.slice(2);
    else if (arg === '--dangerously-bypass-approvals-and-sandbox' || arg === '--yolo') bypass = true;
    else if (valueOptions.has(arg)) index++;
  }
  // Codex 0.153.4 gives the bypass bool precedence over every sandbox value.
  if (bypass) sandbox = 'danger-full-access';
  fs.writeFileSync(process.env.TEST_EFFECTIVE_TASK, JSON.stringify({sandbox}));
  fs.writeFileSync(process.env.TEST_EFFECTIVE_CWD, JSON.stringify({cwd: fs.realpathSync(cwd)}));
  let input = '';
  process.stdin.on('data', chunk => input += chunk);
  process.stdin.on('end', () => fs.writeFileSync(process.env.TEST_STDIN, input));
}
""")
        codex.chmod(0o755)
        harness = self.bin / "harness"
        harness.write_text('#!/bin/bash\nif [ "$3" = capture ]; then printf "{}" > "$5"; fi\n')
        harness.chmod(0o755)
        self.schema = self.root / "schema.json"
        self.schema.write_text('{"type":"object"}')
        self.paths = {key: self.root / name for key, name in {
            "TEST_CODEX_ARGS": "codex.json",
            "TEST_COMPANION_ARGS": "companion.json",
            "TEST_STDIN": "stdin.txt",
            "TEST_EFFECTIVE_TASK": "effective-task.json",
            "TEST_EFFECTIVE_CWD": "effective-cwd.json",
            "HARNESS_ORCHESTRATION_LEDGER": "ledger.jsonl",
        }.items()}
        self.env = {**os.environ, **{key: str(path) for key, path in self.paths.items()},
                    "HOME": str(self.root / "home"), "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "HARNESS_BIN": str(harness), "HARNESS_DISABLE_MODEL_ROUTING": "0",
                    "CODEX_MODEL_TIER": "standard", "CODEX_EFFORT": "",
                    "HARNESS_CODEX_DISABLE_PRIMARY_ENV_GUARD": "0",
                    "HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE": "0",
                    "HARNESS_CODEX_RESET_PRIMARY_ENVIRONMENT": "0",
                    "HARNESS_CODEX_PRIMARY_ENV_STATE_FILE": str(self.root / "primary.json")}

    def run_wrapper(self, *args, env=None, input=""):
        for path in self.paths.values():
            path.unlink(missing_ok=True)
        return subprocess.run(["bash", str(ROOT / "scripts/codex-companion.sh"), *args],
                              cwd=ROOT, env={**self.env, **(env or {})}, input=input,
                              text=True, capture_output=True, timeout=15)

    def captured(self, name):
        return json.loads(self.paths[name].read_text())

    def assert_pair(self, args, key, value):
        self.assertEqual(sum(args[i:i + 2] == [key, value] for i in range(len(args) - 1)), 1, args)

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("refusing provider dispatch", result.stderr)
        for key in ("TEST_CODEX_ARGS", "TEST_COMPANION_ARGS", "HARNESS_ORCHESTRATION_LEDGER"):
            self.assertFalse(self.paths[key].exists(), (key, result.stderr))

    def primary_directories(self):
        primary = self.root / "primary"
        target = self.root / "target"
        primary.mkdir()
        target.mkdir()
        Path(self.env["HARNESS_CODEX_PRIMARY_ENV_STATE_FILE"]).write_text(json.dumps({
            "version": 1, "repo_root": str(primary.resolve()), "git_dir": "", "branch": "", "cwd": str(primary.resolve())
        }))
        return primary, target

    def assert_primary_rejected(self, result):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("primary-environment-guard", result.stderr)
        for key in ("TEST_CODEX_ARGS", "TEST_COMPANION_ARGS", "HARNESS_ORCHESTRATION_LEDGER"):
            self.assertFalse(self.paths[key].exists(), (key, result.stderr))

    def assert_ledger_write(self, expected):
        records = [json.loads(line) for line in self.paths["HARNESS_ORCHESTRATION_LEDGER"].read_text().splitlines()]
        self.assertEqual(len(records), 1)
        self.assertIs(records[0]["write"], expected)

    def test_ultra_task_and_structured_task(self):
        for schema in ([], ["--output-schema", str(self.schema)]):
            for effort in (["--effort", "ultra"], ["--effort=ultra"],
                           ["-c", 'model_reasoning_effort="ultra"'],
                           ["-cmodel_reasoning_effort=ultra"],
                           ["--config=model_reasoning_effort='ultra'"]):
                with self.subTest(schema=schema, effort=effort):
                    result = self.run_wrapper("task", *schema, *effort, "fix the bug")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = self.captured("TEST_CODEX_ARGS")
                    self.assertEqual(args[0], "exec")
                    self.assert_pair(args, "-c", 'model_reasoning_effort="ultra"')
                    self.assertIn("fix the bug", args)
                    self.assertNotIn("--effort", args)
                    self.assertFalse(self.paths["TEST_COMPANION_ARGS"].exists())

    def test_task_effort_precedence_and_stdin(self):
        for tier, effort in (("standard", "xhigh"), ("release", "high"), ("lite", "low"), ("worker", "max")):
            with self.subTest(tier=tier):
                result = self.run_wrapper("task", env={"CODEX_MODEL_TIER": tier}, input="simple docs cleanup\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                key = "TEST_CODEX_ARGS" if effort == "max" else "TEST_COMPANION_ARGS"
                args = self.captured(key)
                self.assert_pair(args, "-c" if effort == "max" else "--effort",
                                 f'model_reasoning_effort="{effort}"' if effort == "max" else effort)
                self.assertEqual(self.paths["TEST_STDIN"].read_text(), "simple docs cleanup\n")
        for effort in ("low", "high", "xhigh", "max", "ultra"):
            with self.subTest(env_effort=effort):
                result = self.run_wrapper("task", "simple docs cleanup", env={"CODEX_MODEL_TIER": "worker", "CODEX_EFFORT": effort})
                self.assertEqual(result.returncode, 0, result.stderr)
                raw = effort in ("max", "ultra")
                args = self.captured("TEST_CODEX_ARGS" if raw else "TEST_COMPANION_ARGS")
                self.assert_pair(args, "-c" if raw else "--effort", f'model_reasoning_effort="{effort}"' if raw else effort)
                result = self.run_wrapper("task", "--effort", "high", "fix", env={"CODEX_MODEL_TIER": "worker", "CODEX_EFFORT": effort})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_pair(self.captured("TEST_COMPANION_ARGS"), "--effort", "high")

    def test_explicit_model_forms_are_preserved(self):
        for model in (["--model", "custom-model"], ["-m=custom-model"],
                      ["-c", 'model="custom-model"'], ["--config", "model='custom-model'"],
                      ["--config=model=custom-model"], ["-c=model=custom-model"],
                      ["-cmodel=custom-model"]):
            for effort in ("high", "ultra"):
                with self.subTest(model=model, effort=effort):
                    result = self.run_wrapper("task", *model, "--effort", effort, "fix")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = self.captured("TEST_CODEX_ARGS" if effort == "ultra" else "TEST_COMPANION_ARGS")
                    self.assert_pair(args, "--model", "custom-model")
                    self.assertEqual(args.count("--model"), 1)

    def test_invalid_or_duplicate_overrides_stop_before_dispatch(self):
        for args in (["--model"], ["--model="], ["--effort"], ["--effort=unknown"],
                     ["-c"], ["-c", "model="], ["-c", 'model="broken'],
                     ["-c", 'model="'], ["-c", "model='"],
                     ["-c", 'model_reasoning_effort="'], ["-c", "model_reasoning_effort='"],
                     ["--model", "one", "-c", 'model="two"'],
                     ["--effort", "high", "-c", 'model_reasoning_effort="ultra"'],
                     ["--effort", "high", "--effort", "high"]):
            for command in ("task", "review"):
                with self.subTest(command=command, args=args):
                    self.assert_rejected(self.run_wrapper(command, *args))
        self.assert_rejected(self.run_wrapper("task", "fix", env={"CODEX_EFFORT": "unknown"}))

    def test_unsupported_state_modes_fail_in_any_order(self):
        for command in ("task", "review", "adversarial-review"):
            for mode in ("--background", "--resume", "--resume-last", "--fresh", "--background=true", "--resume=job"):
                for order in ([mode, "--effort", "ultra"], ["--effort", "ultra", mode]):
                    with self.subTest(command=command, order=order):
                        self.assert_rejected(self.run_wrapper(command, *order))
        for order in (["--background", "--output-schema", str(self.schema)],
                      ["--output-schema", str(self.schema), "--background"]):
            self.assert_rejected(self.run_wrapper("task", *order, "fix"))

    def test_review_ultra_and_config_overrides_keep_envelope(self):
        for command in ("review", "adversarial-review"):
            for disabled in ("0", "1"):
                for overrides in (["--model", "custom-model", "--effort", "ultra"],
                                  ["-c", 'model="custom-model"', "--config=model_reasoning_effort=ultra"]):
                    with self.subTest(command=command, disabled=disabled, overrides=overrides):
                        result = self.run_wrapper(command, *overrides, "--base", "main", "--json",
                                                  env={"HARNESS_DISABLE_MODEL_ROUTING": disabled})
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(json.loads(result.stdout), {"review": "fixture", "target": "preserved"})
                        args = self.captured("TEST_CODEX_ARGS")
                        self.assertEqual(args[0], "app-server")
                        for config in ('model="custom-model"', 'review_model="custom-model"', 'model_reasoning_effort="ultra"'):
                            self.assert_pair(args, "-c", config)
                        companion = self.captured("TEST_COMPANION_ARGS")
                        self.assert_pair(companion, "--model", "custom-model")
                        self.assertNotIn("--effort", companion)

    def test_separator_keeps_prompt_tokens_out_of_option_parsing(self):
        for effort in ("high", "ultra"):
            with self.subTest(effort=effort):
                result = self.run_wrapper("task", "--effort", effort, "--", "--prompt-file", "missing-file")
                self.assertEqual(result.returncode, 0, result.stderr)
                args = self.captured("TEST_CODEX_ARGS" if effort == "ultra" else "TEST_COMPANION_ARGS")
                self.assertEqual(args[args.index("--") + 1:], ["--prompt-file", "missing-file"])
                self.assertIn("--model", args[:args.index("--")])
                if effort == "ultra":
                    self.assert_pair(args[:args.index("--")], "--sandbox", "read-only")

    def test_extra_task_config_is_passed_through_without_changing_effort(self):
        result = self.run_wrapper("task", "-c", 'model_verbosity="low"', "fix",
                                  env={"CODEX_EFFORT": "high"})
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.captured("TEST_CODEX_ARGS")
        self.assert_pair(args, "-c", 'model_verbosity="low"')
        self.assert_pair(args, "-c", 'model_reasoning_effort="high"')
        self.assert_rejected(self.run_wrapper("task", "--background", "-c", 'model_verbosity="low"', "fix"))
        self.assert_rejected(self.run_wrapper("review", "-c", 'model_verbosity="low"'))

    def test_routing_disabled_ultra_review_does_not_invent_a_model(self):
        result = self.run_wrapper("review", "--effort", "ultra", "--base", "main",
                                  env={"HARNESS_DISABLE_MODEL_ROUTING": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.captured("TEST_CODEX_ARGS")
        self.assert_pair(args, "-c", 'model_reasoning_effort="ultra"')
        self.assertEqual(args.count("-c"), 1)
        self.assertNotIn("--model", self.captured("TEST_COMPANION_ARGS"))

    def test_cwd_aliases_preserve_target_for_task_and_native_review(self):
        target = self.root / "review target=one"
        target.mkdir()
        Path(self.env["HARNESS_CODEX_PRIMARY_ENV_STATE_FILE"]).write_text(json.dumps({
            "version": 1, "repo_root": str(target.resolve()), "git_dir": "", "branch": "", "cwd": str(target.resolve())
        }))
        relative_target = os.path.relpath(target, ROOT)
        aliases = (["--cwd", relative_target], [f"--cwd={relative_target}"],
                   ["--cd", relative_target], [f"--cd={relative_target}"],
                   ["-C", relative_target], [f"-C{relative_target}"], [f"-C={relative_target}"])
        for command, effort in (("task", "high"), ("task", "ultra"), ("review", "high"), ("adversarial-review", "high")):
            for cwd_args in aliases:
                with self.subTest(command=command, effort=effort, cwd_args=cwd_args):
                    target_args = ["--write", "inspect source"] if command == "task" else ["--base", "main", "--json"]
                    result = self.run_wrapper(command, *cwd_args, "--model", "custom-model", "--effort", effort, *target_args)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    effective = self.captured("TEST_EFFECTIVE_CWD")
                    self.assertEqual(effective["cwd"], str(target.resolve()), effective)
                    args = self.captured("TEST_COMPANION_ARGS" if self.paths["TEST_COMPANION_ARGS"].exists() else "TEST_CODEX_ARGS")
                    self.assert_pair(args, "--model", "custom-model")
                    if command == "task":
                        self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "workspace-write")
                        self.assert_ledger_write(True)
                        self.assert_pair(args, "--effort" if effort == "high" else "-c",
                                         effort if effort == "high" else f'model_reasoning_effort="{effort}"')
                    else:
                        self.assertEqual(effective["positionals"], [])
                        self.assert_pair(args, "--base", "main")
                        self.assert_pair(self.captured("TEST_CODEX_ARGS"), "-c", 'model_reasoning_effort="high"')

    def test_runtime_sandbox_preserves_explicit_read_only(self):
        for sandbox in (["--sandbox", "read-only"], ["-s", "read-only"],
                        ["--sandbox=read-only"], ["-s=read-only"]):
            with self.subTest(sandbox=sandbox):
                result = self.run_wrapper("task", "--write", *sandbox, "inspect source",
                                          env={"CODEX_MODEL_TIER": "worker", "CODEX_EFFORT": "high"})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "read-only")
                self.assertFalse(self.paths["TEST_COMPANION_ARGS"].exists())
                self.assertIn("inspect source", self.captured("TEST_CODEX_ARGS"))
        for mode in ("--background", "--resume", "--resume-last", "--fresh"):
            self.assert_rejected(self.run_wrapper("task", mode, "--sandbox", "read-only", "inspect",
                                                  env={"CODEX_EFFORT": "high"}))

    def test_runtime_only_options_do_not_become_companion_prompt(self):
        for options in (["--add-dir", str(self.root)], ["--color=never"],
                        ["--ephemeral"], ["--skip-git-repo-check"],
                        ["--output-last-message", str(self.root / "message.txt")],
                        ["--image", str(self.root / "image.png")]):
            with self.subTest(options=options):
                result = self.run_wrapper("task", *options, "inspect source", env={"CODEX_EFFORT": "high"})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(self.paths["TEST_CODEX_ARGS"].exists(), "runtime-only options were sent to official companion")
                self.assertFalse(self.paths["TEST_COMPANION_ARGS"].exists())
                args = self.captured("TEST_CODEX_ARGS")
                for option in options:
                    self.assertIn(option, args)

    def test_official_task_write_flag_keeps_its_companion_semantics(self):
        result = self.run_wrapper("task", "--write", "inspect source", env={"CODEX_EFFORT": "high"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.captured("TEST_EFFECTIVE_TASK"), {"sandbox": "workspace-write", "positionals": ["inspect source"]})
        self.assertFalse(self.paths["TEST_CODEX_ARGS"].exists())

    def test_non_model_config_is_rejected_before_dispatch(self):
        for config in ('model_provider="fixture-provider"',
                       'model_providers.fixture.base_url="https://example.test"',
                       'mcp_servers.fixture.command="fixture-command"',
                       'sandbox_mode="danger-full-access"',
                       'approval_policy="never"', 'unknown_future_key=true'):
            for arguments in (["-c", config], [f"-c{config}"], [f"--config={config}"]):
                with self.subTest(arguments=arguments):
                    self.assert_rejected(self.run_wrapper("task", *arguments, "inspect source"))

    def test_runtime_write_option_keeps_primary_environment_guard(self):
        _, target = self.primary_directories()
        for options in (["--sandbox", "workspace-write"], ["-s=workspace-write"],
                        ["--full-auto"], ["--dangerously-bypass-approvals-and-sandbox"]):
            with self.subTest(options=options):
                result = self.run_wrapper("task", "--cwd", str(target), *options, "inspect source",
                                          env={"CODEX_EFFORT": "high", "HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE": "0"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("primary-environment-guard", result.stderr)
                for key in ("TEST_CODEX_ARGS", "TEST_COMPANION_ARGS", "HARNESS_ORCHESTRATION_LEDGER"):
                    self.assertFalse(self.paths[key].exists(), (key, result.stderr))

    def test_write_boolean_normalization_matches_provider_and_ledger(self):
        primary, _ = self.primary_directories()
        for tier in ("standard", "worker"):
            for runtime in ([], ["--ephemeral"]):
                for write in (True, False):
                    with self.subTest(tier=tier, runtime=runtime, write=write):
                        result = self.run_wrapper("task", "--cwd", str(primary), f"--write={str(write).lower()}",
                                                  *runtime, "inspect source", env={"CODEX_MODEL_TIER": tier})
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "workspace-write" if write else "read-only")
                        self.assert_ledger_write(write)
                        raw = bool(runtime) or tier == "worker"
                        args = self.captured("TEST_CODEX_ARGS" if raw else "TEST_COMPANION_ARGS")
                        self.assertFalse(any(arg.startswith("--write=") for arg in args), args)
                        self.assertEqual(args.count("--write"), int(write and not raw), args)

    def test_write_boolean_primary_boundary_and_explicit_sandbox(self):
        primary, target = self.primary_directories()
        for tier in ("standard", "worker"):
            for runtime in ([], ["--sandbox", "read-only"]):
                for write in (True, False):
                    with self.subTest(tier=tier, runtime=runtime, write=write):
                        result = self.run_wrapper("task", "--cwd", str(target), f"--write={str(write).lower()}",
                                                  *runtime, "inspect source", env={"CODEX_MODEL_TIER": tier})
                        if write:
                            self.assert_primary_rejected(result)
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "read-only")
                            self.assert_ledger_write(False)
            result = self.run_wrapper("task", "--cwd", str(primary), "--write=true", "--sandbox=read-only", "inspect source",
                                      env={"CODEX_MODEL_TIER": tier})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "read-only")
            self.assert_ledger_write(True)

    def test_yolo_alias_matches_canonical_bypass_and_primary_guard(self):
        primary, target = self.primary_directories()
        for tier in ("standard", "worker"):
            for cwd in (primary, target):
                with self.subTest(tier=tier, cwd=cwd):
                    result = self.run_wrapper("task", "--cwd", str(cwd), "--yolo", "inspect source", env={"CODEX_MODEL_TIER": tier})
                    if cwd == target:
                        self.assert_primary_rejected(result)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        args = self.captured("TEST_CODEX_ARGS")
                        self.assertEqual(args.count("--dangerously-bypass-approvals-and-sandbox"), 1, args)
                        self.assertNotIn("--yolo", args)
                        self.assertNotIn("--sandbox", args)
                        self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "danger-full-access")
                        self.assert_ledger_write(True)

    def test_attached_sandbox_and_cwd_keep_primary_boundary(self):
        primary, target = self.primary_directories()
        for cwd in (primary, target):
            for sandbox in ("read-only", "workspace-write", "danger-full-access"):
                with self.subTest(cwd=cwd, sandbox=sandbox):
                    result = self.run_wrapper("task", f"-C{cwd}", f"-s{sandbox}", "inspect source", env={"CODEX_EFFORT": "high"})
                    if cwd == target and sandbox != "read-only":
                        self.assert_primary_rejected(result)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], sandbox)
                        self.assert_ledger_write(sandbox != "read-only")

    def test_ambiguous_permission_arguments_reject_before_dispatch(self):
        for options in ([f"--write={value}"] for value in ("", "0", "yes", "FALSE", "true=ignored", "false=ignored")):
            with self.subTest(options=options):
                self.assert_rejected(self.run_wrapper("task", *options, "inspect source"))
        for options in (["-write"], ["--write", "--write=false"], ["--write=false", "--write=true"],
                        ["--write=true", "--write=true"], ["--full-auto=false"], ["--full-auto=true"],
                        ["--yolo=false"], ["--dangerously-bypass-approvals-and-sandbox=true"],
                        ["--yolo", "--dangerously-bypass-approvals-and-sandbox"],
                        ["--sandbox", "read-only", "-sworkspace-write"], ["--sandbox=unknown"],
                        ["--sandbox"], ["--cwd", "--write"], ["--image", "--write"]):
            with self.subTest(options=options):
                self.assert_rejected(self.run_wrapper("task", *options))

    def test_duplicate_cwd_and_prompt_options_cannot_redirect_guard(self):
        primary, target = self.primary_directories()
        for cwd in (["--cwd", str(primary), "--cwd", str(target)],
                    [f"--cwd={primary}", f"-C{target}"], ["-C", str(primary), "--cd", str(target)]):
            with self.subTest(cwd=cwd):
                self.assert_rejected(self.run_wrapper("task", "--write", *cwd, "inspect source",
                                                      env={"CODEX_MODEL_TIER": "worker", "CODEX_EFFORT": "high"}))
        self.assert_primary_rejected(self.run_wrapper("task", "--write", "--", "--cwd", str(primary),
                                                       env={"CODEX_MODEL_TIER": "worker", "CODEX_EFFORT": "high"}))
        for tier in ("standard", "worker"):
            with self.subTest(tier=tier):
                result = self.run_wrapper("task", "--", "--cwd", str(primary), "--write", "--yolo", "--profile", "fixture",
                                          env={"CODEX_MODEL_TIER": tier})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "read-only")
                self.assert_ledger_write(False)

    def test_unknown_runtime_options_reject_before_dispatch(self):
        for options in (["--profile", "fixture"], ["--profile=fixture"], ["-pfixture"], ["--oss"],
                        ["--local-provider", "fixture"], ["--ignore-rules"], ["--ignore-user-config"],
                        ["--dangerously-bypass-hook-trust"], ["--enable", "fixture_feature"], ["--disable=fixture_feature"],
                        ["--approve-for-me"], ["--not-so-yolo"], ["--future-runtime-option"], ["--ask-for-approval", "never"]):
            for tier in ("standard", "worker"):
                with self.subTest(options=options, tier=tier):
                    self.assert_rejected(self.run_wrapper("task", *options, "inspect source", env={"CODEX_MODEL_TIER": tier}))

    def test_false_write_does_not_erase_explicit_sandbox_intent(self):
        primary, target = self.primary_directories()
        for options, sandbox in ((["--sandbox", "workspace-write"], "workspace-write"), (["--yolo"], "danger-full-access")):
            for flags in (["--write=false", *options], [*options, "--write=false"]):
                for cwd in (primary, target):
                    with self.subTest(flags=flags, cwd=cwd):
                        result = self.run_wrapper("task", "--cwd", str(cwd), *flags, "inspect source")
                        if cwd == target:
                            self.assert_primary_rejected(result)
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], sandbox)
                            self.assert_ledger_write(True)

    def test_relative_prompt_file_uses_resolved_target_cwd(self):
        target = self.root / "prompt=target"
        target.mkdir()
        prompt_file = target / "instructions=review.txt"
        prompt_file.write_text("instructions from target cwd\n")
        for tier in ("standard", "worker"):
            for args in (["--cwd", str(target), "--prompt-file", prompt_file.name],
                         [f"--prompt-file={prompt_file.name}", f"--cwd={target}"]):
                with self.subTest(tier=tier, args=args):
                    result = self.run_wrapper("task", *args, env={"CODEX_MODEL_TIER": tier})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.paths["TEST_STDIN"].read_text(), prompt_file.read_text())

    def test_add_dir_with_write_intent_rejects_before_dispatch(self):
        primary, other = self.primary_directories()
        # The primary cwd is valid. Reject the extra writable root itself,
        # rather than relying on a non-primary cwd to trigger the usual guard.
        for tier in ("standard", "worker"):
            for write in (["--write"], ["--write=true"], ["--sandbox", "workspace-write"],
                          ["--write=false", "-sdanger-full-access"], ["--yolo"], ["--full-auto"],
                          ["--write", "--sandbox", "read-only"]):
                for flags in ([*write, "--add-dir", str(other)], [f"--add-dir={other}", *write]):
                    with self.subTest(tier=tier, flags=flags):
                        result = self.run_wrapper("task", "--cwd", str(primary), *flags, "inspect source",
                                                  env={"CODEX_MODEL_TIER": tier})
                        self.assert_rejected(result)
                        self.assertIn("--add-dir", result.stderr)

    def test_add_dir_read_only_and_prompt_literal_are_preserved(self):
        primary, other = self.primary_directories()
        for tier in ("standard", "worker"):
            for readonly in ([], ["--write=false"], ["--sandbox=read-only"], ["--write=false", "-sread-only"]):
                with self.subTest(tier=tier, readonly=readonly):
                    result = self.run_wrapper("task", "--cwd", str(primary), "--add-dir", str(other),
                                              *readonly, f"--add-dir={primary}", "inspect source",
                                              env={"CODEX_MODEL_TIER": tier})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = self.captured("TEST_CODEX_ARGS")
                    self.assert_pair(args, "--add-dir", str(other))
                    self.assertIn(f"--add-dir={primary}", args)
                    self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "read-only")
                    self.assert_ledger_write(False)
            result = self.run_wrapper("task", "--cwd", str(primary), "--write", "--", "--add-dir", str(other),
                                      env={"CODEX_MODEL_TIER": tier})
            self.assertEqual(result.returncode, 0, result.stderr)
            args = self.captured("TEST_CODEX_ARGS" if tier == "worker" else "TEST_COMPANION_ARGS")
            self.assertEqual(args[args.index("--") + 1:], ["--add-dir", str(other)])
            self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "workspace-write")
            self.assert_ledger_write(True)
            result = self.run_wrapper("task", "--cwd", str(primary), "--write", "--image", str(other / "image.png"),
                                      "inspect source", env={"CODEX_MODEL_TIER": tier})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_pair(self.captured("TEST_CODEX_ARGS"), "--image", str(other / "image.png"))
            self.assertEqual(self.captured("TEST_EFFECTIVE_TASK")["sandbox"], "workspace-write")
            self.assert_ledger_write(True)


if __name__ == "__main__":
    unittest.main()
