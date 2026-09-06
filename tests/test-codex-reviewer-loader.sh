#!/usr/bin/env bash
# Exercise the setup entrypoints with isolated homes and a local clone fixture.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib

root = Path(sys.argv[1])
description = "Codex reviewer worker for harness review and retake loops"
failures = []
checks = 0


def check(label, action):
    global checks
    checks += 1
    try:
        action()
    except (AssertionError, KeyError, OSError, subprocess.CalledProcessError) as error:
        failures.append(label)
        print(f"FAIL {label}: {error}")
    else:
        print(f"PASS {label}")


def read_config(path):
    return tomllib.loads(path.read_text())


def assert_reference(config):
    reviewer = read_config(config)["agents"]["reviewer"]
    assert reviewer.get("config_file") == "agents/reviewer.toml", (
        "inline agents.reviewer must explicitly load agents/reviewer.toml; "
        f"observed config_file={reviewer.get('config_file')!r}"
    )
    profile = config.parent / reviewer["config_file"]
    assert profile.is_file(), f"referenced reviewer profile does not exist: {profile}"
    assert read_config(profile)["name"] == "reviewer"


check("package template points to its reviewer profile", lambda: assert_reference(root / "codex/.codex/config.toml"))

with tempfile.TemporaryDirectory(prefix="codex reviewer loader ") as tmp:
    tmp = Path(tmp)
    source = tmp / "source package"
    (source / "codex/.codex/skills/breezing").mkdir(parents=True)
    (source / "codex/.codex/skills/breezing/SKILL.md").write_text("---\nname: breezing\ndescription: setup fixture\n---\n")
    (source / "codex/.codex/rules").mkdir()
    (source / "codex/.codex/rules/harness.rules").write_text("# Setup fixture\n")
    (source / "codex/.codex/agents").mkdir()
    shutil.copy2(root / "codex/.codex/agents/reviewer.toml", source / "codex/.codex/agents/reviewer.toml")
    (source / "codex/AGENTS.md").write_text("# Setup fixture\n")
    fake_bin = tmp / "bin"
    fake_bin.mkdir()
    fake_git = fake_bin / "git"
    fake_git.write_text('''#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = clone ] || exit 2
destination="${!#}"
mkdir -p "$destination"
cp -R "$FAKE_HARNESS_SOURCE/." "$destination/"
''')
    fake_git.chmod(0o755)

    def run_setup(kind, case, mode="user", content=None, symlink=False, custom_profile=None):
        case_dir = tmp / f"{kind} {case} {mode}"
        home = case_dir / "home"
        project = case_dir / "project"
        home.mkdir(parents=True, exist_ok=True)
        project.mkdir(exist_ok=True)
        config_dir = (home if mode == "user" else project) / ".codex"
        config_dir.mkdir(exist_ok=True)
        config = config_dir / "config.toml"
        if custom_profile is not None:
            (config_dir / "profiles").mkdir(exist_ok=True)
            (config_dir / "profiles/custom reviewer.toml").write_text(custom_profile)
        if content is not None:
            if symlink:
                target = case_dir / "linked config.toml"
                target.write_text(content)
                config.symlink_to(target)
            else:
                config.write_text(content)
        env = dict(os.environ, HOME=str(home), CODEX_HOME=str(home / ".codex"),
                   CLAUDE_PLUGIN_ROOT=str(source), FAKE_HARNESS_SOURCE=str(source),
                   PATH=f"{fake_bin}{os.pathsep}{os.environ['PATH']}")
        script = "codex-setup-local.sh" if kind == "local" else "setup-codex.sh"
        result = subprocess.run(["bash", str(root / "scripts" / script), f"--{mode}"],
                                cwd=project, env=env, text=True, capture_output=True)
        assert result.returncode == 0, f"setup exited {result.returncode}: {result.stdout}{result.stderr}"
        return config

    for kind in ("local", "remote"):
        for mode in ("user", "project"):
            check(f"{kind} fresh {mode} setup", lambda k=kind, m=mode: assert_reference(run_setup(k, "fresh", m)))
        check(f"{kind} existing config without reviewer", lambda k=kind: assert_reference(run_setup(k, "missing reviewer", content='model = "operator-model"\n')))

        def legacy_case(kind, sandbox):
            content = (f'model = "operator-model"\nmodel_reasoning_effort = "low"\n'
                       'approval_policy = "on-request"\nsandbox_mode = "workspace-write"\n'
                       '[agents]\nmax_threads = 3\n[agents.reviewer] # old setup role\n'
                       f'description = "{description}"\n' + sandbox +
                       '[custom]\nmarker = "preserved"\n')
            case = "legacy with sandbox" if sandbox else "legacy without sandbox"
            config = run_setup(kind, case, content=content, symlink=True)
            assert config.is_symlink(), "config symlink was replaced"
            assert_reference(config)
            document = read_config(config)
            before = tomllib.loads(content)
            for key in ("model", "model_reasoning_effort", "approval_policy", "sandbox_mode", "custom"):
                assert document[key] == before[key], f"operator setting changed: {key}"
            assert document["agents"]["max_threads"] == 3
            before["agents"]["reviewer"]["config_file"] = "agents/reviewer.toml"
            assert document["agents"]["reviewer"] == before["agents"]["reviewer"]
            assert any(p.read_text() == content for p in (config.parent / "backups").rglob("config.toml.*")), "original config was not backed up"
            first = config.read_bytes()
            run_setup(kind, case)
            assert config.read_bytes() == first, "second setup changed an already linked role"

        for sandbox in ("", 'sandbox = "workspace-read-only"\n'):
            check(f"{kind} migrate legacy reviewer ({'sandbox' if sandbox else 'description only'})", lambda k=kind, s=sandbox: legacy_case(k, s))

        def custom_case(kind, case, role):
            content = f'model = "operator-model"\nmodel_reasoning_effort = "low"\n[agents.reviewer]\n{role}'
            profile = ('name = "reviewer"\nmodel = "operator-reviewer"\n'
                       'model_reasoning_effort = "low"\nsandbox_mode = "read-only"\n'
                       'developer_instructions = "My review instructions"\n')
            config = run_setup(kind, case, content=content, custom_profile=profile)
            document = read_config(config)
            assert document["agents"]["reviewer"] == tomllib.loads(content)["agents"]["reviewer"], "custom inline reviewer was changed"
            assert (config.parent / "profiles/custom reviewer.toml").read_text() == profile, "custom profile was changed"
            assert document["model"] == "operator-model"
            assert document["model_reasoning_effort"] == "low"

        custom_roles = {
            "manual config file": f'description = "{description}"\nconfig_file = "profiles/custom reviewer.toml"\n',
            "manual literal config file": f'description = "{description}"\n\'config_file\' = \'profiles/custom reviewer.toml\'\n',
            "manual role settings": f'description = "{description}"\nmodel = "operator-reviewer"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\napproval_policy = "on-request"\n',
            "manual permissions": f'description = "{description}"\nsandbox = "workspace-write"\n',
            "custom description": 'description = "My independent reviewer"\n',
        }
        for case, role in custom_roles.items():
            check(f"{kind} preserve {case}", lambda k=kind, c=case, r=role: custom_case(k, c, r))

print(f"{checks - len(failures)}/{checks} reviewer loader checks passed")
if failures:
    raise SystemExit(1)
PY
