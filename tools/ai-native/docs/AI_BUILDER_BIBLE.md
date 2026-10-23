# AI Builder Bible — shared reusable operating system

## Objective

Increase *validated useful outcomes per dollar and hour*, not tokens consumed or agents spawned. Human defines outcomes, architecture boundaries and risk appetite; software runs deterministic verification; independent AI reviewer is called only at the end-state and for substantive decisions.

## Default control loop

```text
Human-approved spec + cost/acceptance contract
                 |
                 v
       low-cost Executor (default)
                 |
                 v
     deterministic end-state trigger
          |             |
  unit/build/replay   fingerprint of HEAD + dirty/untracked state
          |             |
          +---- evidence packet ----+
                                    |
                        independent strong Reviewer
                                    |
                   +----------------+------------------+
                   |                |                  |
                PASS             REWORK        BLOCKED/NOT_VERIFIED
                   |                |                  |
              accept task    targeted task for   record precise
              + find next    Executor (bounded)   dependency/proof gap
```

The Reviewer MUST actually be invoked through an external client (for example a configured Codex CLI invocation) and given a read-only role/prompt. Merely setting `model_policy.independent_reviewer = Astra` does not call that model. See `docs/INTEGRATION.md`.

## Model policy

| Role | Default strategy | When invoked |
| --- | --- | --- |
| Executor | capable economical model such as GPT-6 Luna Medium | Most coding, tests, fixes, doc work |
| Planner | short, optional higher-reasoning context | Scope ambiguity, subtask allocation |
| Reviewer | *independent* strong model such as GPT-6 Astra High | End-state inspection, diff, acceptance, evidence, risks |
| Architect | expensive high-reasoning model | New architecture, violated invariant, ambiguous defect after 2 failed fixes |

A stronger reviewer does not automatically fix code. It emits a narrow correction contract for the Executor. Avoid passing entire repo/logs; provide task, fingerprint, changed files and gate failures. Inspect actual diff, not worker claims.

## Engineering invariants

- **One owner** per mutable state/behavior. Improve existing seams, don't create shadow state machines.
- **Executable proof** outranks persuasive summaries. Use builds, unit/integration tests, end-to-end traces and hardware observations scoped honestly.
- **Evidence provenance**: source commit, complete dirty state fingerprint, commands, observed outputs and reviewer verdict. Do not mark PASS because a previous session claimed success.
- **Deterministic code enforces policies**; prompts guide but cannot enforce. An optional Stop hook is only a convenience. CI/branch protection should enforce required gates and accepted reviews where configured.
- **Pre-tool guard**: for supported file-edit tools, apply task-specific `approved_paths` and `forbidden_paths` before the tool executes; fail closed when the active policy is missing or malformed, and protect agent instructions, CI workflows and evidence state. The optional Claude Code hook is documented in `docs/PRE_TOOL_GUARD.md`. This is defense-in-depth, not a sandbox: arbitrary shell writes and other agent tools can bypass file-tool checks, so pair it with isolated worktrees, client sandbox/permission controls, and required CI.
- **Bounded autonomy**: max retries, command timeouts, time/token/GPU cost caps; continue independent work after external blockers, never use infinite recursive Stop hooks.
- **No fabricated human/device results**: user testing, emulator, ADB, GPU and live-service checks require actual evidence. Classify unresolved as NOT_VERIFIED/BLOCKED, rather than advertising PASS.

## Imported patterns (not copied product code)

From [Android_Automotive_Voice_Agent](https://github.com/asapacsin/Android_Automotive_Voice_Agent): task contracts, role boundaries, read-only reviewer, review-before-integration, Stop/continue hook, TEST_MATRIX distinction of test layers. From `aurel-game`: `verification/gates.json`, `scripts/engineering.py` check/report/next, explicit dependency frontier, replay/native/neural evidence scope, GPU blocker discipline. The portable implementation consolidates these rather than depending on Android/Gradle/CMake.

## Evidence and limitations

A successful local unit-test result means only the harness unit tests ran. It does not mean the Aurel neural GPU workflow, Android speech/navigation E2E or any actual LLM provider review was run. Template gate commands must be executed in the respective repos; external Reviewer/Executor CLIs require authentication and working model selection. `PASS` is scoped to contract gates; if hardware is mandatory, add a real hardware gate before accepting.
