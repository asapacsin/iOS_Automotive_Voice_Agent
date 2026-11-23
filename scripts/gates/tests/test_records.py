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

    def test_fixtures_match_the_swift_fixtures(self):
        swift = sorted((ROOT / "Packages/NovaCore/Tests/NovaAgentTests/Fixtures").glob("record-format-*.txt"))
        self.assertGreaterEqual(len(swift), 2)
        for f in swift:
            self.assertEqual((FIX / f.name).read_bytes(), f.read_bytes(), f.name)
            n = int(f.stem.rsplit("-", 1)[1])
            self.assertIn(n, read.READERS, f"read.py has no reader for format {n}")

    def test_t046w_row22_format5_bodies_unescape_exactly(self):
        """T-046w F-18 §34 row 22 (format 5): read.py gives the search bodies of the fixture back exactly."""
        rows = read.read(FIX / "record-format-5.txt")
        req = next(r for r in rows if r["kind"] == "search-request")
        res = next(r for r in rows if r["kind"] == "search-response")
        self.assertEqual(read.body(req), '{"input":{"messages":[{"content":"第一行\\n第二行"}]},"system":"规则一\n规则二"}')
        self.assertEqual(read.body(res), 'id:1\nevent:result\n:HTTP_STATUS/200\ndata:{"text":"七块\tC:\\\\path"}\n\nid:2\r\ndata:{}\n\n')
        self.assertEqual({r["legacy"] for r in rows}, {"false"})
        self.assertEqual(read.unescape_body("a\\\\nb\\nc\\td\\re"), "a\\nb\nc\td\re")
        # Every line after the header starts with its time (F-18 §34 row 23's check, on the fixture).
        lines = (FIX / "record-format-5.txt").read_bytes().decode("utf-8").split("\n")[:-1]
        events = [l for l in lines if l[:1].isdigit()]
        self.assertEqual(len(events), len(rows))
        self.assertNotIn("\r", "".join(lines))

    def test_t046w_row22_format4_multiline_search_body_is_one_legacy_row(self):
        """T-046w F-18 §34 row 22 (format 4): a raw search body over many lines is one search-response row, legacy=true."""
        body = "id:1\nevent:result\n:HTTP_STATUS/200\ndata:{\"a\":1}\n\nid:2\ndata:{}"
        text = ("recordFormat 4\napp 0.1.0(1) abcdef0\n100 search-request attempt=1 body={}\n"
                f"200 search-response attempt=1 status=200 body={body}\n300 search-result ok ms=1\n")
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d) / "20261123-101517.txt"
            f.write_text(text, encoding="utf-8")
            rows = read.read(f)
        self.assertEqual([r["kind"] for r in rows], ["search-request", "search-response", "search-result"])
        res = rows[1]
        self.assertEqual(read.body(res), body)
        self.assertEqual(res["legacy"], "true")
        self.assertEqual({rows[0]["legacy"], rows[2]["legacy"]}, {"false"})

    def test_t031y_row7_agent_fields_index_and_unregistered(self):
        """T-031y F-09b §15 row 7: rows carry agentVersion/agentHash/model; index has the columns; unknown hash flagged."""
        import json
        rows = read.read(FIX / "record-format-2.txt")
        self.assertEqual({(r["agentVersion"], r["agentHash"], r["model"]) for r in rows},
                         {("1.0.0", "0123456789ab", "gemini-3.8-live")})
        self.assertEqual({r["setup"] for r in rows}, {"unregistered"})
        real = json.loads((ROOT / "specs/contracts/agent-setup-parts/1.0.0.json").read_text(encoding="utf-8"))["sessions"]
        text = (FIX / "record-format-2.txt").read_text(encoding="utf-8").replace("0123456789ab", next(iter(real.values())))
        with tempfile.TemporaryDirectory() as tmp:
            src, arc = pathlib.Path(tmp) / "src", pathlib.Path(tmp) / "arc"
            src.mkdir()
            (src / "20261120-110000.txt").write_text(text, encoding="utf-8")
            self.assertEqual({r["setup"] for r in read.read(src / "20261120-110000.txt")}, {"registered"})
            with contextlib.redirect_stdout(io.StringIO()):
                collect.main(["--from", str(src), "--archive", str(arc)])
            with (arc / "index.csv").open(encoding="utf-8", newline="") as f:
                row = next(csv.DictReader(f))
            self.assertEqual((row["agentVersion"], row["model"], row["recordFormat"]), ("1.0.0", "gemini-3.8-live", "2"))
        # Older formats carry empty agent fields.
        self.assertEqual({r["agentVersion"] for r in read.read(FIX / "record-format-1.txt")}, {""})


    def test_t031u_row5_format_without_notes_row_fails(self):
        """T-031u F-12 §21 row 5: formatVersion n+1 with no row in record-format.md fails check_record_format."""
        import re
        sys.path.insert(0, str(ROOT / "scripts" / "gates"))
        import check_record_format as gate
        n = int(re.search(r"static let formatVersion = (\d+)", (ROOT / gate.SOURCE).read_text(encoding="utf-8"))[1])
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            files = [gate.SOURCE, gate.NOTES] + [f"{gate.FIXTURES}/record-format-{k}.txt" for k in range(1, n + 2)]
            for rel in files:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text((ROOT / rel).read_text(encoding="utf-8") if (ROOT / rel).exists() else "x",
                                        encoding="utf-8")
            self.assertEqual(gate.problems(root), [])
            src = root / gate.SOURCE
            src.write_text(src.read_text(encoding="utf-8").replace(f"formatVersion = {n}", f"formatVersion = {n + 1}"),
                           encoding="utf-8")
            self.assertEqual(gate.problems(root), [f"{gate.NOTES}: format {n + 1} has no row"])
        self.assertEqual(gate.problems(), [])


if __name__ == "__main__":
    unittest.main()
