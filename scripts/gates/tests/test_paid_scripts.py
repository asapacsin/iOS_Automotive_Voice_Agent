import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import check_paid_scripts as gate  # noqa: E402


class PaidScriptsTests(unittest.TestCase):
    def test_t046u_row10_paid_host_without_max_calls_fails(self):
        """T-046u F-18 §32 row 10: a script naming a paid host without --max-calls fails the gate."""
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "scripts" / "x").mkdir(parents=True)
            bad = root / "scripts" / "x" / "probe.py"
            bad.write_text('URL = "https://dashscope-intl.aliyuncs.com/api/v1"\n', encoding="utf-8")
            (root / "scripts" / "x" / "ok.py").write_text('URL = "https://generativelanguage.googleapis.com"\n'
                                                         'p.add_argument("--max-calls")\n', encoding="utf-8")
            (root / "scripts" / "x" / "free.py").write_text('print("no host")\n', encoding="utf-8")
            self.assertEqual(gate.offenders(root), ["scripts/x/probe.py"])
            self.assertEqual(gate.main(root), 1)
            bad.unlink()
            self.assertEqual(gate.main(root), 0)

    def test_repository_passes(self):
        self.assertEqual(gate.offenders(pathlib.Path(__file__).resolve().parents[3]), [])


if __name__ == "__main__":
    unittest.main()
