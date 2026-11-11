#!/usr/bin/env python3
"""Runner gate (owner rules 2026-10-27 and 2026-11-11, specs/ci-linux.md §3 item 6).

- No macOS runner in any workflow (macOS minutes are billed about 10x).
- Never `schedule` or `pull_request_target`; no `secrets.` reference anywhere.
- A workflow that starts by itself (`push` / `pull_request`) passes only if it has `permissions: contents: read`
  and every job runs on `ubuntu-24.04` or `ubuntu-latest` exactly (no larger runner, no matrix), has
  `timeout-minutes` of 30 or less, and carries the public-only guard word for word.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
GUARD = "github.event_name == 'workflow_dispatch' || github.event.repository.private == false"
RUNNERS = {"ubuntu-24.04", "ubuntu-latest"}
MAX_MINUTES = 30


def _code(line: str) -> str:
    return line.split("#", 1)[0].rstrip()


def _jobs(lines: list[str]) -> dict[str, list[str]]:
    """Job name -> its body lines (the lines indented under it inside `jobs:`)."""
    jobs: dict[str, list[str]] = {}
    inside = False
    current = None
    for raw in lines:
        line = _code(raw)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            inside = line.strip() == "jobs:"
            current = None
            continue
        if not inside:
            continue
        if indent == 2 and line.strip().endswith(":"):
            current = line.strip()[:-1]
            jobs[current] = []
        elif current is not None:
            jobs[current].append(line)
    return jobs


def _value(body: list[str], key: str) -> str | None:
    for line in body:
        if len(line) - len(line.lstrip()) == 4:
            m = re.match(rf"\s*{key}:\s*(.*)$", line)
            if m:
                return m.group(1).strip().strip("'\"") if key != "if" else m.group(1).strip()
    return None


def check_text(name: str, text: str) -> list[str]:
    bad: list[str] = []
    lines = text.splitlines()
    automatic = False
    for n, raw in enumerate(lines, 1):
        code = _code(raw)
        if re.search(r"runs-on:.*macos", code, re.I):
            bad.append(f"{name}:{n}: macOS runner is forbidden")
        if re.match(r"\s*(schedule|pull_request_target)\s*:", code):
            bad.append(f"{name}:{n}: {code.strip()} trigger is forbidden")
        if re.match(r"\s*(push|pull_request)\s*:", code):
            automatic = True
        if "secrets." in code:
            bad.append(f"{name}:{n}: secrets are not used in CI")
    if not automatic:
        return bad
    top = [_code(l) for l in lines]
    has_perm = any(l == "permissions:" for l in top) and any(re.fullmatch(r"\s{2}contents:\s*read", l) for l in top)
    if not has_perm and "permissions: { contents: read }" not in top and "permissions: {contents: read}" not in top:
        bad.append(f"{name}: an automatic workflow needs permissions: contents: read")
    jobs = _jobs(lines)
    if not jobs:
        bad.append(f"{name}: no jobs found")
    for job, body in jobs.items():
        runner = _value(body, "runs-on")
        if runner not in RUNNERS:
            bad.append(f"{name}: job {job}: runs-on must be one of {sorted(RUNNERS)} (got {runner})")
        if any(re.match(r"\s*matrix:", l) for l in body):
            bad.append(f"{name}: job {job}: no matrix in an automatic workflow")
        minutes = _value(body, "timeout-minutes")
        if minutes is None or not minutes.isdigit() or int(minutes) > MAX_MINUTES:
            bad.append(f"{name}: job {job}: timeout-minutes of {MAX_MINUTES} or less is required (got {minutes})")
        guard = _value(body, "if")
        if guard is None or guard.removeprefix("${{").removesuffix("}}").strip() != GUARD:
            bad.append(f"{name}: job {job}: the public-only guard is required: if: {GUARD}")
    return bad


def check(root: pathlib.Path = ROOT) -> list[str]:
    bad: list[str] = []
    for wf in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        bad += check_text(wf.name, wf.read_text(encoding="utf-8"))
    return bad


def main() -> int:
    bad = check()
    for b in bad:
        print("RUNNERS FAIL", b)
    print(f"runners: {len(bad)} violations")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
