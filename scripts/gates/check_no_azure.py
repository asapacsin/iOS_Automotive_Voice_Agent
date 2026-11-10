#!/usr/bin/env python3
"""F-07 §17 item 6 (T-020d): Azure is removed from the iOS app.

Fails if "azure" (any case) appears in any file under App/ or Packages/. The secrets-gate fixtures in
scripts/gates/tests keep Azure key names as sample names; they are outside both trees.
"""
import argparse
import pathlib
import sys

TREES = ("App", "Packages")
SKIP_DIRS = {".build", ".swiftpm", "DerivedData"}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[2]))
    root = pathlib.Path(parser.parse_args(argv).root)
    bad = []
    for tree in TREES:
        for path in sorted((root / tree).rglob("*")):
            if not path.is_file() or SKIP_DIRS.intersection(path.relative_to(root).parts):
                continue
            rel = path.relative_to(root)
            if "azure" in str(rel).lower():
                bad.append(f"{rel}: file name names Azure")
                continue
            data = path.read_bytes().lower()
            if b"azure" not in data:
                continue
            for n, line in enumerate(data.splitlines(), 1):
                if b"azure" in line:
                    bad.append(f"{rel}:{n}: names Azure")
    for b in bad:
        print("AZURE FAIL", b)
    print(f"no-azure: {len(bad)} violations")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
