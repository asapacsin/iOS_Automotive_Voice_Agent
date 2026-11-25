#!/usr/bin/env python3
"""F-18 §40 items 3-4, row 58 (T-046zc): only the Beijing account's five free-quota models, and no Singapore endpoint.

Scans the app's Swift sources (Packages/*/Sources, App) and the PC eval scripts (scripts/eval, scripts/search_eval) for
chat-model names (qwen…, deepseek-…, kimi-…) and fails on any name outside the five, or on `dashscope-intl`.
Tests and fixtures are not scanned (old records keep the names they were written with).
"""
import pathlib
import re
import sys

ALLOWED = {"qwen3.8-max-0902", "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "kimi-k3.1-pro", "qwen4-max"}
MODEL = re.compile(r"\b(?:qwen[0-9][\w.\-]*|qwen-(?:plus|max|turbo|flash|long)[\w.\-]*|deepseek-[\w.\-]+|kimi-[\w.\-]+)")
ROOTS = ("App", "scripts/eval", "scripts/search_eval")


def files(root: pathlib.Path):
    for pkg in sorted((root / "Packages").glob("*/Sources")):
        yield from sorted(pkg.rglob("*.swift"))
    for r in ROOTS:
        base = root / r
        if base.exists():
            yield from sorted(p for p in base.rglob("*") if p.suffix in (".swift", ".py", ".sh") and "__pycache__" not in p.parts)


def offenders(root: pathlib.Path) -> list[str]:
    bad = []
    for path in files(root):
        rel = path.relative_to(root).as_posix()
        for n, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if "dashscope-intl" in line:
                bad.append(f"{rel}:{n}: dashscope-intl (F-18 §40 item 1: Beijing endpoints only)")
            for m in MODEL.findall(line):
                name = m.rstrip(".-")
                if name not in ALLOWED:
                    bad.append(f"{rel}:{n}: model {name} is not one of the five (F-18 §40 item 3)")
    return bad


def main(root: pathlib.Path = pathlib.Path(__file__).resolve().parents[2]) -> int:
    bad = offenders(root)
    for b in bad:
        print(f"check_qwen_models: {b}")
    if not bad:
        print("check_qwen_models: OK")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
