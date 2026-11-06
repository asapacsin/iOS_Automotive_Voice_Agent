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

Copy `.claude/hooks/ai-native-stop.py` and `.claude/settings.json` into the *target repo* with the controller and its companion modules in `scripts/`. Enable only after testing your CLI configuration:

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


## 8. Subprocess credential scope and log redaction

The controller now constructs separate child environments for executor, gate and
reviewer processes. It passes ordinary runtime variables (PATH, HOME,
JAVA_HOME and ANDROID_SDK_ROOT), its own task protocol fields, and the selected
role's model configuration. It does **not** copy arbitrary API tokens from the
parent process. For a role that explicitly needs a secret, grant only the
needed variable names, not the values, with a comma-separated allowlist:


```bash
export AI_NATIVE_EXECUTOR_ENV_ALLOWLIST=OPENAI_API_KEY
export AI_NATIVE_REVIEWER_ENV_ALLOWLIST=REVIEWER_API_KEY
# Only if a verification command truly needs credentials:
export AI_NATIVE_GATE_ENV_ALLOWLIST=TEST_SERVICE_TOKEN
```

On Windows PowerShell set the AI_NATIVE_EXECUTOR_ENV_ALLOWLIST environment
variable to OPENAI_API_KEY (and correspondingly for other roles). Environment
variable names are checked; wildcards are rejected. CLI commands that
authenticate using files under HOME still have access to those files: separate
HOME/profile directories, OS users, sandbox permissions and file/network
restrictions are required for genuine credential and reviewer isolation.
Set AI_NATIVE_REVIEWER_HOME (and optionally AI_NATIVE_EXECUTOR_HOME) to
separate credential-profile directories if your CLI loads credentials from HOME.
The runtime does not create or authenticate those profiles for you. The
model role string or read-only prompt is never an authentication boundary.

Controller command logs, stderr/stdout excerpts and reviewer findings redact
recognized credential patterns and known sensitive parent environment values.
This is defense in depth; do not print secrets in arbitrary formats or supply
them in argv, specs or prompts. Check target-project artifact retention
and permissions. Authentication remains an explicit deployment prerequisite.

## 9. Task merge is not project release

The governance eligible command checks the exact task under review, mandatory
requirement evidence, current fingerprint and approved scope; it does not
pretend that all unrelated work has finished. To require PROJECT RELEASE
readiness, additionally provide a verified work registry:


```bash
python3 scripts/governance.py eligible \
  --repo /path/to/project \
  --contract /path/to/task.json \
  --requirements /path/to/project/verification/requirements.json \
  --release-registry /path/to/project/verification/work.json
```

A release requires every frontier item to be terminal and every PASS to
reference actual JSON evidence files under .ai-native/ with a matching
source_fingerprint, PASS status and exact SHA-256, plus no unresolved human
or external tasks. The supervisor records each passing item's contract_hash;
its evidence descriptor binds the task ID and contract hash to the exact
latest.json review report through report_path and report_sha256. The release
gate checks the report's own PASS, source fingerprint, reviewed contract hash,
and TASK_VERIFIED control-plane decision. Reusing another task's proof or
changing the reviewed report invalidates release evidence. Prior PASS files
become stale when the source changes. Missing/invalid registry data fails
closed. These hashes prove consistency and integrity, not that a trusted
hardware runner actually executed the test. This CLI still does not
authenticate human attestations, establish physical-device provenance, or
configure hosted branch protection.

## 10. Verification levels

- The unittest command below tests the controller and a full
  test-double-backed external process cycle.
- A successful GitHub Actions job proves that the checked-out controller
  revision passed those tests in the workflow runner.
- A live authenticated Executor/Reviewer run in a disposable target worktree
  is still required to certify provider integration and actual model selection.
- Configure GitHub rulesets and required status checks separately. A workflow
  YAML file does not make a branch protected.


```bash
python3 -m unittest discover -s tests -v
```


## 11. Bounded durable external supervisor

Use the external supervisor for sessions spanning multiple tasks. It consumes a
trusted, explicit work registry, not a model-invented backlog. Each autonomous
entry must include contract_path and a matching task_id, in addition to the
required id, owner, status, action and depends_on fields.

**Keep the mutable runtime registry outside the target Git tree or under a
gitignored folder such as .ai-native/work.json.** Modifying a tracked registry
after review would invalidate the source fingerprint. The controller rejects
tracked or non-ignored runtime registries in the worktree.


```bash
python3 scripts/supervisor.py --repo /path/to/project \
  --registry /path/to/project/.ai-native/work.json \
  --max-tasks 10 --max-seconds 1800
```

The supervisor creates an exclusive lock and checkpoints every task. On
restart, a RUNNING task advances to PASS only if its current exact-tree,
exact-contract independent review is valid; otherwise it becomes
BLOCKED_EXTERNAL for diagnosis while unrelated work may proceed. On restart it automatically reclaims a stale
lock only when the previous process ID no longer exists. If the lock owner
cannot be verified, it refuses concurrent execution; investigate before
manual intervention. This design is synchronous and single-host;
it does not claim distributed scheduling or exactly-once process execution.
A trusted operator/CI must keep the runtime registry and requirements outside
Executor write permissions. The optional Claude Stop hook is not a replacement
for this external driver.

## 12. Source-backed task discovery

Use `scripts/discover_work.py` to turn unchecked Markdown/text checklist items in explicitly named, trusted files into reviewable candidates with source path, line number, source-file SHA-256, line SHA-256, and current Git commit provenance.

```bash
python3 scripts/discover_work.py \
  --repo /path/to/project \
  --source OPEN_PROBLEMS.md \
  --source docs/PROJECT_PLAN.md \
  --output .ai-native/candidates.json \
  --max-items 100
```

The command only reads the listed files and emits candidate JSON. It does not execute tasks, create contracts, promote candidates into `work.json`, or claim that a candidate is approved. Review each candidate, confirm its scope and acceptance criteria, then create an explicit task contract. Only unchecked `[ ]` Markdown/text checklist items are recognized; completed `[x]` items and unlisted files are ignored. Generated/runtime directories such as `.ai-native/` and `.git/` cannot be discovery sources.

The default output is stdout. If writing inside the target repository, the output path must already be gitignored (normally via `.ai-native/`) so generated discovery state cannot invalidate reviewed source fingerprints. The item limit fails closed instead of silently truncating the backlog. This is the first source adapter, not full discovery from test failures, issue trackers, requirement manifests, or stale evidence.

## 13. Resource-aware execution and remote-delivery checks

See [ENVIRONMENT_CONTINUATION.md](ENVIRONMENT_CONTINUATION.md) for the exact runner commands and task-status rules. `scripts/capabilities.py` probes whether an NVIDIA GPU, FFmpeg and explicitly identified model files are available. An item with `requires: ["nvidia_gpu", "model_weights"]` is blocked only when those capabilities are absent; unrelated CPU tasks continue. The runner must keep its mutable registry/capabilities gitignored or outside the worktree and protect them from Executor writes.

`scripts/supervisor.py --capabilities <trusted.json> --require-remote` is the opt-in fail-closed delivery mode. It never pushes for you: final checks/review must target the committed source, publication must occur on an authorized branch, and the remote SHA must match. Missing GPU, withheld model approval, or failed GitHub push are named **task-level blockers**, not evidence that a whole project is complete. The cloud task must actually invoke the external supervisor; these files do not install a Codex Cloud Stop hook.

## 14. Diff-first reviewer scope

Copy [review-scope-contract.json](../examples/review-scope-contract.json) outside
the target worktree or into a Git-ignored folder. Before the Executor starts,
run `git rev-parse HEAD` at the agreed task baseline and set `base_commit` to
that full SHA. Point `--repo` at the Git worktree root. Keep the original contract and runner configuration under
operator or CI control. Edit the example's acceptance, paths, and gate commands
for the task, then validate it with `scripts/ai_native.py validate --contract`.
Run the usual cycle or Stop hook with the existing read-only reviewer command.
When installing the hook in another project, copy the controller with its
companion Python modules or invoke it from the full source checkout.

| Field | Behavior |
| --- | --- |
| `mode` | `diff_first` inspects committed, staged, and unstaged patches and Git-visible untracked files before opening the remaining task context. |
| `context_paths` | Literal repository-relative files or directories. Directories expand to existing Git-visible files. Name a required Git-ignored test artifact as a literal file. Missing or redirected required context blocks verification. |
| `exclude_paths` | Slash-aware globs that filter inferred context only. They cannot hide tracked edits, Git-visible untracked files, applicable project instructions, explicit context, or gate evidence. Use Git's ignore rules for disposable build outputs. |
| `allow_scope_expansion` | Defaults to `true`. The reviewer can open other Git-visible source when a concrete question requires it. If expansion is disabled and required context is missing, the reviewer returns `NOT_VERIFIED`. |
| `log_scope_expansions` | Defaults to `true` and prints an additional line for each expansion. The result and verdict always retain each reported file and its reason. |
| `read_policy` | `advisory` guides inspection. Codex still runs in its separate read-only sandbox. `strict` returns `NOT_VERIFIED` because this runner has no enforced read allowlist. Claude Code's own permissions apply to Claude Code. |

Contracts that omit `review_scope` keep the original reviewer protocol.
An empty `review_scope` object opts into the defaults and requires a trusted
`base_commit` that is available and an ancestor of the current HEAD. Scoped
review rejects unresolved index entries, entries marked skip-worktree or
assume-unchanged, and changed submodules. Track a submodule change with a
separate task in that repository and supply its evidence through your
project's verification process.

Each scoped attempt writes `review_scope.json` and includes the manifest and
its hash in `review_packet.json`. See the [sample manifest](../examples/review-scope-manifest.json),
which was captured from the regression fixture. The manifest lists both sides
of renames, deleted paths, and three commands that reproduce the complete
tracked patches. Each command has a SHA-256 of its raw output. Untracked files
have content hashes, and links are represented by hashes of the link target
text. Initial context can also include nearby dependency manifests, conventionally
named tests, and files named in gate commands. The packet includes gate
summaries and the path to `gates.json`. Store
additional mandatory gate outputs at explicit context paths when summaries
alone cannot prove acceptance. Raw patches are read from Git in the target
checkout, keeping a second copy of the diff out of run artifacts.

A custom reviewer still returns the original verdict fields and adds the
following `review_scope` object. The ordered `initial_files` must match the
manifest for a complete review. The file and reason arrays are positional.

```json
{
  "mode": "diff_first",
  "manifest_hash": "<packet.review_scope_hash>",
  "initial_files": [
    "scripts/service.py",
    ".ai-native/runs/scope/attempt-01/gates.json",
    "AGENTS.md"
  ],
  "additional_files": ["scripts/caller.py"],
  "expansion_reasons": ["Verify how the caller consumes the updated result."],
  "scope_complete": true
}
```

The controller rejects a complete verdict with missing initial files, a
stale hash, or a disallowed expansion. The supervisor and merge eligibility
check the saved scope again before relying on a scoped PASS. Advisory logs
record what the reviewer reports inspecting. They are not a filesystem
access audit. Keep Git metadata, the reviewer command, and run artifacts
under trusted runner control. If the reviewer cannot inspect essential
material within its limits, it returns `NOT_VERIFIED` with
`scope_complete: false`.

**Verification example.** Run
`python3 -m unittest discover -s tests -p test_review_scope.py -v`.
The end-to-end fixture uses an external test double that executes and verifies
the three diff commands, reads the untracked source, checks the initial
context and gate evidence, then opens `scripts/caller.py` to confirm the
changed function's integration. The test asserts that order and checks that
the reviewer records the caller and its reason. It also exercises a staged
edit reversed in the worktree and confirms the path remains visible in both
patches. This establishes the controller's ordering and evidence protocol
with a test double. A live Codex run is needed to observe model behavior.
