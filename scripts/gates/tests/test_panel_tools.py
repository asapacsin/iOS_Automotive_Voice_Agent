"""F-09b §17 row 9 (T-031zb): a panel with no registry entry, or a layered entry with no close tool, fails the gate."""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import check_panel_tools as gate  # noqa: E402

REG = "Packages/NovaCore/Sources/NovaKit/ScreenState.swift"
VIEW = "App/NovaDrive/DriveView.swift"


class PanelToolsGateTests(unittest.TestCase):
    def rig(self, tmp, files):
        root = pathlib.Path(tmp)
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text, encoding="utf-8")
        return gate.problems(root)

    def test_repository_passes(self):
        self.assertEqual(gate.problems(), [])

    def test_t031zb_row9_panel_without_entry_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            issues = self.rig(tmp, {
                REG: '        .camera: PanelEntry(layer: 2, opens: [], close: "exit_navigation_mode", acts: []),\n',
                VIEW: "Text(\"x\").screenPanel(.camera)\nText(\"y\").screenPanel(.radio)\n"})
            self.assertEqual(len(issues), 1)
            self.assertIn(".screenPanel(.radio)", issues[0])

    def test_t031zb_row9_layer_without_close_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            issues = self.rig(tmp, {
                REG: '        .camera: PanelEntry(layer: 2, opens: [], close: nil, acts: []),\n'
                     '        .working: PanelEntry(layer: nil, opens: [], close: nil, acts: []),\n',
                VIEW: "Text(\"x\").screenPanel(.camera).screenPanel(.working)\n"})
            self.assertEqual(issues, [f"{REG}: .camera has layer 2 and no close tool"])


if __name__ == "__main__":
    unittest.main()
