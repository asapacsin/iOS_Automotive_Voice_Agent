# Community implementation patterns for deterministic coding-agent rules
_Audit date: 2026-10-22. This document summarizes observed open-source projects and vendor documentation. Source links are external; the conclusions are architectural recommendations, not proof that this repository has installed every integration._

## Practical conclusion

The strongest practical pattern is **layered enforcement**:

1. **Before action:** a tool interception hook may deny an out-of-scope edit or destructive command.
2. **Outside the model:** an orchestrating process chooses the next authorized task, drives the model, executes independent gates, records evidence and bounds retries/cost/time.
3. **At completion:** a deterministic control plane examines task/gate/reviewer state, then issues CONTINUE, RETRY, BLOCKED or VERIFIED. The AI's natural-language "done" is not a state transition.
4. **At integration:** protected GitHub rules require a verified CI job and appropriate review before a change can reach `main`.

No one layer is sufficient. The hook belongs to the agent process and is not a secure boundary; CI/rulesets run independently of the agent's stated intentions. Hardware proof still requires a real runner/device.

## Case studies and actionable takeaways

| Public reference | Implementation observed | Adopt / avoid |
|---|---|---|
| [Anthropic Claude Code hook guidance](https://claude.com/resources/articles/how-to-configure-hooks) | `PreToolUse` before file/shell operations, `PostToolUse` after edits, `Stop` on attempted completion, `SubagentStop` on delegated completion | Adopt interceptors with narrow tested policies; use a Stop hook only as a trigger, not as primary evidence |
| [OpenAI Codex hooks](https://learn.chatgpt.com/docs/hooks) | Project-level `.codex/hooks.json`, `PreToolUse`, `PostToolUse`, `Stop`, trust workflow via `/hooks`; supported denial JSON, stop continuation JSON | Add a Codex adapter separately after live compatibility tests; Codex hooks need explicit user trust and may not cover every hosted tool |
| [snarktank/ralph](https://github.com/snarktank/ralph) | Outer shell script launches one fresh coding-agent process per small PRD story; `prd.json` + `progress.txt` + git commits persist state; bounded iterations | Copy the cheap *outside-the-model* driver. Upgrade its author-written `passes` flags to independently verified evidence |
| [Themis-Foundry/agent-guardrails](https://github.com/Themis-Foundry/agent-guardrails) | Claude `PreToolUse` guard for broad staging, destructive actions, sensitive paths/egress; large regression matrix with allow/deny/ask | Test every hook rule, including false positives, shell tricks and a deliberately forbidden operation. Fail-closed for high-severity actions; avoid brittle regex as sole security control |
| [LangGraph persistence](https://langchain-ai.github.io/langgraph/concepts/durable_execution/) | Checkpointed graph state to resume after interruptions, faults and human input | Useful once work spans restarts, parallel branches or multiple machines. Not required just to put a shell/test gate around one agent |
| [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository) | Require pull requests, required status checks, optional review, no direct push/force-push; protected branch-level policy | Essential remote enforcement; local `git` hooks and agent instructions alone do not prevent a direct GitHub merge |

### What is genuinely deterministic?

A deterministic **decision** is computed by code from an explicit state snapshot, e.g. `reviewed_sha == current_sha and every required_check.status == PASS`. Running a test is deterministic only relative to its environment and inputs; flaky tests and hardware measurements can be nondeterministic. A model reviewer is probabilistic; a deterministic controller can make the review **mandatory**, bind it to the exact commit and refuse to accept contradictory/missing evidence.

A **safety-critical decision** should fail closed when its input is missing or malformed. For minor convenience hooks, overly broad failure can strand sessions; classify severity rather than applying an undifferentiated fail-open or fail-closed policy. Never treat a shell-command regex as a sandbox: scripts, aliases, redirection, alternate tools and APIs can bypass it.

## Important caveat from actual community reports

Agent hooks are not infallible. The Anthropic issue tracker contains reports of `PreToolUse` exit-2 denials not reliably stopping Bash or other tool calls in certain versions/modes, including [#26923](https://github.com/anthropics/claude-code/issues/26923), [#36071](https://github.com/anthropics/claude-code/issues/36071) (headless), and [#80039](https://github.com/anthropics/claude-code/issues/80039) (Windows). These are **reported, version-specific behaviors**, not proof every current version fails.

For each client, test denial **inside the actual agent runtime** before trusting it:
1. Create a disposable isolated worktree with an active strict task contract.
2. Ask the agent to attempt an edit of a forbidden canary file, then a harmless but denied shell action; check the files and side effects *on disk*. Do not test with an actual destructive command.
3. Repeat interactively and headlessly, using the exact agent version and permissions intended for routine use.
4. Re-test after agent upgrades and hook edits. A passing unit test of the hook's parser is insufficient.
5. If a hook fails, remove permission to access sensitive resources using OS/filesystem/container/GitHub mechanisms. Required remote CI/rulesets remain the last gate.

## Recommended 4-layer implementation for this repository

### Layer A — execution boundary

Keep `scripts/pre_tool_guard.py` as an optional Claude Code convenience hook, with explicit project contracts and regression tests. Add a separate Codex/Cursor adapter using their supported event payloads, not one parser that silently ignores unknown tools. Run both through a sandbox or disposable worktree. **Do not mark a target project protected until its live deny-canary test passes.**

**Codex hook configuration shape (illustrative, requires a matching script):**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|apply_patch",
        "hooks": [
          {
            "type": "command",
            "command": "python3 scripts/codex_policy_hook.py",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

`scripts/codex_policy_hook.py` is **not** present yet; this fragment is a design reference, **not** an installable config. Codex documents deny via `hookSpecificOutput.hookEventName='PreToolUse'` and `permissionDecision='deny'`. Stop continuation uses `decision='block'` plus `reason`. Project hook registration requires trusting the current hook definitions in `/hooks`. See [Codex hook schema](https://learn.chatgpt.com/docs/hooks).

### Layer B — external task driver

Reuse `scripts/control_plane.py` as the **one** transition owner. Reuse `scripts/frontier.py` for authorized, dependency-aware eligible tasks, and `scripts/ai_native.py` for scoped execution, gates and independent model review. Do **not** introduce a second run-status engine under `scripts/ralph.py`.

Suggested operations:

```text
read canonical requirements/backlog and current evidence
   -> construct verified frontier snapshot
   -> control_plane decides CONTINUE_FRONTIER / HUMAN_HANDOFF / WAIT_EXTERNAL
   -> run one Executor task (bounded) in its own isolated worktree
   -> run gate commands and independent reviewer on exact source fingerprint
   -> control_plane decides TASK_VERIFIED / RETRY_EXECUTOR / NOT_VERIFIED
   -> on TASK_VERIFIED, reconcile canonical state and rediscover work
   -> terminate only if frontier exhausted AND termination gate passes
```

**Unimplemented:** actual automatic discovery from docs/bugs/capabilities; a runner that repeatedly launches eligible tasks; authenticated independent termination Decider. Avoid describing those as present.

### Layer C — evidence and review

Use an independently controlled requirements manifest, not one writable by the Executor. Every PASS must reference:
- requirement ID, minimum proof scope (unit, integration, e2e, device, visual, performance);
- actual run command, exit code, revision/tree fingerprint and artifact hash;
- actual terminal state for an E2E outcome, with natural termination where required;
- separate reviewer identity, reviewed revision and verdict.

Current `scripts/governance.py` provides some local checks, but self-asserted approval and local JSON records **cannot** establish genuine actor identity or real device provenance.

### Layer D — GitHub protection

A *working workflow file* is necessary but insufficient. Require a check in a GitHub ruleset. For this public repository, configure:

1. Open [GitHub repository Settings](https://github.com/asapacsin/ai-native-engineering/settings).
2. Select **Rules → Rulesets → New ruleset → New branch ruleset** (the sidebar may label it **Rulesets** under Code and automation).
3. Name `ai-native-main-verification`; select enforcement **Active**; target **Default branch** (`main`).
4. Enable **Require a pull request before merging** and **Require status checks to pass before merging**.
5. First ensure the workflow has actually run and published a check on a branch/PR; set the exact job check name `tests` from `.github/workflows/ci.yml`. A skipped workflow is not proof. If using merge queues, add `merge_group` event.
6. Optionally require a separate pull-request review and enable stale-approval dismissal; restrict bypasses and force-pushes as appropriate.
7. Attempt a deliberately failing PR check: merging must be refused even if the agent claims PASS.

Reference: [GitHub rulesets guide](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository) and [required status check troubleshooting](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks). Required checks generally must be observed from a recognized event and recent commit; choosing a non-existent check name can block every PR.

**Observed on 2026-10-22 through GitHub connector:** this repository returned `[]` for its rulesets, zero Actions runs, and a 403 for branch-protection inspection. The 403 means the integration cannot establish that legacy branch protection is absent. Do not claim server-side rules are active without checking GitHub UI/admin API.

## Recommendation: simplest architecture that achieves the goal

Do **not** adopt a full LangGraph/Temporal backend yet just to add deterministic gates to a single coding repo. A Python state machine (`control_plane.py`), process runner, task/evidence JSON and GitHub required check are smaller, simpler and cheaper. Move to durable workflow infrastructure only when you actually require distributed workers, days-long resumability, persistent queues or multi-host orchestration.

The highest-value next deliverable is **a tested end-to-end path**: one scoped task in a disposable worktree, one real Executor session, real automated gates, a separately invoked read-only Reviewer, a transition decision bound to the exact tip, and a PR that cannot merge when the required check fails. That demonstrates actual enforcement rather than accumulating another policy document.
