#!/usr/bin/env python3
"""Extract reviewable work candidates from explicitly named Markdown checklists.

This tool never executes candidate work, invents tasks, or edits the work registry.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

CHECKBOX = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[\s\]\s+(.+?)\s*$")
SUPPORTED_SUFFIXES = {".md", ".markdown", ".txt"}


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def source_commit(repo: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True
    )
    return result.stdout.strip()


def discover(repo: Path, sources: list[str], max_items: int = 100) -> dict:
    """Create deterministic candidates with line-level source provenance."""
    repo = Path(repo).resolve()
    if not 1 <= max_items <= 500:
        raise ValueError("max_items must be between 1 and 500")
    if not sources:
        raise ValueError("at least one explicit --source is required")
    commit = source_commit(repo)
    candidates = []
    source_records = []
    seen_paths = set()

    for source in sources:
        supplied = Path(source).expanduser()
        lexical = supplied if supplied.is_absolute() else repo / supplied
        resolved = lexical.resolve()
        if not resolved.is_relative_to(repo):
            raise ValueError("source must resolve inside the repository: " + str(source))
        relative = resolved.relative_to(repo).as_posix()
        if (relative == ".git" or relative.startswith(".git/")
                or relative == ".ai-native" or relative.startswith(".ai-native/")):
            raise ValueError("generated/runtime paths cannot be discovery sources: " + relative)
        if resolved.suffix.lower() not in SUPPORTED_SUFFIXES:
            raise ValueError("unsupported source format; use Markdown or text checklists: " + relative)
        if not resolved.is_file():
            raise ValueError("source is not a regular file: " + relative)
        if relative in seen_paths:
            continue
        seen_paths.add(relative)

        raw = resolved.read_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("source must be UTF-8 text: " + relative) from exc
        file_hash = sha256_bytes(raw)
        count_before = len(candidates)

        for line_number, line in enumerate(text.splitlines(), start=1):
            match = CHECKBOX.match(line)
            if not match:
                continue
            title = " ".join(match.group(1).split()).strip()
            if not title:
                continue
            identity = f"{relative}:{line_number}:{title}".encode("utf-8")
            candidate_id = "disc-" + sha256_bytes(identity)[:12]
            candidates.append({
                "id": candidate_id,
                "status": "NEEDS_REVIEW",
                "title": title,
                "source_path": relative,
                "source_line": line_number,
                "source_line_sha256": sha256_bytes(line.encode("utf-8")),
                "source_sha256": file_hash,
                "source_commit": commit,
            })
            if len(candidates) > max_items:
                raise ValueError(f"candidate count exceeds max_items={max_items}; narrow the explicit sources")

        source_records.append({
            "path": relative,
            "sha256": file_hash,
            "candidate_count": len(candidates) - count_before,
        })

    candidates.sort(key=lambda item: (item["source_path"], item["source_line"], item["id"]))
    source_records.sort(key=lambda item: item["path"])
    return {
        "schema_version": 1,
        "source_commit": commit,
        "sources": source_records,
        "candidate_count": len(candidates),
        "candidates": candidates,
        "notice": "Candidates are unapproved. Review them and create explicit task contracts before execution.",
    }


def safe_output_path(repo: Path, output: str) -> Path:
    """Avoid writing generated state into tracked source or through an escaping symlink."""
    repo = Path(repo).resolve()
    supplied = Path(output).expanduser()
    lexical = supplied if supplied.is_absolute() else repo / supplied
    path = lexical.resolve()
    if lexical.absolute().is_relative_to(repo) and not path.is_relative_to(repo):
        raise ValueError("output symlink escapes repository")
    if path.is_relative_to(repo):
        relative = path.relative_to(repo).as_posix()
        ignored = subprocess.run(
            ["git", "-C", str(repo), "check-ignore", "-q", "--", relative],
            capture_output=True
        )
        if ignored.returncode != 0:
            raise ValueError("output inside repository must be gitignored to preserve source fingerprints")
    return path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--source", action="append", required=True,
                        help="explicit Markdown/text checklist source; repeat for multiple files")
    parser.add_argument("--output", help="optional JSON output path; stdout is the default")
    parser.add_argument("--max-items", type=int, default=100)
    args = parser.parse_args(argv)
    try:
        repo = Path(args.repo).resolve()
        result = discover(repo, args.source, args.max_items)
        rendered = json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        if args.output:
            destination = safe_output_path(repo, args.output)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(rendered, encoding="utf-8")
            print(json.dumps({"result": "CANDIDATES_WRITTEN", "count": result["candidate_count"],
                              "output": str(destination)}, ensure_ascii=False))
        else:
            sys.stdout.write(rendered)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print("DISCOVERY_BLOCKED: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
