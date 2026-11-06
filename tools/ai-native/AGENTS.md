# AI-native agent operating contract

1. **Executor-first**: default to a capable low-cost executor for routine scoped tasks. Do not spin up Architect, Planner, or Reviewer before they are needed. Pick actual model in the external agent client; this repo cannot override provider entitlement.
2. First inspect the existing owner, source, ADR/spec, state, git status, and current acceptance. Research upstream documentation/community solutions before inventing new infrastructure.
3. Author a small JSON task contract with `goal`, `acceptance`, `boundaries`, exact gate commands, time limits, and `task_id`.
4. Delegate implementation to the Executor in an isolated worktree/branch when useful. Never weaken tests or create parallel implementation owners to get green checks.
5. On executor end, run `scripts/ai_native.py cycle`: run deterministic gates, capture commit + dirty diff/untracked fingerprint, then call an **independent read-only** Reviewer through an explicitly configured external command.
6. Verdicts: `PASS` (acceptance evidence and independent review), `REWORK` (targeted fixes), `BLOCKED` (named missing dependency), `NOT_VERIFIED` (cannot support completion claim). Reviewer's words alone never override a failed required gate.
7. At most 3 attempts and a defined time/cost budget. Escalate ambiguous architecture, two failed attempts, invariant conflict, or genuinely expensive experiments to Architect; do not routinely send trivial work to expensive models.
8. Continue only authorized independent tasks. Stop on truly human-only actions, credentials or irreversible decisions; record and batch human requests rather than asking for every routine next step.
9. Results must bind to actual source revision/worktree fingerprint. Compile != runtime; JVM != device; offline model clip != live performance. Record evidence level and what was NOT verified.
10. No secrets in reports, logs, commits, agent prompts or model inputs. Never claim this skeleton has called a real LLM without an explicitly configured reviewer/executor CLI.

Canonical method: [`docs/AI_BUILDER_BIBLE.md`](docs/AI_BUILDER_BIBLE.md).

## Governance and continuation entry points

- `python3 scripts/governance.py scope --repo <target> --contract <contract>` — reject out-of-scope and protected edits.
- `python3 scripts/governance.py eligible --repo <target> --contract <contract> --requirements <requirements.json>` — check current commit, independent approval and reviewer PASS. Run in CI before merge.
- `python3 scripts/frontier.py next --registry <work.json>` — discover authorized independent tasks; never invent a backlog item.
- `python3 scripts/frontier.py human-packet --registry <work.json>` — batch real human-only work, not ordinary emulator automation.
- Use separate approvals and required CI/branch rules; local role names and hooks are not security boundaries. See `docs/ENFORCEMENT.md`.


## Deterministic control plane is authoritative

- Use scripts/control_plane.py as the single pure decision engine for retry/stop, dependency-frontier continuation, human handoff, and merge eligibility.
- Do not let an Executor, Reviewer, prompt, or test summary override a control-plane decision. Invalid, stale, missing, or lower-scope evidence must fail closed.
- The control plane performs no model/network/shell calls; adapters supply observed state. Keep model routing and domain-specific device/GPU/visual proof in adapters.
- A successful task review is not merge authorization. Use scripts/governance.py and required CI/branch rules; local approval strings are procedural, not authenticated security boundaries.

## Resource-aware environment and termination

- Split independent CPU/offline checks from GPU, model-weight, device and external-service work in an explicit dependency frontier. Mark a resource as `requires` on its individual task; one missing GPU or model must **never** end unrelated authorized work.
- At the start of each supervised run use a runner-owned capability snapshot (see `scripts/capabilities.py`); missing capabilities block only dependent tasks, and re-probe before resuming on a different machine. Never download weights, acquire credentials, or rent GPU resources without the required authority.
- On every Executor exit, let the external supervisor recompute the frontier. Continue independent tasks while `CONTINUE_FRONTIER` is available within budget. Return `WAIT_EXTERNAL` with exact blocked items when only external work remains; do not call that project `COMPLETE`.
- For remotely delivered code tasks use `scripts/supervisor.py --require-remote` and verify the reviewed local commit is clean and matches the authorized remote branch. A local PASS without remote delivery is not successful delivery. Never force-push, bypass protections, or self-approve a merge.
- Instructions alone cannot enforce this on a Codex Cloud task. The host must actually run the supervisor and maintain the trusted registry and capability snapshot. See [`docs/ENVIRONMENT_CONTINUATION.md`](docs/ENVIRONMENT_CONTINUATION.md).
