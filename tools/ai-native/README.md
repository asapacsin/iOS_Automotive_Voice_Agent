# AI-native Engineering (Executor-first + End-State Reviewer)

> **Coverage status (2026-10-22): INCOMPLETE.** The shared project has implemented *local* contract approval and scoped checks, an executor/reviewer loop, gate evidence, and a manually populated dependency-aware work frontier. It does **not** yet implement or verify every practice from Android, Aurel, and Edria. In particular, required CI/branch protection, automatic discovery from canonical sources, independent termination review, cost-aware model routing, durable checkpoint recovery, research/design-basis gates, and real project-specific device/GPU/visual validations remain missing or partial. See the [coverage audit](docs/PRACTICE_COVERAGE.md). The controller's unit tests are not full-system parity and do not prove a GitHub Actions run.

Reusable, testable workflow distilled from the Android automotive voice-agent and Aurel game. **Not just prompts:** the Python controller runs real commands, records evidence tied to source fingerprint, hands a packet to an external read-only reviewer, and enforces `PASS | REWORK | BLOCKED | NOT_VERIFIED` with bounded retries.

The optional [portable Stop-hook continuation](docs/HOOK_CYCLE.md) carries the Android repo's bounded keep-going mechanism into this project: it reads the validated work frontier, routes around blocked dependencies, and stops on no progress or a stale end-state review. It is **off by default** and does not discover unrecorded tasks or replace real verification.

The optional Claude Code pre-tool guard (`scripts/pre_tool_guard.py`) can block out-of-scope file edits and common destructive shell commands **before** execution. It is opt-in and defense-in-depth, not a full OS sandbox; see the [pre-tool guard guide](docs/PRE_TOOL_GUARD.md).

## Verify this repository

```bash
python3 -m unittest discover -s tests -v
python3 scripts/ai_native.py validate --contract examples/contract.json
```

## Deterministic control plane

scripts/control_plane.py is a pure policy engine: it consumes observed task/gate/review/frontier state and emits a hashed decision such as RETRY_EXECUTOR, WAIT_EXTERNAL, CONFIGURE_REVIEWER, TASK_VERIFIED, CONTINUE_FRONTIER, HUMAN_HANDOFF, or READY_TO_MERGE. It performs no LLM calls, network requests, shell commands, or clock reads. ai_native.py, frontier.py, and governance.py call this engine instead of independently guessing whether to retry, continue, stop, or merge. Every merge precondition fails closed.

## Enforced governance and autonomous frontier

The local tooling now includes contract-hash approval, scoped paths, exact-tip merge eligibility and independent requirement-scope checks (`scripts/governance.py`), and a dependency-aware autonomous frontier with deferred human tasks and a two-clean-pass human gate (`scripts/frontier.py`). **Neither component is an installed GitHub branch rule or an automatically running multi-agent service.**

See **[community-reviewed deterministic enforcement patterns](docs/COMMUNITY_DETERMINISTIC_PATTERNS.md)** for evidence-based hook, external-loop, state-machine, and GitHub ruleset designs; [operational enforcement commands](docs/ENFORCEMENT.md) and the [practice coverage audit](docs/PRACTICE_COVERAGE.md) describe implementation status and gaps.

## Drive a project

1. Copy and edit `examples/contract.json` (or start with `adapters/aurel.json` / `adapters/android.json`).
2. Configure `AI_NATIVE_EXECUTOR_CMD` (optional) and `AI_NATIVE_REVIEWER_CMD` (required for PASS) to **real authenticated external agent CLIs**; see `scripts/codex_bridge.py` for a working Codex CLI adapter with explicit Luna Medium / Astra High model flags. Prompts alone do not invoke an LLM.
3. Run `python3 scripts/ai_native.py cycle --repo /path/to/project --contract /path/to/contract.json`.
4. Examine `.ai-native/runs/<task-id>/latest.json`, gate logs, review packet and decision. On REWORK, target the changed files and re-verify; do not accept an unsupported green build as E2E proof.

Default: **low-cost Executor → deterministic end-state checks → stronger independent Reviewer → targeted Executor retry**. Escalate to Architect only when important uncertainty warrants it. `max_attempts` and `max_total_seconds` prevent runaway spending.

See [AI Builder Bible](docs/AI_BUILDER_BIBLE.md), [pre-tool guard guide](docs/PRE_TOOL_GUARD.md), and [exact integration instructions](docs/INTEGRATION.md).

## File map

| Path | Role |
| --- | --- |
| `scripts/ai_native.py` | bounded orchestration wired to deterministic retry/stop policy; source and contract fingerprints |
| `scripts/pre_tool_guard.py` | opt-in pre-action path policy and dangerous-shell-command checks |
| `scripts/codex_bridge.py` | optional external Codex executor/reviewer subprocess adapters; live integration not certified |
| `scripts/control_plane.py` | pure deterministic cycle, frontier and merge decisions; decision hash and fail-closed rules |
| `scripts/governance.py` | procedural approvals and scope checks delegated to deterministic merge policy; not GitHub branch protection |
| `scripts/frontier.py` | manually defined dependency frontier, blocker propagation, human handoff gate; no automatic source discovery |
| `docs/PRACTICE_COVERAGE.md` | verified coverage audit and remaining migration roadmap |
| `docs/PRE_TOOL_GUARD.md` | opt-in pre-tool guard setup, test procedure, and limitations |
| `.claude/hooks/ai-native-stop.py` | opt-in end-state Stop hook, guards recursive loops |
| `.claude/settings.json` | PreToolUse and Stop hook registrations; pre-tool guard is disabled unless explicitly enabled |
| `examples/contract.json` | sample spec/acceptance/budget/CLI gate contract |
| `adapters/aurel.json`, `adapters/android.json` | source-specific gate examples; not a claim those apps were tested here |
| `tests/` | controller behavioral tests, including pre-tool policy, false PASS and stale review rejection |
| `.github/workflows/ci.yml` | CI for the portable controller |
| `scripts/publish.ps1` | obsolete bootstrap helper, deliberately refuses to overwrite this existing repository |

## This repository is published

This repository is hosted at [asapacsin/ai-native-engineering](https://github.com/asapacsin/ai-native-engineering). The original bootstrap-only publishing script is retained for historical/reference purposes and deliberately refuses to overwrite this existing repository. Review the [coverage audit](docs/PRACTICE_COVERAGE.md) before claiming all source-project practices are implemented.
