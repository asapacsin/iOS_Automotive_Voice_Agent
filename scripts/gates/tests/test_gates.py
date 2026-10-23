"""Self-tests for the static gates: each planted bypass from the T-000 reviews must fail its gate.

Run: python3 -m unittest discover -s scripts/gates/tests   (scripts/gates/run_all.sh does this)
Fake key material is assembled at runtime so this file holds no key-shaped literal.
"""
import contextlib
import io
import pathlib
import shutil
import sys
import tempfile
import unittest

GATES = pathlib.Path(__file__).resolve().parents[1]
REPO = GATES.parents[1]
sys.path.insert(0, str(GATES))

import check_imports  # noqa: E402
import check_secrets  # noqa: E402
import spec_trace  # noqa: E402

FAKE = "Q7" + "x9Lm2" * 5          # 27 chars, mixed case + digits: looks like a key, is not one
FAKE_GOOGLE = "AIza" + "B" * 35


class Tree:
    """A scratch repo root with the files a gate needs."""

    def __init__(self) -> None:
        self.root = pathlib.Path(tempfile.mkdtemp())
        services = REPO / "Packages/NovaCore/Sources/NovaPorts/Services.swift"
        self.write("Packages/NovaCore/Sources/NovaPorts/Services.swift", services.read_text(encoding="utf-8"))

    def write(self, rel: str, text: str) -> pathlib.Path:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def close(self) -> None:
        shutil.rmtree(self.root)


def run(main, *argv) -> int:
    with contextlib.redirect_stdout(io.StringIO()):
        return main(list(argv))


class SecretsGateTests(unittest.TestCase):
    PLANTED = {
        "App/Config.swift": f'let geminiApiKey: String = "{FAKE}"',
        "App/Config2.swift": f'static let amap_web_key: String? = "{FAKE}"',
        "App/Raw.swift": f'let qianfanKey = #"{FAKE}"#',
        ".env": f"AZURE_SPEECH_KEY={FAKE}",
        ".env.local": f"export GEMINI_API_KEY={FAKE}  # local only",
        "App/App.xcodeproj/project.pbxproj": f'AMAP_SDK_KEY = "{FAKE}";',
        "App/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme":
            f'<EnvironmentVariable\n   key = "GEMINI_API_KEY"\n   value = "{FAKE}"\n   isEnabled = "YES">',
        ".github/workflows/x.yml": f"env:\n  AMAP_WEB_KEY: {FAKE}\n",
        "App/Secrets.xcconfig": f"AMAP_SDK_KEY[sdk=iphoneos*] = {FAKE} // device",
        "App/Other.xcconfig": f"IFLYTEK_APP_ID = {FAKE}",
        "fixtures/capture.har": '{"headers": [{"name": "x-goog-api-key", "value": "' + FAKE + '"}]}',
        "fixtures/capture2.har": '{"headers": [{"value": "Bearer ' + FAKE + '", "name": "Authorization"}]}',
        "fixtures/url.jsonl": '{"url": "wss://host/ws?key=' + FAKE + '"}',
        "App/Google.swift": f'let k = "{FAKE_GOOGLE}"',
        "App/Info.plist": f"<key>AzureSpeechKey</key>\n<string>{FAKE}</string>",
    }
    CLEAN = {
        "App/Keys.swift": 'enum K: String { case amapWebKey = "amap_web_key"; case gemini = "GEMINI_API_KEY_MISSING" }',
        "App/Ref.xcconfig": "AMAP_SDK_KEY = $(AMAP_SDK_KEY)",
        ".github/workflows/ok.yml": "env:\n  GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}\n",
        "App/Short.swift": 'let token = "abc"',
    }

    def test_each_planted_secret_fails(self) -> None:
        for rel, text in self.PLANTED.items():
            with self.subTest(rel=rel):
                tree = Tree()
                try:
                    tree.write(rel, text)
                    self.assertEqual(run(check_secrets.main, str(tree.root)), 1, rel)
                finally:
                    tree.close()

    def test_clean_references_pass(self) -> None:
        tree = Tree()
        try:
            for rel, text in self.CLEAN.items():
                tree.write(rel, text)
            self.assertEqual(check_secrets.scan(tree.root), [])
        finally:
            tree.close()

    def test_credential_key_names_are_scanned(self) -> None:
        self.assertIn("qianfan_key", check_secrets.NAME)
        self.assertIn("iflytek_app_id", check_secrets.NAME)

    def test_repository_is_clean(self) -> None:
        self.assertEqual(check_secrets.scan(REPO), [])


class ImportsGateTests(unittest.TestCase):
    PLANTED = {
        "access level": "public import UIKit",
        "backticks": "import `UIKit`",
        "attribute and access level": "@preconcurrency internal import AVFoundation",
        "after a URL string": 'let u = "https://example.com"; import UIKit',
        "after a string with a comment opener": 'let s = "/*"\nimport UIKit\nlet t = "*/"',
        "websocket factory call": "let t = session.webSocketTask(with: url)",
        "websocket type": "var t: URLSessionWebSocketTask?",
        "spi": "@_spi(Private) import UIKit",
    }
    CLEAN = {
        "import in a comment": "// import UIKit",
        "import in a nested block comment": "/* outer /* inner */ import UIKit */",
        "import in a string": 'let s = "import UIKit"',
        "import in a multiline string": 'let s = """\nimport UIKit\n"""',
        "import in a raw string": 'let s = #"import "UIKit" "#',
        "allowed": "public import Foundation\nimport NovaKit",
    }

    def check(self, code: str) -> int:
        tree = Tree()
        try:
            tree.write("Packages/NovaCore/Sources/NovaVoice/X.swift", code)
            return run(check_imports.main, str(tree.root))
        finally:
            tree.close()

    def test_each_bypass_fails(self) -> None:
        for name, code in self.PLANTED.items():
            with self.subTest(name=name):
                self.assertEqual(self.check(code), 1, name)

    def test_comments_and_strings_pass(self) -> None:
        for name, code in self.CLEAN.items():
            with self.subTest(name=name):
                self.assertEqual(self.check(code), 0, name)


class SpecTraceGateTests(unittest.TestCase):
    def check(self, test_source: str, *ids: str) -> int:
        tree = Tree()
        try:
            tree.write("Packages/NovaCore/Tests/XTests/X.swift", test_source)
            return run(spec_trace.main, "--root", str(tree.root), *ids)
        finally:
            tree.close()

    def test_enabled_test_counts(self) -> None:
        self.assertEqual(self.check('@Test("F-04 gate opens") func a() {}', "F-04"), 0)
        self.assertEqual(self.check('@Test("F-04 x", .tags(.gate)) func a() {}', "F-04"), 0)

    def test_whole_tokens_only(self) -> None:
        self.assertEqual(self.check('@Test("F-10 x") func a() {}', "F-1"), 1)

    def test_commented_out_test_does_not_count(self) -> None:
        self.assertEqual(self.check('// @Test("F-04 gate opens") func a() {}', "F-04"), 1)
        self.assertEqual(self.check('/* @Test("F-04 gate opens") */ func a() {}', "F-04"), 1)

    def test_test_in_string_does_not_count(self) -> None:
        self.assertEqual(self.check('let s = """\n@Test("F-04 x")\n"""', "F-04"), 1)

    def test_disabled_test_does_not_count(self) -> None:
        self.assertEqual(self.check('@Test("F-04 x", .disabled()) func a() {}', "F-04"), 1)
        self.assertEqual(self.check('@Test("F-04 x", .disabled("flaky")) func a() {}', "F-04"), 1)


if __name__ == "__main__":
    unittest.main()
