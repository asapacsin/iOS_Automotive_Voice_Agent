#!/usr/bin/env python3
"""Optional Claude Code PreToolUse guard for scoped file edits and risky shell commands.

This is a deterministic policy check, not an OS sandbox. Shell writes can bypass
file-tool scope checks; use the agent's sandbox/worktree and required CI gates too.
Enable with AI_NATIVE_GUARD_ENABLED=1 and AI_NATIVE_CONTRACT_PATH pointing to a
task contract that declares approved_paths.
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import sys
from pathlib import Path, PurePosixPath

WRITE_TOOLS = {
    "Edit": ("file_path",),
    "Write": ("file_path",),
    "MultiEdit": ("file_path",),
    "NotebookEdit": ("notebook_path", "file_path"),
}

DANGEROUS_COMMANDS = (
    (re.compile(r"\bgit\s+reset\s+--hard(?:\s|$)", re.IGNORECASE),
     "git reset --hard can discard uncommitted work"),
    (re.compile(r"\bgit\s+clean\b[^;\n|&]*(?:--force|\s-[a-z]*f[a-z]*)(?:\s|$)", re.IGNORECASE),
     "git clean with force can delete untracked files"),
    (re.compile(r"\bgit\s+push\b[^;\n|&]*(?:--force-with-lease|--force(?:\s|$)|\s-f(?:\s|$))", re.IGNORECASE),
     "force-pushing can overwrite shared history"),
    (re.compile(r"\brm\s+-(?:[a-z]*r[a-z]*f[a-z]*|[a-z]*f[a-z]*r[a-z]*)\b", re.IGNORECASE),
     "recursive forced deletion requires explicit human review"),
    (re.compile(r"\bgit\s+checkout\s+--\s+\.(?:\s|$|[;&|])", re.IGNORECASE),
     "git checkout -- . can discard local changes"),
)


def _normalise(value: str) -> str:
    return value.replace("\\", "/").strip()


def _valid_patterns(contract: dict) -> str | None:
    approved = contract.get("approved_paths")
    if not isinstance(approved, list) or not approved:
        return "active contract must declare a non-empty approved_paths list; writes are blocked"
    for field in ("approved_paths", "forbidden_paths"):
        patterns = contract.get(field, [])
        if not isinstance(patterns, list):
            return f"{field} must be a list"
        for raw in patterns:
            if not isinstance(raw, str) or not raw.strip():
                return f"{field} contains an empty or non-string pattern"
            pattern = _normalise(raw)
            if (
                pattern.startswith("/")
                or re.match(r"^[A-Za-z]:/", pattern)
                or Path(pattern).is_absolute()
                or ".." in PurePosixPath(pattern).parts
            ):
                return f"unsafe path pattern in {field}: {raw}"
    return None


def _matches(relative_path: str, pattern: str) -> bool:
    """Match project-relative globs: * stays within one path segment; ** recurses."""
    path_parts = PurePosixPath(_normalise(relative_path)).parts
    pattern_parts = PurePosixPath(_normalise(pattern)).parts

    def match_from(path_index: int, pattern_index: int) -> bool:
        if pattern_index == len(pattern_parts):
            return path_index == len(path_parts)
        token = pattern_parts[pattern_index]
        if token == "**":
            if pattern_index == len(pattern_parts) - 1:
                return True
            return any(
                match_from(next_path_index, pattern_index + 1)
                for next_path_index in range(path_index, len(path_parts) + 1)
            )
        return (
            path_index < len(path_parts)
            and fnmatch.fnmatchcase(path_parts[path_index], token)
            and match_from(path_index + 1, pattern_index + 1)
        )

    return match_from(0, 0)


def _is_protected(relative_path: str) -> bool:
    path = PurePosixPath(relative_path)
    if path.name == "AGENTS.md":
        return True
    if relative_path == ".claude/settings.json":
        return True
    if relative_path == ".github/workflows" or relative_path.startswith(".github/workflows/"):
        return True
    if relative_path == ".ai-native" or relative_path.startswith(".ai-native/"):
        return True
    return False


def _scope_error(raw_path: str, repo: Path, contract: dict) -> str | None:
    if not isinstance(raw_path, str) or not raw_path.strip():
        return "write tool did not provide a target path; blocked by scope guard"
    candidate = Path(raw_path).expanduser()
    if not candidate.is_absolute():
        candidate = repo / candidate
    try:
        resolved = candidate.resolve(strict=False)
        root = repo.resolve()
        relative_path = resolved.relative_to(root).as_posix()
    except (OSError, RuntimeError, ValueError):
        return f"target is outside the project or cannot be resolved: {raw_path}"

    if relative_path in ("", "."):
        return "project root is not a writable file target"
    if _is_protected(relative_path):
        return f"protected policy/control file cannot be edited by the executor: {relative_path}"

    forbidden = contract.get("forbidden_paths", [])
    if any(_matches(relative_path, pattern) for pattern in forbidden):
        return f"target matches forbidden_paths: {relative_path}"

    approved = contract.get("approved_paths", [])
    if not any(_matches(relative_path, pattern) for pattern in approved):
        return f"target is outside approved_paths: {relative_path}"
    return None


def guard_event(event: dict, repo: Path, contract: dict) -> str | None:
    """Return a denial reason, or None when the requested tool call is allowed."""
    tool_name = event.get("tool_name")
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return "hook event has no valid tool_input; blocked by scope guard"

    if tool_name in WRITE_TOOLS:
        for key in WRITE_TOOLS[tool_name]:
            if tool_input.get(key):
                return _scope_error(tool_input[key], repo, contract)
        return "write tool did not provide a target path; blocked by scope guard"

    if tool_name == "Bash":
        command = tool_input.get("command", "")
        if not isinstance(command, str):
            return "shell command is missing or invalid; blocked by scope guard"
        for pattern, reason in DANGEROUS_COMMANDS:
            if pattern.search(command):
                return reason
    return None


def main() -> int:
    if os.environ.get("AI_NATIVE_GUARD_ENABLED") != "1":
        return 0

    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError) as exc:
        print(f"AI-native pre-tool guard blocked malformed hook input: {exc}", file=sys.stderr)
        return 2
    if not isinstance(event, dict):
        print("AI-native pre-tool guard requires a JSON object hook event; blocked.", file=sys.stderr)
        return 2

    contract_path = os.environ.get("AI_NATIVE_CONTRACT_PATH")
    if not contract_path:
        print("AI-native pre-tool guard is enabled but AI_NATIVE_CONTRACT_PATH is unset; blocked.", file=sys.stderr)
        return 2

    try:
        contract = json.loads(Path(contract_path).expanduser().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"AI-native pre-tool guard cannot load the active contract: {exc}; blocked.", file=sys.stderr)
        return 2

    if not isinstance(contract, dict):
        print("AI-native pre-tool guard requires a JSON object contract; blocked.", file=sys.stderr)
        return 2
    policy_error = _valid_patterns(contract)
    if policy_error:
        print(f"AI-native pre-tool guard: {policy_error}", file=sys.stderr)
        return 2

    repo = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
    reason = guard_event(event, repo, contract)
    if reason:
        print(f"AI-native pre-tool guard blocked tool call: {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
