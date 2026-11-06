#!/usr/bin/env python3
"""Host-observed capabilities for dependency-aware AI-native task scheduling.

The capability file belongs to a trusted runner, not the Executor. Missing or
unobserved capabilities fail closed for tasks which explicitly require them;
they do not prevent independent tasks from running.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def validate_capabilities(data: dict) -> dict[str, bool]:
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError("capabilities require schema_version=1")
    values = data.get("capabilities")
    if not isinstance(values, dict):
        raise ValueError("capabilities must be a JSON object")
    for name, available in values.items():
        if not isinstance(name, str) or not name.strip() or not isinstance(available, bool):
            raise ValueError("capability names must be nonempty and values must be booleans")
    return values


def load_capabilities(path: Path | None) -> dict[str, bool]:
    if path is None:
        return {}
    return validate_capabilities(json.loads(path.read_text(encoding="utf-8")))


def missing_capabilities(item: dict, available: dict[str, bool]) -> list[str]:
    return sorted(name for name in item.get("requires", []) if not available.get(name, False))


def probe_command(executable: str, arg: str) -> bool:
    if not shutil.which(executable):
        return False
    try:
        return subprocess.run([executable, arg], capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", help="write to a runner-owned, gitignored JSON path")
    p.add_argument("--weights-file", action="append", default=[],
                   help="required model file; repeat for all required model files")
    args = p.parse_args(argv)
    result = {"schema_version": 1, "capabilities": {
        "nvidia_gpu": probe_command("nvidia-smi", "-L"),
        "ffmpeg": probe_command("ffmpeg", "-version"),
        "model_weights": bool(args.weights_file) and all(
            Path(name).is_file() for name in args.weights_file),
    }}
    payload = json.dumps(result, indent=2) + "\n"
    if args.output:
        path = Path(args.output)
        if path.is_symlink():
            raise ValueError("refusing to overwrite a symlink")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding="utf-8")
    else:
        print(payload, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print("INVALID_CAPABILITIES: " + str(exc), file=sys.stderr)
        raise SystemExit(3)
