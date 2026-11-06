"""Git inventory shared by task governance and the review controller."""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
from pathlib import Path

DIFF_FLAGS = ("--no-ext-diff", "--no-textconv", "--ignore-submodules=none")
EXCLUDE_UNTRACKED = (".ai-native/", ".git/", "__pycache__/", ".pytest_cache/")


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "--no-replace-objects", "--no-optional-locks",
                             "-C", str(repo), *args], capture_output=True)
    if result.returncode:
        raise RuntimeError("git " + " ".join(args) + ": " + result.stderr.decode(errors="replace")[:300])
    return result.stdout


def git_paths(data: bytes) -> list[str]:
    return [os.fsdecode(item) for item in data.split(b"\0") if item]


def untracked_paths(repo: Path) -> list[str]:
    return git_paths(git(repo, "ls-files", "--others", "--exclude-standard", "-z", "--"))


def runtime_output(path: str) -> bool:
    return path.startswith(EXCLUDE_UNTRACKED) or "/__pycache__/" in path


def resolve_base(repo: Path, base: str) -> str:
    if not isinstance(base, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", base):
        raise ValueError("base_commit must be a full 40-character Git commit SHA")
    commit = git(repo, "rev-parse", "--verify", base + "^{commit}").decode().strip()
    if commit != base.lower():
        raise ValueError("base_commit must identify a commit directly")
    return commit


def diff_ranges(base: str, head: str) -> dict[str, tuple[str, ...]]:
    # Preserve staged/unstaged changes that cancel out in a single diff to HEAD.
    return {"committed": (base, head), "staged": ("--cached", head), "unstaged": ()}


def tracked_changes(repo: Path, revisions: tuple[str, ...]) -> dict[str, tuple[str, str]]:
    # With rename detection disabled Git lists both endpoints, one path per entry.
    fields = git_paths(git(repo, "diff", *DIFF_FLAGS, "--no-renames", "--raw",
                          "-z", *revisions, "--"))
    changes = {}
    for metadata, path in zip(fields[::2], fields[1::2], strict=True):
        old_mode, new_mode, *_ = metadata.removeprefix(":").split()
        changes[path] = (old_mode, new_mode)
    return changes


def changed_paths(repo: Path, base: str) -> list[str]:
    base = resolve_base(repo, base)
    head = git(repo, "rev-parse", "HEAD").decode().strip()
    paths = set(untracked_paths(repo))
    for revisions in diff_ranges(base, head).values():
        paths.update(tracked_changes(repo, revisions))
    return sorted(paths)


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def patterns_match(path: str, rule: str) -> bool:
    """Git-style directory prefix or slash-aware * and ** patterns."""
    rule = rule.replace("\\", "/")
    if rule.endswith("/"):
        return path.startswith(rule)
    expression = ""
    i = 0
    while i < len(rule):
        if rule[i:i + 3] == "**/":
            expression += "(?:.*/)?"
            i += 3
        elif rule[i:i + 2] == "**":
            expression += ".*"
            i += 2
        elif rule[i] == "*":
            expression += "[^/]*"
            i += 1
        elif rule[i] == "?":
            expression += "[^/]"
            i += 1
        else:
            expression += re.escape(rule[i])
            i += 1
    return re.fullmatch(expression, path) is not None
