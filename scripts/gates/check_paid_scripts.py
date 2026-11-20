#!/usr/bin/env python3
"""F-18 §32 item 6 (T-046u): every script under scripts/ that names a paid model host takes --max-calls.

A script that sends to a paid model must print its planned calls, start only with --yes or a typed y, take
--max-calls and stop at the first quota error. This gate checks the one thing a reader can check mechanically:
the script names `--max-calls`. Gate scripts and tests are skipped (they hold the host names as data).
"""
import pathlib
import re
import sys

PAID_HOSTS = re.compile(r"dashscope(-intl)?\.aliyuncs\.com|generativelanguage\.googleapis\.com|open\.bigmodel\.cn|"
                        r"qianfan\.baidubce\.com|aip\.baidubce\.com")
SKIP = ("scripts/gates/",)


def offenders(root: pathlib.Path) -> list[str]:
    bad = []
    for path in sorted((root / "scripts").rglob("*")):
        rel = path.relative_to(root).as_posix()
        if path.suffix not in (".py", ".sh") or rel.startswith(SKIP) or "__pycache__" in rel:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if PAID_HOSTS.search(text) and "--max-calls" not in text:
            bad.append(rel)
    return bad


def main(root: pathlib.Path = pathlib.Path(__file__).resolve().parents[2]) -> int:
    bad = offenders(root)
    for rel in bad:
        print(f"check_paid_scripts: {rel} names a paid model host and has no --max-calls (F-18 §32 item 6)")
    if not bad:
        print("check_paid_scripts: OK")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
