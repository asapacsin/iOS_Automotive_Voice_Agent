# Operational integration

## 1. Create a real task contract

Copy `examples/contract.json`, edit `task_id`, `goal`, `acceptance`, `boundaries` and `gates`. Gate `command` is an argv array; it does not run in a shell unless you **explicitly** call `bash -lc` or `powershell -Command`. A failed gate is not proof of successful implementation. Use `python3 scripts/ai_native.py validate --contract mytask.json` to check shape.

## 2. Configure actual external agents

Set `AI_NATIVE_EXECUTOR_CMD` to a working *already authenticated* executor CLI command that implements the contract in `AI_NATIVE_CONTRACT`, reads previous feedback in `AI_NATIVE_FEEDBACK`, and exits 0 when implementation work is complete. Set `AI_NATIVE_REVIEWER_CMD` to a **different read-only** agent invocation. The reviewer must load the exact JSON file in `AI_NATIVE_REVIEW_PACKET`, inspect the actual diff and evidence in the target repo, and write strict JSON at `AI_NATIVE_REVIEW_RESULT`:

```json
{"verdict": "PASS", "reviewed_fingerprint": "<value from packet.snapshot.fingerprint>", "reviewed_contract_hash": "<value from packet.contract_hash>", "findings": [], "next_action": "merge after CI evidence"}
```

Valid verdicts: `PASS`, `REWORK`, `BLOCKED`, `NOT_VERIFIED`. The deterministic control plane (scripts/control_plane.py) owns retry/stop decisions; the reviewer cannot override failed gates, retry limits, stale fingerprints, or contract-hash mismatches. If required gates fail, `PASS` is automatically downgraded. If no reviewer, stale fingerprint, malformed JSON, or source changed during review: `NOT_VERIFIED`. Use different model/session for independent review, not the writer self-grading. Client-specific Claude/Codex CLI syntax differs by version; verify actual selected model/effort in its logs. This project intentionally does not pretend a named model tier is automatically routed.

Do not run the reviewer with source-editing permissions. A non-mutating source snapshot check detects changes to tracked/untracked files, but cannot substitute for OS read-only permissions or a dedicated worktree.

## 3. Drive the cycle

```bash
python3 scripts/ai_native.py cycle --repo /path/to/target-repo --contract /path/to/task.json
```

With `AI_NATIVE_EXECUTOR_CMD` set, the controller invokes Executor -> configured gate commands -> reviewer; repeats only on REWORK up to `max_attempts` and overall deadline. Without an Executor command, it verifies current state just once. Without a Reviewer command, the verdict is NOT_VERIFIED, even if tests pass. Evidence is written under `<target>/.ai-native/runs/<task-id>/` (gitignored).

Exit codes: `0 PASS`, `2 REWORK`, `3 BLOCKED`, `4 NOT_VERIFIED`, `5 invalid config or controller failure`. When a time/retry budget is exhausted, inspect the latest verdict and escalate rather than continuing indefinitely.

## 4. Optional Claude Stop hook

Copy `.claude/hooks/ai-native-stop.py` and `.claude/settings.json` into the *target repo* with `scripts/ai_native.py`. Enable only after testing your CLI configuration:

```bash
export AI_NATIVE_STOP_ENABLED=1
export AI_NATIVE_CONTRACT_PATH=/absolute/path/to/active-contract.json
export AI_NATIVE_REVIEWER_CMD='your read-only reviewer cli command'
```

The Stop hook runs the end-state cycle once and may block a stop after REWORK; it does **not** spawn unbounded recursive agents. When `stop_hook_active=true`, it exits without blocking. Disabling the hook or missing contract leaves normal agent shutdown alone. Hook behavior and schema are intended for compatible Claude Code versions; test the host's actual hook support before relying on it. Reviewer invocation is still required. For Codex/Cursor, call `cycle` from your own task-completion command/hook instead of assuming their stop APIs match Claude's.

## 5. Project-specific evidence

**Aurel:** use `adapters/aurel.json` in `aurel-game`; CMake/CTest prove reference/native test tiers as indicated by test names; Aurel `verification/gates.json` records stage provenance. Do **not** promote reference CLI tests to neural runtime success. GPU work needs actual videos, VRAM, latency and live checks; attach a required gate with real measurements before claiming end-to-end PASS.

**Android:** use `adapters/android.json` in `Android_Automotive_Voice_Agent`; actual runtime may require PowerShell (`gradlew.bat`) on Windows. JVM, compile, emulator/device, network and real microphone/navigation evidence are separate. Add required device/emulator gates for changes to audio, map and lifecycle. Running `test_matrix.py --gate` is policy/phase validation, **not** a real device pass.

## 6. CI and integration

The starter's CI tests the controller itself; it does not run the two product test suites. Configure branch protection to require the appropriate **target project** CI checks and accepted reviewer artifact before merging `exec/*` branches. The CLI verdict is a local evidence file; no branch protection is installed by this repo.

## 7. Ready-to-run Codex role adapters (no invented automatic routing)

The starter includes `scripts/codex_bridge.py`, a real Codex CLI wrapper. The default configured model names are `gpt-6-luna` with `medium` for Executor and `gpt-6-astra` with `high` for Reviewer. They are explicit CLI flags, not assumptions about your ChatGPT UI entitlement. Install and authenticate Codex on the machine which runs the scripts, then set both environment variables to absolute paths of the bridge file:

```bash
export AI_NATIVE_EXECUTOR_CMD="python3 /absolute/path/ai-native-engineering/scripts/codex_bridge.py executor"
export AI_NATIVE_REVIEWER_CMD="python3 /absolute/path/ai-native-engineering/scripts/codex_bridge.py reviewer"
python3 /absolute/path/ai-native-engineering/scripts/ai_native.py cycle --repo /path/to/project --contract /path/to/task.json
```

On Windows PowerShell:

```powershell
$env:AI_NATIVE_EXECUTOR_CMD = 'python C:\path\to\ai-native-engineering\\scripts\\codex_bridge.py executor'
$env:AI_NATIVE_REVIEWER_CMD = 'python C:\path\to\ai-native-engineering\\scripts\\codex_bridge.py reviewer'
python C:\path\to\ai-native-engineering\\scripts\\ai_native.py cycle --repo C:\path\to\project --contract C:\path\to\task.json
```

Change actual installed model selection through `AI_NATIVE_EXECUTOR_MODEL`, `AI_NATIVE_REVIEWER_MODEL`, and corresponding `_EFFORT` env vars. Verify the resulting Codex session activity. This wrapper uses `codex exec --model ... --sandbox ... --output-schema ... --output-last-message ...` as documented by the Codex non-interactive workflow. The reviewer is sandboxed read-only; the controller rejects a stale fingerprint or a reviewer process modifying the tracked source.

**Security and billing:** this launches real model sessions consuming the account/API allowance where available. Authenticate through Codex itself, not by committing tokens. Run on a small disposable branch first. Never invoke it with untrusted task contracts, which contain executable gate commands.
