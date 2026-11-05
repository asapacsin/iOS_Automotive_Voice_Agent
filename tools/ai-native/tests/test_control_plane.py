import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import control_plane as cp


class ControlPlaneTests(unittest.TestCase):
    def cycle_state(self, **overrides):
        state = {
            "schema_version": 1, "task_status": "PASS", "attempt": 1, "max_attempts": 3,
            "deadline_exceeded": False, "executor_configured": True, "executor_status": "PASS",
            "reviewer_configured": True, "reviewer_process_status": "PASS",
            "reviewer_verdict": "PASS", "reviewer_independent": True,
            "current_fingerprint": "a" * 64, "reviewed_fingerprint": "a" * 64,
            "contract_hash": "b" * 64, "reviewed_contract_hash": "b" * 64,
            "gates": [{"id": "unit", "required": True, "status": "PASS"}],
            "gate_source_fingerprint": "a" * 64
        }
        state.update(overrides)
        return state

    def test_cycle_pass_is_deterministically_verified(self):
        result = cp.decide_cycle(self.cycle_state())
        self.assertEqual(result["action"], "TASK_VERIFIED")
        self.assertEqual(result["decision_sha256"], cp.canonical_hash({k:v for k,v in result.items() if k != "decision_sha256"}))

    def test_executor_failure_retries_when_budget_remains(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(task_status="REWORK", executor_status="FAIL"))["action"], "RETRY_EXECUTOR")

    def test_retry_limit_escalates(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(task_status="REWORK", executor_status="FAIL", attempt=3))["action"], "ESCALATE_RETRY_LIMIT")

    def test_deadline_overrides_apparent_pass(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(deadline_exceeded=True))["action"], "ESCALATE_BUDGET")

    def test_gate_failure_overrides_reviewer_pass(self):
        gates = [{"id":"unit", "required":True, "status":"FAIL"}]
        self.assertEqual(cp.decide_cycle(self.cycle_state(gates=gates))["action"], "RETRY_EXECUTOR")

    def test_blocked_gate_waits_external(self):
        gates = [{"id":"device", "required":True, "status":"BLOCKED"}]
        self.assertEqual(cp.decide_cycle(self.cycle_state(gates=gates))["action"], "WAIT_EXTERNAL")

    def test_no_required_gates_is_rejected(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(gates=[{"id":"opt","required":False,"status":"PASS"}]))["action"], "STOP_NOT_VERIFIED")

    def test_missing_reviewer_is_configuration_failure(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(reviewer_configured=False, reviewer_process_status="NOT_RUN", reviewer_verdict=None))["action"], "CONFIGURE_REVIEWER")

    def test_stale_review_cannot_pass(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(reviewed_fingerprint="c"*64))["action"], "REVIEW_REQUIRED")

    def test_review_of_wrong_contract_cannot_pass(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(reviewed_contract_hash="c"*64))["action"], "REVIEW_REQUIRED")

    def test_non_independent_review_cannot_pass(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(reviewer_independent=False))["action"], "STOP_NOT_VERIFIED")

    def test_reviewer_rework_retries(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(task_status="REWORK", reviewer_verdict="REWORK"))["action"], "RETRY_EXECUTOR")

    def test_reviewer_rework_at_cap_escalates(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(task_status="REWORK", reviewer_verdict="REWORK", attempt=3))["action"], "ESCALATE_RETRY_LIMIT")

    def test_reviewer_blocked_waits(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(task_status="BLOCKED", reviewer_verdict="BLOCKED"))["action"], "WAIT_EXTERNAL")

    def test_invalid_attempt_rejected(self):
        self.assertEqual(cp.decide_cycle(self.cycle_state(attempt=0))["action"], "INVALID_STATE")

    def work(self):
        return [
            {"id":"passed", "owner":"AUTONOMOUS","status":"PASS","evidence":["test.log"],"depends_on":[]},
            {"id":"gpu", "owner":"AUTONOMOUS","status":"BLOCKED_EXTERNAL","blocked_by":"GPU unavailable","depends_on":["passed"]},
            {"id":"neural", "owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":["gpu"]},
            {"id":"docs", "owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":["passed"]},
            {"id":"human", "owner":"HUMAN_PHYSICAL","status":"HUMAN_REQUIRED","depends_on":["docs"],
             "automation_blocker":"subjective perception", "procedure":"run a human playtest",
             "expected_return":"notes and build id", "pass_criteria":"the flow is usable"}
        ]

    def test_independent_work_continues_around_gpu_blocker(self):
        result = cp.decide_frontier(self.work())
        self.assertEqual(result["action"], "CONTINUE_FRONTIER")
        self.assertEqual([x["id"] for x in result["frontier"]["autonomous"]], ["docs"])

    def test_human_handoff_requires_two_clean_passes(self):
        work = self.work()
        work[3].update(status="PASS", evidence=["docs.log"])
        fp = cp.canonical_hash(work)
        result = cp.decide_frontier(work, clean_passes=2, state_fingerprint=fp, registry_fingerprint=fp)
        self.assertEqual(result["action"], "HUMAN_HANDOFF")

    def test_stale_human_discovery_pass_is_rejected(self):
        work = self.work()
        work[3].update(status="PASS", evidence=["docs.log"])
        fp = cp.canonical_hash(work)
        self.assertEqual(cp.decide_frontier(work, clean_passes=2, state_fingerprint="stale", registry_fingerprint=fp)["action"], "DISCOVERY_REQUIRED")

    def test_all_terminal_work_stops(self):
        work = [{"id":"done","owner":"AUTONOMOUS","status":"PASS","evidence":["test.log"],"depends_on":[]}]
        self.assertEqual(cp.decide_frontier(work)["action"], "STOP_COMPLETE")

    def test_dependency_cycle_invalid(self):
        work = [{"id":"a","owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":["b"]},
                {"id":"b","owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":["a"]}]
        self.assertEqual(cp.decide_frontier(work)["action"], "INVALID_STATE")

    def test_missing_gate_fingerprint_fails_closed(self):
        state = self.cycle_state(gate_source_fingerprint=None)
        self.assertEqual(cp.decide_cycle(state)["action"], "STOP_NOT_VERIFIED")

    def test_malformed_dependency_type_fails_closed(self):
        work = [{"id":"a","owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":None}]
        self.assertEqual(cp.decide_frontier(work)["action"], "INVALID_STATE")

    def test_human_task_requires_operational_handoff_fields(self):
        work = [{"id":"human","owner":"HUMAN_PHYSICAL","status":"HUMAN_REQUIRED","depends_on":[],
                 "automation_blocker":"subjective","procedure":"play test","expected_return":"notes","pass_criteria":"usable"}]
        self.assertEqual(cp.decide_frontier(work)["action"], "DISCOVERY_REQUIRED")
        del work[0]["procedure"]
        self.assertEqual(cp.decide_frontier(work)["action"], "INVALID_STATE")

    def test_not_applicable_dependency_is_terminal_only_with_reason(self):
        work = [{"id":"skip","owner":"AUTONOMOUS","status":"NOT_APPLICABLE","reason":"not needed","depends_on":[]},
                {"id":"next","owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":["skip"]}]
        result = cp.decide_frontier(work)
        self.assertEqual(result["action"], "CONTINUE_FRONTIER")
        self.assertEqual([x["id"] for x in result["frontier"]["autonomous"]], ["next"])

    def test_integration_requires_every_precondition(self):
        state = {k: True for k in ("contract_approved","scope_clean","review_pass","review_current",
                  "contract_current","required_gates_pass","requirements_pass","source_clean",
                  "frontier_complete","human_clear","external_clear")}
        self.assertEqual(cp.decide_integration(state)["action"], "READY_TO_MERGE")
        state["source_clean"] = False
        self.assertEqual(cp.decide_integration(state)["action"], "NOT_ELIGIBLE")

    def test_non_string_dependency_id_fails_closed(self):
        work = [{"id":"a","owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":[{"bad":"id"}]}]
        self.assertEqual(cp.decide_frontier(work)["action"], "INVALID_STATE")

    def test_priority_must_be_numeric(self):
        work = [{"id":"a","owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":[],"priority":"urgent"}]
        self.assertEqual(cp.decide_frontier(work)["action"], "INVALID_STATE")

    def test_invalid_clean_pass_count_fails_closed(self):
        work = [{"id":"a","owner":"AUTONOMOUS","status":"NOT_RUN","depends_on":[]}]
        self.assertEqual(cp.decide_frontier(work, clean_passes="2")["action"], "INVALID_STATE")

    def test_gate_id_and_required_flag_are_validated(self):
        state = self.cycle_state(gates=[{"status":"PASS","required":"yes"}])
        self.assertEqual(cp.decide_cycle(state)["action"], "INVALID_STATE")

    def test_decision_digest_detects_tampering(self):
        decision = cp.decide_integration({k: True for k in (
            "contract_approved","scope_clean","review_pass","review_current","contract_current",
            "required_gates_pass","requirements_pass","source_clean","frontier_complete",
            "human_clear","external_clear")})
        self.assertTrue(cp.verify_decision(decision))
        decision["action"] = "NOT_ELIGIBLE"
        self.assertFalse(cp.verify_decision(decision))

    def test_integration_fails_closed_on_missing_precondition(self):
        self.assertEqual(cp.decide_integration({})["action"], "INVALID_STATE")

    def test_release_decision_requires_observed_completion(self):
        state = {k: True for k in (
            "contract_approved","scope_clean","review_pass","review_current",
            "contract_current","required_gates_pass","requirements_pass","source_clean")}
        self.assertEqual(cp.decide_integration(state)["action"], "READY_TO_MERGE")
        state["scope"] = "release"
        self.assertEqual(cp.decide_integration(state)["action"], "INVALID_STATE")
        state.update(frontier_complete=False, human_clear=True, external_clear=True)
        self.assertEqual(cp.decide_integration(state)["action"], "NOT_ELIGIBLE")
        state["frontier_complete"] = True
        self.assertEqual(cp.decide_integration(state)["action"], "READY_TO_RELEASE")


if __name__ == "__main__":
    unittest.main()
