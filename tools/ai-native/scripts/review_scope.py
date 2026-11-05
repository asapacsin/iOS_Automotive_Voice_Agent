"""Discover advisory reviewer context and validate its source-bound evidence."""
from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path, PurePosixPath, PureWindowsPath

from control_plane import canonical_hash
from git_changes import (DIFF_FLAGS, diff_ranges, file_digest, git, git_paths,
                         patterns_match, resolve_base, runtime_output, tracked_changes, untracked_paths)

DEFAULT_EXCLUDES = ["node_modules/**", "build/**", "dist/**"]
DEPENDENCY_FILES = (
    "pyproject.toml", "setup.cfg", "requirements.txt", "package.json",
    "tsconfig.json", "Cargo.toml", "go.mod", "pom.xml", "build.gradle",
    "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "CMakeLists.txt",
)


def check_path(value: str, *, glob: bool = False) -> None:
    if (not isinstance(value, str) or not value.strip()
            or PureWindowsPath(value).drive
            or any(part in {"", ".", "..", ".git"} for part in value.lower().split("/"))
            or re.search(r"[\\:\x00-\x1f\x7f\ud800-\udfff]", value)
            or (not glob and any(char in value for char in "*?"))):
        raise ValueError("review scope requires safe repository-relative paths and segment globs")


def scope_config(contract: dict) -> dict | None:
    if "review_scope" not in contract:
        return None
    settings = contract["review_scope"]
    defaults = {
        "mode": "diff_first", "context_paths": [], "exclude_paths": DEFAULT_EXCLUDES,
        "allow_scope_expansion": True, "log_scope_expansions": True, "read_policy": "advisory",
    }
    if not isinstance(settings, dict) or settings.keys() - defaults.keys():
        raise ValueError("review_scope must be an object containing only supported fields")
    settings = {**defaults, **settings}
    if settings["mode"] != "diff_first" or settings["read_policy"] not in ("advisory", "strict"):
        raise ValueError("review_scope requires diff_first mode and advisory or strict read_policy")
    for key in ("allow_scope_expansion", "log_scope_expansions"):
        if not isinstance(settings[key], bool):
            raise ValueError("review_scope." + key + " must be boolean")
    for key in ("context_paths", "exclude_paths"):
        if not isinstance(settings[key], list):
            raise ValueError("review_scope." + key + " must be an array of paths")
        for value in settings[key]:
            check_path(value, glob=key == "exclude_paths")
    return settings


def trusted_base(repo: Path, contract: dict, settings: dict, head: str) -> str:
    if settings["read_policy"] == "strict":
        raise ValueError("strict review read isolation requires an enforced allowlist; this runner supports advisory scope")
    git_root = Path(os.fsdecode(git(repo, "rev-parse", "--show-toplevel")).rstrip("\r\n")).resolve()
    if git_root != repo:
        raise ValueError("scoped review requires the root of the Git worktree")
    base = resolve_base(repo, contract.get("base_commit"))
    git(repo, "merge-base", "--is-ancestor", base, head)
    return base


def local_path(repo: Path, relative: str) -> Path:
    """Only read literal in-repo paths, without traversing symlinks or junctions."""
    check_path(relative)
    path = repo
    for component in relative.split("/"):
        path = path / component
        if path.is_symlink() or path.resolve() != path:
            raise ValueError("unsafe symlink or redirected review path: " + relative)
    return path


def context_digest(repo: Path, relative: str) -> str:
    path = local_path(repo, relative)
    if not path.is_file():
        raise ValueError("missing or unreadable review context: " + relative)
    return file_digest(path)


def discover_context(repo: Path, contract: dict, settings: dict, changed: list[str],
                     tracked: set[str], untracked: list[str]) -> tuple[list[str], list[str]]:
    # Literal directories expand over Git's visible files. Literal files can also
    # point to mandatory ignored evidence produced by a gate.
    explicit = set()
    for relative in settings["context_paths"]:
        path = local_path(repo, relative)
        if path.is_dir():
            children = {name for name in tracked.union(untracked)
                        if name.startswith(relative + "/")
                        and ((repo / name).exists() or (repo / name).is_symlink())}
            if not children:
                raise ValueError("review context directory has no visible files: " + relative)
            explicit.update(children)
        else:
            explicit.add(relative)

    hints = set()
    for relative in changed:
        path = PurePosixPath(relative)
        stem = path.stem
        if path.suffix == ".py":
            hints.update(str(p) for p in (path.with_name(f"test_{stem}.py"),
                                          PurePosixPath("tests") / f"test_{stem}.py"))
        elif path.suffix in {".ts", ".tsx", ".js", ".jsx"}:
            hints.update(str(path.with_name(stem + suffix + path.suffix))
                         for suffix in (".test", ".spec"))
        for parent in path.parents:
            hints.update(str(parent / name) for name in DEPENDENCY_FILES)
    for gate in contract["gates"]:
        hints.update(arg.removeprefix("./") for arg in gate["command"])
    hints.intersection_update(tracked.union(untracked))
    hints = {name for name in hints if not any(patterns_match(name, pattern)
                                               for pattern in settings["exclude_paths"])}
    hints = {name for name in hints if (repo / name).is_file() or (repo / name).is_symlink()}
    context = explicit | hints

    instructions = {"AGENTS.md", "AGENTS.override.md", "CLAUDE.md", ".claude/CLAUDE.md"}
    for relative in set(changed) | context:
        for parent in PurePosixPath(relative).parents:
            instructions.update(str(parent / name) for name in
                                ("AGENTS.md", "AGENTS.override.md", "CLAUDE.md"))
    applicable = sorted(name for name in instructions
                        if (repo / name).exists() or (repo / name).is_symlink())
    return sorted(context), applicable


def build_manifest(repo: Path, contract: dict, settings: dict, snapshot: dict,
                   gate_evidence: str) -> dict:
    head = snapshot["commit"]
    base = trusted_base(repo, contract, settings, head)
    index = git_paths(git(repo, "ls-files", "-v", "-z"))
    if any(item[0] == "S" or item[0].islower() for item in index):
        raise ValueError("Git index has skip-worktree or assume-unchanged paths")
    if git(repo, "ls-files", "--unmerged", "-z"):
        raise ValueError("unmerged Git index prevents a complete review diff")
    tracked = {item[2:] for item in index}

    diffs = {}
    changed = set()
    for name, revisions in diff_ranges(base, head).items():
        changes = tracked_changes(repo, revisions)
        if any("160000" in modes for modes in changes.values()):
            raise ValueError("changed submodule requires its own complete review")
        changed.update(changes)
        args = ["diff", *DIFF_FLAGS, "--binary", "--full-index", "--no-color", "--find-renames",
                "--submodule=short", *revisions, "--"]
        patch = git(repo, *args)
        diffs[name] = {"files": sorted(changes), "argv": ["git", "--no-replace-objects",
                                                        "--no-optional-locks", *args],
                       "sha256": hashlib.sha256(patch).hexdigest()}

    untracked = sorted(name for name in untracked_paths(repo) if not runtime_output(name))
    if set(untracked) != snapshot["untracked_hashes"].keys():
        raise ValueError("untracked paths could not be completely fingerprinted")
    changed.update(untracked)
    changed = sorted(changed)
    for name in changed:
        check_path(name)

    context, instructions = discover_context(repo, contract, settings, changed, tracked, untracked)
    evidence_files = sorted(set(context) | set(instructions) | {gate_evidence})
    return {
        "schema_version": 1, **settings, "base_commit": base, "head_commit": head,
        "source_fingerprint": snapshot["fingerprint"], "contract_hash": canonical_hash(contract),
        "diffs": diffs, "untracked": snapshot["untracked_hashes"],
        "changed_files": changed,
        "initial_files": changed + [name for name in evidence_files if name not in changed],
        "project_instructions": instructions, "gate_evidence": gate_evidence,
        "context_hashes": {name: context_digest(repo, name) for name in evidence_files},
    }


def check_scope_result(repo: Path, manifest: dict, result: dict, *, require_complete: bool = True) -> None:
    if (not isinstance(result, dict)
            or result.get("mode") != manifest["mode"]
            or result.get("manifest_hash") != canonical_hash(manifest)
            or not isinstance(result.get("scope_complete"), bool)):
        raise ValueError("reviewer evidence is incomplete or bound to a different review scope")
    initial = result.get("initial_files")
    if result["scope_complete"]:
        if initial != manifest["initial_files"]:
            raise ValueError("reviewer omitted initial scope files or reported them out of order")
    elif require_complete:
        raise ValueError("reviewer evidence is incomplete")
    elif not isinstance(initial, list) or not all(isinstance(path, str) for path in initial):
        raise ValueError("partial review scope must list inspected initial files")
    else:
        inspected = set(initial)
        if initial != [path for path in manifest["initial_files"] if path in inspected]:
            raise ValueError("partial review scope must list inspected initial files in manifest order")
    files, reasons = result.get("additional_files"), result.get("expansion_reasons")
    if not isinstance(files, list) or not isinstance(reasons, list) or len(files) != len(reasons):
        raise ValueError("review scope expansions require one reason per file")
    if files and not manifest["allow_scope_expansion"]:
        raise ValueError("reviewer expanded scope while expansion was disabled")
    seen = set(manifest["initial_files"])
    for path, reason in zip(files, reasons):
        check_path(path)
        if path in seen or not isinstance(reason, str) or not reason.strip() or runtime_output(path):
            raise ValueError("review scope expansions require unique source files and nonempty reasons")
        # Scope expansions may use Git-visible source. Declare ignored evidence
        # explicitly so its contents are bound to the manifest.
        if not local_path(repo, path).is_file() or (
            path not in manifest["untracked"]
            and not git(repo, "--literal-pathspecs", "ls-files", "--cached", "-z", "--", path)
        ):
            raise ValueError("review scope expansion is missing or outside Git-visible source: " + path)
        seen.add(path)
