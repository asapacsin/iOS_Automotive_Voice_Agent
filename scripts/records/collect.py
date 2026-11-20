#!/usr/bin/env python3
"""F-12 §21 item 5 (T-031u): archive conversation records on the PC by build and format.

    collect.py --from <folder>      read records exported from the app (Files app) or pulled earlier
    collect.py                      pull Documents/conversations from the phone on USB (pymobiledevice3)

Each record is copied unchanged to <archive>\\<commit>\\<file name> and gets one row in <archive>\\index.csv
(file, sha256, commit, app version, recordFormat, start time, line count, dropped, reader). A file whose sha256 is
already in the index is skipped. A format with no reader in read.py is archived with reader=none and the run ends
with "unknown recordFormat <n> in <commit>". No network call; nothing leaves the PC.
"""
import argparse
import csv
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import read as reader  # noqa: E402

BUNDLE = "XTL-Y6YT9YM42U.com.asapacsin.novadrive"
DEFAULT_ARCHIVE = r"D:\ndrecords"
DEFAULT_PMD3 = r"C:\Users\Administrator\AppData\Local\novadrive-tools\venv312\Scripts\pymobiledevice3.exe"
INDEX_FIELDS = ["file", "sha256", "commit", "app_version", "recordFormat", "start", "lines", "dropped", "reader",
                "agentVersion", "agentHash", "model"]
NAME = re.compile(r"^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.txt$")


def facts(path: pathlib.Path) -> dict:
    data = path.read_bytes()
    lines = data.decode("utf-8", errors="replace").splitlines()
    try:
        fmt = reader.record_format(lines)
    except reader.UnknownFormat as e:
        fmt = e.format
    app = next((line for line in lines[:3] if line.startswith("app ")), "")
    parts = app.split()
    version = parts[1] if len(parts) > 1 else ""
    commit = parts[2] if len(parts) > 2 else "unknown"
    m = NAME.match(path.name)
    start = f"{m[1]}-{m[2]}-{m[3]} {m[4]}:{m[5]}:{m[6]}" if m else ""
    dropped = sum(int(line.split("=", 1)[1]) for line in lines if re.fullmatch(r"dropped=\d+", line))
    return {"file": path.name, "sha256": hashlib.sha256(data).hexdigest(), "commit": commit, "app_version": version,
            "recordFormat": fmt, "start": start, "lines": len(lines), "dropped": dropped,
            "reader": f"format{fmt}" if fmt in reader.READERS else "none",
            **{k: v for k, v in reader.agent_fields(lines).items() if k != "setup"}}


def collect(source: pathlib.Path, archive: pathlib.Path) -> tuple[list[dict], list[str]]:
    """Archives every *.txt in `source`; returns the new index rows and the unknown-format messages."""
    archive.mkdir(parents=True, exist_ok=True)
    index = archive / "index.csv"
    known = set()
    if index.exists():
        with index.open(encoding="utf-8", newline="") as f:
            known = {row["sha256"] for row in csv.DictReader(f)}
    added, unknown = [], []
    for path in sorted(source.glob("*.txt")):
        row = facts(path)
        if row["sha256"] in known:
            continue
        known.add(row["sha256"])
        dest = archive / row["commit"] / path.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
        added.append(row)
        if row["reader"] == "none":
            unknown.append(f"unknown recordFormat {row['recordFormat']} in {row['commit']}")
    new_file = not index.exists()
    with index.open("a", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=INDEX_FIELDS)
        if new_file:
            w.writeheader()
        w.writerows(added)
    return added, unknown


def pull(pmd3: str, dest: pathlib.Path) -> bool:
    """Pulls Documents/conversations from the app's container (verified 2026-11-20, pymobiledevice3 `apps pull`;
    the remote path needs the leading slash). When it fails, export the folder through the Files app and use --from."""
    cmd = [pmd3, "apps", "pull", "--documents", BUNDLE, "/Documents/conversations", str(dest / "conversations")]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"cannot read the app container ({type(e).__name__}); export the folder and use --from", file=sys.stderr)
        return False
    if r.returncode != 0:
        print("cannot read the app container (pymobiledevice3 exit "
              f"{r.returncode}); export the folder and use --from", file=sys.stderr)
        return False
    return True


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--from", dest="source", help="a folder of exported records")
    p.add_argument("--archive", default=DEFAULT_ARCHIVE)
    p.add_argument("--pmd3", default=DEFAULT_PMD3)
    a = p.parse_args(argv)
    archive = pathlib.Path(a.archive)
    if a.source:
        added, unknown = collect(pathlib.Path(a.source), archive)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            if not pull(a.pmd3, pathlib.Path(tmp)):
                return 2
            found = next((d for d in [pathlib.Path(tmp), *pathlib.Path(tmp).rglob("*")] if d.is_dir()
                          and any(d.glob("*.txt"))), pathlib.Path(tmp))
            added, unknown = collect(found, archive)
    print(f"archived {len(added)} new record(s) into {archive}")
    for line in unknown:
        print(line)
    return 1 if unknown else 0


if __name__ == "__main__":
    sys.exit(main())
