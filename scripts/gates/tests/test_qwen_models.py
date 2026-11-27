import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import check_qwen_models as gate  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[3]


class QwenModelsTests(unittest.TestCase):
    def test_t046zc_row58_only_the_five_models(self):
        """T-046zc F-18 §40 row 58: an old model or the Singapore host in app sources or eval scripts fails the gate."""
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "Packages" / "P" / "Sources").mkdir(parents=True)
            (root / "scripts" / "eval").mkdir(parents=True)
            ok = root / "Packages" / "P" / "Sources" / "Route.swift"
            ok.write_text('let a = ["qwen3.8-max-0902", "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "kimi-k3.1-pro", "qwen4-max"]\n',
                          encoding="utf-8")
            self.assertEqual(gate.main(root), 0)
            old = root / "scripts" / "eval" / "probe.py"
            old.write_text('M = "qwen3.8-flash"\nU = "https://dashscope-intl.aliyuncs.com"\nP = "qwen-plus"\n', encoding="utf-8")
            bad = gate.offenders(root)
            self.assertEqual(len(bad), 3, bad)
            self.assertTrue(any("qwen3.8-flash" in b for b in bad) and any("dashscope-intl" in b for b in bad))
            self.assertEqual(gate.main(root), 1)

    def test_t046zc_row58_repository_is_clean(self):
        """T-046zc F-18 §40 row 58: the repository itself passes."""
        self.assertEqual(gate.offenders(REPO), [])


if __name__ == "__main__":
    unittest.main()
