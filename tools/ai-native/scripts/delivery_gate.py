#!/usr/bin/env python3
"""Verify a committed, reviewed source tip actually exists on the remote.

This check does not commit, push, merge, or bypass branch rules. Network and
credentials belong to the host runner. A blocked push is not a completed task.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from ai_native import work_snapshot


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args],
                          capture_output=True, text=True, timeout=15)


def check_delivery(repo: Path, remote: str = "origin", branch: str | None = None) -> dict:
    result = {"status": "NOT_VERIFIED", "remote": remote, "branch": branch,
              "head_sha": None, "remote_sha": None, "reason": None}
    if not remote or any(ch.isspace() for ch in remote) or remote.startswith("-"):
        result["reason"] = "invalid remote name"
        return result
    try:
        snapshot = work_snapshot(repo)
        result["head_sha"] = snapshot["commit"]
        if snapshot["dirty"]:
            result["reason"] = "uncommitted tracked or untracked source changes"
            return result
        if not branch:
            name = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD")
            if name.returncode:
                result["reason"] = "detached HEAD; specify an authorized delivery branch"
                return result
            branch = name.stdout.strip()
            result["branch"] = branch
        valid = git(repo, "check-ref-format", "--branch", branch)
        if valid.returncode:
            result["reason"] = "invalid branch name"
            return result
        exists = git(repo, "remote", "get-url", remote)
        if exists.returncode:
            result["reason"] = "configured remote not found"
            return result
        observed = git(repo, "ls-remote", "--heads", remote, "refs/heads/" + branch)
        if observed.returncode:
            result["status"] = "BLOCKED"
            result["reason"] = "remote unreachable or access denied"
            return result
        line = observed.stdout.strip().splitlines()
        if len(line) != 1:
            result["reason"] = "remote branch does not exist"
            return result
        result["remote_sha"] = line[0].split("\t", 1)[0]
        if result["remote_sha"] != result["head_sha"]:
            result["reason"] = "remote SHA does not match reviewed local HEAD"
            return result
        result["status"] = "PASS"
        result["reason"] = "remote branch matches clean committed HEAD"
        return result
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
        result["status"] = "BLOCKED"
        result["reason"] = "git or network verification unavailable"
        return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--branch")
    args = parser.parse_args(argv)
    result = check_delivery(Path(args.repo).resolve(), args.remote, args.branch)
    print(json.dumps(result, indent=2))
    return {"PASS": 0, "NOT_VERIFIED": 4, "BLOCKED": 3}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
