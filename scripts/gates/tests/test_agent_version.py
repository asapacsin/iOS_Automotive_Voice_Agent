import json
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "gates"))
import check_agent_version as gate  # noqa: E402


class AgentVersionGateTests(unittest.TestCase):
    def rig(self, tmp, change, version, note="n"):
        root = pathlib.Path(tmp)
        (root / gate.PARTS).mkdir(parents=True)
        base = json.loads((ROOT / gate.PARTS / "1.0.0.json").read_text(encoding="utf-8"))
        (root / gate.PARTS / "1.0.0.json").write_text(json.dumps(base), encoding="utf-8")
        new = json.loads(json.dumps(base))
        change(new["parts"])
        new["setupHash"] = "ffffffffffff"
        (root / gate.PARTS / f"{version}.json").write_text(json.dumps(new), encoding="utf-8")
        reg = (ROOT / gate.REGISTRY).read_text(encoding="utf-8")
        reg = reg.replace("|---|---|---|---|---|---|\n",
                          f"|---|---|---|---|---|---|\n| {version} | ffffffffffff | 2026-11-21 | x | {note} | F-09b §15 |\n")
        (root / gate.REGISTRY).write_text(reg, encoding="utf-8")
        return gate.problems(root)

    def test_repository_passes(self):
        self.assertEqual(gate.problems(), [])

    def test_t031y_row4_tool_added_with_minor_row_fails(self):
        """T-031y F-09b §15 row 4: a tool added with only a minor row fails (major required)."""
        def add(p):
            p["tool.nosearch.fake_tool.description"] = "x"
            p["tool.nosearch.fake_tool.schema"] = "{}"
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.rig(tmp, add, "1.1.0"),
                             ["1.1.0: the change needs a major bump, row is minor (F-09b §15 item 4)"])
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.rig(tmp, add, "2.0.0"), [])

    def test_t031y_row3_one_description_char_minor_passes(self):
        """T-031y F-09b §15 row 3: one character in a tool description with a minor row passes."""
        def edit(p):
            k = next(n for n in sorted(p) if n.endswith(".description"))
            p[k] += "。"
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.rig(tmp, edit, "1.1.0"), [])
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.rig(tmp, edit, "1.0.1"),
                             ["1.0.1: the change needs a minor bump, row is patch (F-09b §15 item 4)"])

    def test_t031y_row5_tuning_change_patch_passes(self):
        """T-031y F-09b §15 row 5: a marked Tuning value changed with a patch row passes."""
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.rig(tmp, lambda p: p.__setitem__("tuning.offerOpenSeconds", "30"), "1.0.1"), [])

    def test_base_part_rewritten_is_major_and_missing_note_fails(self):
        def rewrite(p):
            for k in [n for n in p if n.startswith("base.")]:
                p[k] = p[k].replace(p[k][p[k].index("【安全】"):], "【安全】完全不同的一段新文字。")
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIn("1.1.0: the change needs a major bump, row is minor (F-09b §15 item 4)", self.rig(tmp, rewrite, "1.1.0"))
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIn("1.0.1: a row needs a note and a spec section",
                          self.rig(tmp, lambda p: p.__setitem__("tuning.x", "1"), "1.0.1", note=""))

    def test_nested_parameter_added_is_major(self):
        import json as j
        def nest(p):
            k = next(n for n in sorted(p) if n.endswith(".schema"))
            schema = j.loads(p[k])
            schema.setdefault("properties", {})["options"] = {"type": "array", "items": {"type": "object", "properties": {}}}
            p[k] = j.dumps(schema)
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.rig(tmp, nest, "2.0.0"), [])
        self.assertEqual(gate.params('{"properties":{"o":{"type":"array","items":{"properties":{"action":{}}}}}}'),
                         {"o", "o[].action"})


if __name__ == "__main__":
    unittest.main()
