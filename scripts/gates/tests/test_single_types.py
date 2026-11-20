"""F-09b §16 row 6 (T-031z): a second NavigationPhase definition fails the gate."""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import check_single_types as gate  # noqa: E402

HOME = "Packages/NovaCore/Sources/NovaKit/States.swift"


class SingleTypesGateTests(unittest.TestCase):
    def rig(self, tmp, files):
        root = pathlib.Path(tmp)
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text, encoding="utf-8")
        return gate.problems(root)

    def test_repository_passes(self):
        self.assertEqual(gate.problems(), [])

    def test_t031z_row6_second_definition_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            issues = self.rig(tmp, {HOME: "public enum NavigationPhase { case idle }\n",
                                    "Packages/NovaCore/Sources/NovaNav/X.swift": "public enum NavigationPhase: String { case idle }\n"})
            self.assertEqual(len(issues), 1)
            self.assertIn("NovaNav/X.swift", issues[0])

    def test_one_definition_and_uses_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.rig(tmp, {HOME: "public enum NavigationPhase { case idle }\n",
                                            "App/A.swift": "let p: NavigationPhase = .idle // enum NavigationPhase\n"}), [])


if __name__ == "__main__":
    unittest.main()
