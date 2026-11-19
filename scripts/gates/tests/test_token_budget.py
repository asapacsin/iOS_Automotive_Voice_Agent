"""specs/token-budget.md §4 rows 1-4 (T-900a, T-900b)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SECTION = ROOT / "scripts" / "spec_section.py"
GUARD = ROOT / "scripts" / "hooks" / "read_guard.py"
TRIP = ROOT / "specs" / "features" / "trip-plan.md"


def run(cmd, stdin=None, env=None):
    base = {k: v for k, v in os.environ.items() if k != "NOVA_READ_GUARD_KB"}
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, env={**base, **(env or {})})


def guard(event, env=None):
    out = run([sys.executable, str(GUARD)], stdin=event if isinstance(event, str) else json.dumps(event), env=env)
    return out.returncode, out.stdout.strip()


class SpecSectionTests(unittest.TestCase):
    def test_row1_list_one_section_subsection_and_unknown(self):
        listing = run([sys.executable, str(SECTION), "trip-plan"])
        self.assertEqual(listing.returncode, 0)
        self.assertIn("51. Plain navigation", listing.stdout)
        s51 = run([sys.executable, str(SECTION), "trip-plan", "51"]).stdout
        self.assertTrue(s51.splitlines()[1].startswith("## 51. "))
        self.assertNotIn("\n## 50. ", s51)
        self.assertNotIn("\n## 52. ", s51)
        self.assertLess(len(s51.encode()), TRIP.stat().st_size / 4)
        s52 = run([sys.executable, str(SECTION), "trip-plan", "§5.2"]).stdout
        self.assertTrue(s52.splitlines()[1].startswith("### 5.2 "))
        self.assertNotIn("### 5.3 ", s52)
        bad = run([sys.executable, str(SECTION), "trip-plan", "999"])
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("trip-plan", bad.stderr)


class ReadGuardTests(unittest.TestCase):
    def test_row2_whole_large_spec_denied(self):
        code, out = guard({"tool_name": "Read", "tool_input": {"file_path": str(TRIP)}})
        self.assertEqual(code, 0)
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("Grep", decision["permissionDecisionReason"])
        self.assertIn("scripts/spec_section.py", decision["permissionDecisionReason"])

    def test_row3_allowed_cases(self):
        with tempfile.TemporaryDirectory() as d:
            small = Path(d) / "small.md"
            small.write_text("x" * 2048)
            png = Path(d) / "big.png"
            png.write_bytes(b"\0" * 50_000)
            for event in ({"tool_name": "Read", "tool_input": {"file_path": str(TRIP), "offset": 1693, "limit": 180}},
                          {"tool_name": "Read", "tool_input": {"file_path": str(TRIP), "limit": 50}},
                          {"tool_name": "Read", "tool_input": {"file_path": str(small)}},
                          {"tool_name": "Read", "tool_input": {"file_path": str(Path(d) / "missing.md")}},
                          {"tool_name": "Read", "tool_input": {"file_path": str(png)}},
                          {"tool_name": "Grep", "tool_input": {"pattern": "x"}}):
                self.assertEqual(guard(event), (0, ""), event)
        self.assertEqual(guard("not json"), (0, ""))

    def test_relative_path_uses_event_cwd(self):
        event = {"tool_name": "Read", "cwd": str(ROOT), "tool_input": {"file_path": "specs/features/trip-plan.md"}}
        code, out = guard(event)
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_row4_limit_zero_turns_it_off(self):
        event = {"tool_name": "Read", "tool_input": {"file_path": str(TRIP)}}
        self.assertEqual(guard(event, env={"NOVA_READ_GUARD_KB": "0"}), (0, ""))

    def test_hook_registered_for_read(self):
        settings = json.loads((ROOT / ".claude" / "settings.json").read_text())
        entries = [e for e in settings["hooks"]["PreToolUse"] if e.get("matcher") == "Read"]
        self.assertTrue(any("scripts/hooks/read_guard.py" in h["command"] for e in entries for h in e["hooks"]))


if __name__ == "__main__":
    unittest.main()
