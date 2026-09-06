#!/usr/bin/env python3
"""Exercise the actual loop dispatch boundary without calling a provider."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PromptDeliveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="loop-prompt-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.project = self.base / "target-project"
        self.env = os.environ.copy()
        self.env.update(PROJECT_ROOT=str(self.project), HARNESS_INSTALL_ROOT=str(ROOT))
        subprocess.run([
            "bash", "-c",
            'HARNESS_CODEX_LOOP_TEST_SOURCE_ONLY=1 source "$1/tests/test-codex-loop-cli.sh"; '
            'setup_repo "$2"; setup_fake_tools "$3" retry',
            "fixture", str(ROOT), str(self.project), str(self.base),
        ], env=self.env, check=True, capture_output=True, text=True)
        self.plan = self.project / "plans" / "Chosen.md"
        self.plan.parent.mkdir()
        self.plan.write_text(
            "# Account isolation\n\nKeep tenant records separate during retry.\n\n"
            "| Task | 内容 | DoD | Depends | Status |\n"
            "|------|------|-----|---------|--------|\n"
            "| 1 | Correct tenant lookup | Cross-tenant regression passes | - | cc:TODO |\n"
        )
        self.contract = self.project / ".claude/state/contracts/1.sprint-contract.json"
        self.contract.parent.mkdir()
        self.write_contract()
        generator = self.base / "bin/fake-generate-contract.sh"
        generator.write_text('#!/bin/bash\nprintf "%s\\n" "$PROJECT_ROOT/.claude/state/contracts/1.sprint-contract.json"\n')
        self.state = self.project / ".claude/state/codex-loop"
        self.state.mkdir()
        self.results = self.state / "results"
        self.results.mkdir()
        self.run = self.state / "run.json"
        self.run.write_text(json.dumps({
            "schema_version": "codex-loop-run.v1", "run_id": "delivery",
            "project_root": str(self.project), "plans_file": str(self.plan),
            "consulted_trigger_hashes": [], "task_consultations": {},
        }))
        for key, filename in {
            "COMPANION": "fake-companion.sh", "VALIDATE_SCRIPT": "fake-validate.sh",
            "GENERATE_CONTRACT_SCRIPT": "fake-generate-contract.sh",
            "ENRICH_CONTRACT_SCRIPT": "fake-enrich-contract.sh",
            "ENSURE_CONTRACT_SCRIPT": "fake-ensure-contract.sh",
            "RUNTIME_REVIEW_SCRIPT": "fake-runtime-review.sh",
            "WRITE_REVIEW_RESULT_SCRIPT": "fake-write-review-result.sh",
            "PLATEAU_SCRIPT": "fake-plateau.sh", "CHECKPOINT_SCRIPT": "fake-checkpoint.sh",
            "ADVISOR_SCRIPT": "fake-advisor.sh", "MEM_CLIENT": "fake-mem.sh",
        }.items():
            self.env[f"CODEX_LOOP_{key}"] = str(self.base / "bin" / filename)
        self.env.update(HARNESS_PLAN_FILE=str(self.plan), CODEX_LOOP_TASK_DRIVER="companion",
                        CODEX_LOOP_POLL_INTERVAL_SEC="0.01")

    def write_contract(self, *, triggers=(), authorization=False):
        source = {"plans_file": str(self.plan), "task_id": "1"}
        if authorization:
            source["authorization_refs"] = ["conversation:approved-local-tenant-fix"]
        self.contract.write_text(json.dumps({
            "source": source,
            "task": {"id": "1", "title": "Correct tenant lookup",
                     "definition_of_done": "Cross-tenant regression passes",
                     "declared_scope": ["src/tenant.py", "tests/test_tenant.py"]},
            "contract": {"checks": [{"id": "tenant-regression", "description": "Run tenant regression"}],
                         "non_goals": ["No production migration"], "risk_flags": list(triggers)},
            "review": {"reviewer_profile": "static", "status": "approved",
                       "approved_at": "fixture-review-approval-is-not-user-authorization"},
            "advisor": {"enabled": True, "triggers": list(triggers)},
        }))

    def shell(self, command, expected=0):
        result = subprocess.run([
            "bash", "-c", 'HARNESS_CODEX_LOOP_SOURCE_ONLY=1 source "$1"; ensure_dirs; ' + command,
            "test", str(ROOT / "scripts/codex-loop.sh"),
        ], env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        return result

    def cycle(self, *, batch=False):
        command = 'perform_breezing_cycle delivery 1 1 2' if batch else 'perform_cycle delivery 1 1'
        return self.shell(command, expected=21)

    def prompt(self, batch=False):
        suffix = ".breezing" if batch else ""
        return (self.state / f"prompts/delivery-cycle-1{suffix}.md").read_text()

    def advisor_request_path(self, reason="retry-threshold"):
        paths = list(self.results.glob(f"1.{reason}*.advisor-request.json"))
        self.assertTrue(paths, f"missing advisor request for {reason}")
        return max(paths, key=lambda path: path.stat().st_mtime_ns)

    def use_local_result(self, payload):
        result_file = self.base / "local-result.json"
        result_file.write_text(payload)
        self.env["LOCAL_RESULT_FILE"] = str(result_file)
        companion = self.base / "bin/fake-companion.sh"
        text = companion.read_text()
        start = text.index("  result)")
        end = text.index("  cancel)", start)
        companion.write_text(text[:start] + '  result)\n    cat "$LOCAL_RESULT_FILE"\n    ;;\n' + text[end:])

    def test_selected_contract_reaches_worker_and_toolsless_advisor(self):
        self.write_contract(triggers=["security-sensitive"], authorization=True)
        capture = self.base / "advisor-prompt.txt"
        companion = self.base / "bin/toolsless-advisor.sh"
        companion.write_text('#!/bin/bash\ncat > "$ADVISOR_PROMPT_CAPTURE"\n'
                             'printf \'%s\\n\' \'{"schema_version":"advisor-response.v1","decision":"PLAN",'
                             '"summary":"Use tenant filter","executor_instructions":["Check tenant boundary"],'
                             '"confidence":0.9,"stop_reason":null}\'\n')
        self.env.update(CODEX_LOOP_ADVISOR_SCRIPT=str(ROOT / "scripts/run-advisor-consultation.sh"),
                        CODEX_ADVISOR_COMPANION=str(companion), ADVISOR_PROMPT_CAPTURE=str(capture))
        self.cycle()
        for delivered in [self.prompt(), capture.read_text()]:
            for expected in [str(self.plan), "Correct tenant lookup", "Cross-tenant regression passes",
                             "src/tenant.py", "Run tenant regression", "No production migration",
                             "Keep tenant records separate during retry.",
                             "conversation:approved-local-tenant-fix"]:
                with self.subTest(expected=expected):
                    self.assertIn(expected, delivered)
            self.assertIn("inferred", delivered.lower())
            self.assertNotIn("fixture-review-approval-is-not-user-authorization", delivered)
        captured_request, _ = json.JSONDecoder().raw_decode(capture.read_text().split("Request JSON:\n", 1)[1])
        self.assertEqual(["Check tenant boundary"],
                         captured_request["prior_advisor_response"]["response"]["executor_instructions"])

    def test_batch_receives_selected_plan_task_and_contract(self):
        self.cycle(batch=True)
        delivered = self.prompt(batch=True)
        for expected in [str(self.plan), "Correct tenant lookup", "Cross-tenant regression passes",
                         "src/tenant.py", "No production migration"]:
            self.assertIn(expected, delivered)
        self.assertNotIn('"authorization_refs"', delivered)

    def test_failure_details_survive_worker_result_and_retry_consultation(self):
        companion = self.base / "bin/fake-companion.sh"
        companion.write_text(companion.read_text().replace("summary", "tests/test_tenant.py:42 expected tenant-A got tenant-B"))
        self.cycle()
        request = json.loads(self.advisor_request_path().read_text())
        self.assertIn("tests/test_tenant.py:42", request["last_error"])
        review = json.loads((self.results / "delivery-cycle-1.review-input.json").read_text())
        self.assertIn("expected tenant-A got tenant-B", review["recommendations"][0])
        cycle = json.loads((self.state / "cycles.jsonl").read_text().splitlines()[-1])
        self.assertIn("tests/test_tenant.py:42", cycle["summary"])

    def test_batch_failure_detail_is_retained(self):
        self.cycle(batch=True)
        review = json.loads((self.results / "delivery-cycle-1.breezing.review-input.json").read_text())
        self.assertIn("summary", review["recommendations"][0])

    def test_restart_restores_deduplicated_guidance_without_consulting_again(self):
        self.cycle()
        first_run = json.loads(self.run.read_text())
        self.assertEqual(1, first_run["consultations"])
        self.cycle()
        self.assertEqual(1, json.loads(self.run.read_text())["consultations"])
        self.assertIn("follow advisor PLAN", self.prompt())

    def test_failed_reconsultation_preserves_successful_pair_across_restart(self):
        self.cycle()
        successful_request = self.advisor_request_path()
        successful_response = successful_request.with_name(successful_request.name.replace(
            ".advisor-request.json", ".advisor-response.json"))
        original_pair = (successful_request.read_bytes(), successful_response.read_bytes())
        companion = self.base / "bin/fake-companion.sh"
        companion.write_text(companion.read_text().replace("summary", "new distinct failure B"))
        advisor = self.base / "bin/fake-advisor.sh"
        advisor.write_text(advisor.read_text() + "\nexit 1\n")
        self.env["FAKE_ADVISOR_DECISION"] = "STOP"
        self.cycle()
        self.assertIn("follow advisor PLAN", self.prompt())
        self.assertEqual(1, json.loads(self.run.read_text())["consultations"])
        with self.subTest(boundary="saved successful pair"):
            self.assertEqual(original_pair, (successful_request.read_bytes(), successful_response.read_bytes()))
        self.cycle()
        self.assertIn("follow advisor PLAN", self.prompt())
        self.assertEqual(1, json.loads(self.run.read_text())["consultations"])

    def test_successful_pairs_with_same_trigger_are_isolated_by_run(self):
        command = ('consult_advisor 1 retry-threshold "1:retry-threshold:shared-error" '
                   '"Resolve the error" 2 "shared error" "task=1" '
                   '"$PROJECT_ROOT/.claude/state/contracts/1.sprint-contract.json"')
        saved_runs = []
        for run_id, decision in [("older-run", "STOP"), ("newer-run", "PLAN")]:
            self.run.write_text(json.dumps({
                "run_id": run_id, "project_root": str(self.project), "plans_file": str(self.plan),
                "consulted_trigger_hashes": [], "task_consultations": {},
            }))
            self.env["FAKE_ADVISOR_DECISION"] = decision
            response = self.shell(command).stdout.strip()
            saved_runs.append((run_id, self.run.read_bytes(), response))
        for run_id, run_state, response in saved_runs:
            with self.subTest(run_id=run_id):
                self.run.write_bytes(run_state)
                self.assertEqual(response, self.shell('restore_advisor_response 1').stdout.strip())
    def test_local_crash_error_reaches_retry_advisor_and_cycle_evidence(self):
        jobs = self.state / "jobs"
        jobs.mkdir()
        (jobs / "crashed.json").write_text(json.dumps({"id": "crashed", "status": "running", "pid": None}))
        payload = self.shell('local_task_result_json crashed').stdout
        expected = json.loads(payload)["storedJob"]["errorMessage"]
        self.assertEqual("Loop worker terminated before recording a pid.", expected)
        self.use_local_result(payload)
        self.cycle()
        request = json.loads(self.advisor_request_path().read_text())
        self.assertIn(expected, request["last_error"])
        self.assertIn("failed", request["last_error"])
        cycle = json.loads((self.state / "cycles.jsonl").read_text().splitlines()[-1])
        self.assertIn(expected, cycle["summary"])

    def test_local_nonzero_exit_preserves_partial_output_and_error(self):
        jobs = self.state / "jobs"
        jobs.mkdir()
        prompt = self.base / "local-prompt.md"
        prompt.write_text("Check the tenant lookup.")
        (jobs / "nonzero.json").write_text(json.dumps({
            "id": "nonzero", "status": "queued", "request": {"promptFile": str(prompt)},
        }))
        codex = self.base / "bin/codex"
        codex.write_text(codex.read_text().replace('echo "fake codex failed" >&2',
                                                  'echo "Partial tenant diagnostic"\necho "fake codex failed" >&2'))
        self.env.update(PATH=str(self.base / "bin") + os.pathsep + self.env["PATH"], FAKE_CODEX_MODE="fail")
        self.shell('run_local_task_worker --job-id nonzero', expected=42)
        payload = self.shell('local_task_result_json nonzero').stdout
        self.assertEqual(42, json.loads(payload)["storedJob"]["result"]["status"])
        self.use_local_result(payload)
        self.cycle()
        request = json.loads(self.advisor_request_path().read_text())
        self.assertIn("Partial tenant diagnostic", request["last_error"])
        self.assertIn("codex exec exited with status 42", request["last_error"])
        self.assertIn("failed", request["last_error"])

    def test_missing_local_job_reports_status_without_inventing_a_cause(self):
        summary = self.shell('task_result_summary "$(local_task_result_json missing-job)"').stdout.strip()
        self.assertIn("missing", summary)

    def test_large_plan_reaches_advisor_without_oversized_process_arguments(self):
        background = "Keep tenant records separate during retry.\n" + "tenant context 日本語 " * 11000 + "\nPLAN_TAIL_SENTINEL"
        plan = self.plan.read_text().replace("Keep tenant records separate during retry.", background)
        self.plan.write_text(plan)
        self.assertGreater(len(plan.encode("utf-8")), 131072)
        # Model Linux's 4 KiB-page MAX_ARG_STRLEN on every host. The fixture
        # still executes the real JSON helpers and verifies full delivery.
        result = self.shell('''
python_json() {
  local LC_ALL=C value
  for value in "$@"; do
    if [ "${#value}" -ge 131072 ]; then
      printf 'SIMULATED_LINUX_E2BIG: argument bytes=%s\\n' "${#value}" >&2
      return 126
    fi
  done
  python3 - "$@"
}
perform_cycle delivery 1 1
''', expected=21)
        self.assertNotIn("SIMULATED_LINUX_E2BIG", result.stderr)
        request = json.loads(self.advisor_request_path().read_text())
        delivered = request["execution_context"]["selected_plan"]["background"]
        self.assertTrue("# Account isolation\n\n" + background in delivered,
                        "full Japanese plan background must reach the advisor unchanged")

    def test_large_local_status_reaches_single_and_batch_cycles(self):
        raw = "RESULT: BLOCKED\n" + "worker diagnostic " * 35000 + "\nfailed tenant check\n"
        job = {"id": "oversized", "status": "failed", "phase": "failed",
               "result": {"rawOutput": raw, "status": 42}, "rendered": raw,
               "errorMessage": "codex exec exited with status 42"}
        jobs = self.state / "jobs"
        jobs.mkdir()
        (jobs / "oversized.json").write_text(json.dumps(job))
        status = self.shell('local_task_status_json oversized').stdout
        self.assertGreater(len(status.encode("utf-8")), 1048576)
        status_file = self.base / "native-status.json"
        status_file.write_text(status)
        self.env["NATIVE_STATUS_FILE"] = str(status_file)
        companion = self.base / "bin/fake-companion.sh"
        text = companion.read_text()
        start = text.index("  status)")
        end = text.index("  result)", start)
        companion.write_text(text[:start] + '  status)\n    cat "$NATIVE_STATUS_FILE"\n    ;;\n' + text[end:])
        self.use_local_result(json.dumps({"storedJob": job}))
        for batch in (False, True):
            with self.subTest(batch=batch):
                result = self.cycle(batch=batch)
                self.assertNotIn("argument list too long", result.stderr.lower())
                cycle = json.loads((self.state / "cycles.jsonl").read_text().splitlines()[-1])
                self.assertEqual("failed", cycle["job_status"])
                self.assertIn("failed tenant check", cycle["summary"])
                self.assertIn("codex exec exited with status 42", cycle["summary"])
                self.assertLessEqual(len(cycle["summary"].encode("utf-8")), 8192)

    def test_large_worker_output_is_bounded_before_advisor_arguments(self):
        plan = self.plan.read_text()
        self.plan.write_text(plan.replace("Keep tenant records separate during retry.",
                                         "Keep tenant records separate during retry.\n" + "plan context " * 11000))
        raw = ("RESULT: BLOCKED\nHEAD: tenant lookup diagnostic begins\n" + "worker diagnostic " * 51000
               + "\nTAIL: tests/test_tenant.py:42 expected tenant-A got tenant-B\n")
        payload = {"storedJob": {"status": "failed", "errorMessage": "codex exec exited with status 42",
                                 "result": {"status": 42, "rawOutput": raw}}}
        self.use_local_result(json.dumps(payload))
        result = self.cycle()
        self.assertNotIn("argument list too long", result.stderr.lower(), result.stderr)
        request = json.loads(self.advisor_request_path().read_text())
        review = json.loads((self.results / "delivery-cycle-1.review-input.json").read_text())
        cycle = json.loads((self.state / "cycles.jsonl").read_text().splitlines()[-1])
        for summary in [request["last_error"], review["recommendations"][0], cycle["summary"]]:
            self.assertLessEqual(len(summary.encode("utf-8")), 8192)
            self.assertIn("HEAD: tenant lookup diagnostic begins", summary)
            self.assertIn("TAIL: tests/test_tenant.py:42 expected tenant-A got tenant-B", summary)
            self.assertIn("codex exec exited with status 42", summary)
            self.assertIn("truncated", summary.lower())
            self.assertIn(".worker-result.json", summary)
        evidence_files = list(self.results.glob("*.worker-result.json"))
        self.assertTrue(evidence_files, "full worker result must remain available")
        for evidence_file in evidence_files:
            self.assertEqual(payload, json.loads(evidence_file.read_text()))

    def test_restart_preserves_prior_stop_before_dispatch(self):
        self.write_contract(triggers=["security-sensitive"])
        self.env["FAKE_ADVISOR_DECISION"] = "STOP"
        self.cycle()
        self.assertFalse((self.base / "companion-state/prompt-file").exists())
        self.cycle()
        self.assertFalse((self.base / "companion-state/prompt-file").exists(),
                         "deduplication must not bypass the prior STOP decision")
        self.assertEqual(1, json.loads(self.run.read_text())["consultations"])

    def test_resume_is_project_scoped_and_delivered_as_evidence(self):
        capture = self.base / "memory-request.json"
        mem = self.base / "bin/fake-mem.sh"
        mem.write_text('#!/bin/bash\ncat > "$MEMORY_REQUEST_CAPTURE"\n'
                       'printf \'%s\\n\' \'{"ok":true,"items":['
                       '{"project":"target-project","content":"prior tenant filter failed","id":"obs-own"},'
                       '{"project":"other-project","content":"FOREIGN-SECRET-CONTEXT","id":"obs-foreign"},'
                       '{"content":"UNSCOPED-CONTEXT","id":"obs-unknown"}],'
                       '"meta":{"summary":"UNSCOPED-SUMMARY"}}\'\n')
        self.env["MEMORY_REQUEST_CAPTURE"] = str(capture)
        self.cycle()
        payload = json.loads(capture.read_text())
        self.assertEqual("target-project", payload["project"])
        request = self.advisor_request_path().read_text()
        for delivered in [self.prompt(), request]:
            self.assertIn("prior tenant filter failed", delivered)
            self.assertIn("untrusted", delivered.lower())
            for forbidden in ["FOREIGN-SECRET-CONTEXT", "UNSCOPED-CONTEXT", "UNSCOPED-SUMMARY"]:
                self.assertNotIn(forbidden, delivered)
        mem.write_text('#!/bin/bash\nexit 1\n')
        self.cycle()
        self.assertNotIn("prior tenant filter failed", self.prompt(), "failed refresh must not replay stale evidence")

    def test_weak_cues_follow_all_actual_loop_triggers(self):
        ledger = self.project / ".claude/state/elicitation/events.jsonl"
        ledger.parent.mkdir()
        ledger.write_text("\n".join(json.dumps({
            "schema_version": "elicitation-event.v1", "event_kind": "eval_result",
            "task_id": task_id, "message": message,
        }) for task_id, message in [("1", "Tenant lookup failed before"), ("2", "UNRELATED-TASK")]))
        request = self.base / "cue-request.json"
        for reason in ["high-risk-preflight", "retry-threshold", "plateau-pre-escalation"]:
            with self.subTest(reason=reason):
                request.write_text(json.dumps({"task_id": "1", "reason_code": reason}))
                result = subprocess.run([
                    "bash", str(ROOT / "scripts/build-weak-supervision-cues.sh"),
                    "--request-file", str(request), "--project-root", str(self.project),
                ], check=True, capture_output=True, text=True)
                self.assertIn("Tenant lookup failed before", result.stdout)
                self.assertNotIn("UNRELATED-TASK", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
