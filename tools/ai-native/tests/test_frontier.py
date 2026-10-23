import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import frontier


class FrontierTests(unittest.TestCase):
    def data(self):
        return {"schema_version":1,"work":[
            {"id":"unit", "owner":"AUTONOMOUS","status":"PASS","evidence":["ci:22"],
             "action":"run unit", "depends_on":[]},
            {"id":"gpu", "owner":"AUTONOMOUS","status":"BLOCKED_EXTERNAL","blocked_by":"GPU credentials",
             "action":"run GPU", "depends_on":["unit"]},
            {"id":"neural", "owner":"AUTONOMOUS","status":"NOT_RUN", "action":"run neural",
             "depends_on":["gpu"]},
            {"id":"docs", "owner":"AUTONOMOUS","status":"NOT_RUN", "action":"write docs",
             "depends_on":["unit"],"priority":1},
            {"id":"review", "owner":"HUMAN_PHYSICAL","status":"HUMAN_REQUIRED",
             "action":"try device", "depends_on":["docs"], "automation_blocker":"subjective_perception",
             "procedure":"test interaction", "expected_return":"recorded video", "pass_criteria":"usable"}
        ]}

    def test_dependency_block_only_narrows_frontier(self):
        outcome = frontier.frontier(self.data())
        self.assertEqual([t["id"] for t in outcome["autonomous"]], ["docs"])
        self.assertEqual(set(t["id"] for t in outcome["blocked"]), {"gpu","neural"})

    def test_human_is_queued_not_global_blocker(self):
        outcome = frontier.frontier(self.data())
        self.assertEqual(len(outcome["human"]), 1)
        self.assertEqual(outcome["AUTONOMOUS_ACTION_AVAILABLE"], "YES")

    def test_pass_must_have_evidence(self):
        data = self.data()
        del data["work"][0]["evidence"]
        self.assertTrue(any("PASS without evidence" in p for p in frontier.check(data)))

    def test_cycle_detected(self):
        data = self.data()
        data["work"][0]["depends_on"] = ["docs"]
        self.assertTrue(any("cycle" in p for p in frontier.check(data)))

    def test_two_clean_independent_reviews_required(self):
        data = self.data()
        for w in data["work"]:
            if w["id"] == "docs":
                w.update(status="PASS", evidence=["log:docs-pass"])
        s0 = frontier.clean_pass(data, {}, True)
        self.assertEqual(s0["clean_passes"], 1)
        self.assertTrue(frontier.readiness(data, s0))
        s1 = frontier.clean_pass(data, s0, True)
        self.assertFalse(frontier.readiness(data, s1))

    def test_registry_change_invalidates_clean_passes(self):
        data = self.data()
        state = {"fingerprint":frontier.fingerprint(data),"clean_passes":2}
        data["work"][3]["priority"] = 9
        self.assertEqual(frontier.clean_pass(data, state, True)["clean_passes"], 0)

    def test_human_decision_quantification_required(self):
        data = self.data()
        data["work"][4]["owner"] = "HUMAN_DECISION"
        self.assertTrue(any("quantified" in p for p in frontier.check(data)))


if __name__ == "__main__":
    unittest.main()
