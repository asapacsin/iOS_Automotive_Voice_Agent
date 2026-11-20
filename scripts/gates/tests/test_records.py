import contextlib
import csv
import io
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "records"))
import collect  # noqa: E402
import read  # noqa: E402

FIX = ROOT / "scripts" / "fixtures" / "records"


class RecordScriptsTests(unittest.TestCase):
    def test_t031u_row6_collect_archives_indexes_skips_and_reports(self):
        """T-031u F-12 §21 row 6: 3 files archived under their commits, copy skipped, format 9 reader=none."""
        with tempfile.TemporaryDirectory() as tmp:
            src, arc = pathlib.Path(tmp) / "src", pathlib.Path(tmp) / "arc"
            src.mkdir()
            one = (FIX / "record-format-1.txt").read_text(encoding="utf-8")
            (src / "20261120-080000.txt").write_text((FIX / "record-format-0.txt").read_text(encoding="utf-8"),
                                                     encoding="utf-8")
            (src / "20261120-090000.txt").write_text(one, encoding="utf-8")
            (src / "20261120-090500.txt").write_text(one, encoding="utf-8")  # a copy
            (src / "20261120-100000.txt").write_text("recordFormat 9\napp 0.1.0(1) 1234567\n0 x y\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = collect.main(["--from", str(src), "--archive", str(arc)])
            self.assertEqual(code, 1)
            self.assertIn("unknown recordFormat 9 in 1234567", out.getvalue())
            with (arc / "index.csv").open(encoding="utf-8", newline="") as f:
                rows = list(csv.DictReader(f))
            self.assertEqual(len(rows), 3)
            self.assertEqual({r["reader"] for r in rows}, {"format0", "format1", "none"})
            self.assertTrue((arc / "abcdef0" / "20261120-090000.txt").read_text(encoding="utf-8") == one)
            self.assertTrue((arc / "1234567" / "20261120-100000.txt").exists())
            self.assertEqual(rows[0]["start"], "2026-11-20 08:00:00")
            # Pulling twice adds nothing.
            with contextlib.redirect_stdout(io.StringIO()):
                collect.main(["--from", str(src), "--archive", str(arc)])
            with (arc / "index.csv").open(encoding="utf-8", newline="") as f:
                self.assertEqual(len(list(csv.DictReader(f))), 3)

    def test_t031u_row7_readers_same_shape_legacy_marked(self):
        """T-031u F-12 §21 row 7: format 0 and 1 give the same rows; format-0 rows legacy=true."""
        zero = read.read(FIX / "record-format-0.txt")
        one = read.read(FIX / "record-format-1.txt")
        self.assertTrue(one)
        self.assertEqual([{k: v for k, v in r.items() if k not in ("legacy", "session")} for r in zero],
                         [{k: v for k, v in r.items() if k not in ("legacy", "session")} for r in one])
        self.assertEqual({r["legacy"] for r in zero}, {"true"})
        self.assertEqual({r["legacy"] for r in one}, {"false"})
        self.assertEqual(set(one[0].keys()), set(read.FIELDS))
        with tempfile.TemporaryDirectory() as tmp:
            bad = pathlib.Path(tmp) / "x.txt"
            bad.write_text("recordFormat 9\n", encoding="utf-8")
            with self.assertRaises(read.UnknownFormat):
                read.read(bad)

    def test_fixtures_match_the_swift_fixture(self):
        swift = ROOT / "Packages/NovaCore/Tests/NovaAgentTests/Fixtures/record-format-1.txt"
        self.assertEqual((FIX / "record-format-1.txt").read_bytes(), swift.read_bytes())


    def test_t031u_row5_format_without_notes_row_fails(self):
        """T-031u F-12 §21 row 5: formatVersion 2 with no row in record-format.md fails check_record_format."""
        sys.path.insert(0, str(ROOT / "scripts" / "gates"))
        import check_record_format as gate
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for rel in (gate.SOURCE, gate.NOTES, gate.FIXTURES + "/record-format-1.txt", gate.FIXTURES + "/record-format-2.txt"):
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text((ROOT / rel).read_text(encoding="utf-8") if (ROOT / rel).exists() else "x",
                                        encoding="utf-8")
            self.assertEqual(gate.problems(root), [])
            src = root / gate.SOURCE
            src.write_text(src.read_text(encoding="utf-8").replace("formatVersion = 1", "formatVersion = 2"), encoding="utf-8")
            self.assertEqual(gate.problems(root), [f"{gate.NOTES}: format 2 has no row"])
        self.assertEqual(gate.problems(), [])


if __name__ == "__main__":
    unittest.main()
