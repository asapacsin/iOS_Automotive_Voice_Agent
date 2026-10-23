# AI-native practice coverage audit — 2026-10-21

**Verdict: INCOMPLETE.** The shared repository is an **Executor → deterministic gates → independent Reviewer starter**, not a faithful extraction of every engineering practice used in the source projects. Publishing 16 files and passing 18 starter tests did **not** establish feature parity.

This inventory compares:
- [Android Automotive Voice Agent](https://github.com/asapacsin/Android_Automotive_Voice_Agent) (`main`): governance, architecture, workflows, Android/device evidence, CI and autonomy.
- [Aurel game](https://github.com/asapacsin/aurel-game) (`main`): evidence registry, native/replay/neural scope, model routing and GPU blockers.
- [Edria manga](https://github.com/asapacsin/edria-manga) (`main`): locked sources, benchmark gates, per-asset provenance, recoverable checkpoints and approvals.
- Prior stated design requirement: **one vendor-neutral harness; thin tool/project adapters; separate governance from model choice**.

Meaning of status:
- **CORE**: present as runnable shared code or enforced by its tests *within the specified scope*, not proof of production integration.
- **PARTIAL**: represented as documentation, template, opt-in hook, or less strict code than the source.
- **MISSING**: no equivalent shared implementation.
- **ADAPTER**: deliberately project-specific; needs an adapter/contract, not a blind source-code copy.

| # | Practice actually used | Original source of truth | Shared coverage | What is still needed |
|---|---|---|---|---|
| 01 | Low-cost Executor by default; stronger independent Reviewer | Android `scripts/model_route.py`; Aurel `docs/AGENT_MODEL_ROUTING.md` | PARTIAL | Verified provider routing and cost-based selection rather than CLI model-name defaults |
| 02 | Task-specific Architect/Planner/Executor/Reviewer/Decider roles | Android `.claude/agents/`, `.cursor/agents/`; Aurel `.codex/agents/` | PARTIAL | Role interface + cross-client adapters; escalation hard-gate, terminal Decider |
| 03 | Task contracts with goal, acceptance, bounds and gate commands | Android `scripts/task_contract.py` | PARTIAL | Approved/forbidden path globs, base commit, architecture constraints and change-scope checks |
| 04 | Contract approved by non-Executor, hash-bound to exact version | Android `docs/AGENT_CONTRACT_WORKFLOW.md` | MISSING | Separate approval actor, immutable provenance and invalidate-on-edit rule |
| 05 | Isolated worktree/branch per implementation task | Android `scripts/new_worktree.sh`, `scripts/task_contract.py` | MISSING | Safe worktree creation, scoped checkout, dirty-tree protection and ownership |
| 06 | Deterministic end-state gate invocation | Android `scripts/harness_check.py`; Aurel `scripts/engineering.py` | CORE | `scripts/ai_native.py` runs user-defined commands; still needs project integration |
| 07 | Commit + tracked/untracked source fingerprint | Android `scripts/test_matrix.py`; Aurel `verification/gates.json` | CORE | Shared source fingerprint implemented; add evidence binding for outputs/requirements |
| 08 | Independent Reviewer, review of actual diff (not writer summary) | Android `agent/REVIEWER.md`, `scripts/review_packet.py` | PARTIAL | `scripts/codex_bridge.py` is executable/configurable; independent LIVE reviewer use not yet verified; no separate identity proof |
| 09 | Review-before-merge and fail-closed integration eligibility | Android `scripts/delegation_check.py`, `.claude/hooks/require-review-before-merge.py` | MISSING | Approvals + exact-tip verdict + verified checks + scope all required before merge |
| 10 | Bounded correction iterations, recovery/stop on failure | Android agent handoffs, Aurel routing | CORE | `scripts/ai_native.py` has retry/time cap; no token-dollar accounting or unresolved-work scheduling |
| 11 | Autonomous work discovery from canonical sources | Android `scripts/discover_work.py` | MISSING | Eligible frontier from failing tests, specs, debt, milestones, capability gaps and stale state |
| 12 | Dependency propagation, unblock signals, blocked-only branches | Android `scripts/discover_work.py`; Aurel `scripts/engineering.py next` | MISSING | Dependency DAG, actionable/blocked frontier, automatic unblock and next task |
| 13 | Keep working past a completed task while authorized frontier exists | Android `.claude/hooks/keep-going.py`, `harness/CONSTITUTION.md` rule 12 | PARTIAL | Current hook checks *one task*, not autonomous frontier exhaustion; bound no-progress detection |
| 14 | Independent, fail-closed review of agent termination | Android `scripts/model_route.py` terminate-request/review/consume | MISSING | Terminal-state fingerprint + Decider check before stopping; no agent self-approval |
| 15 | Human-only actions deferred and batched at a phase boundary | Android `scripts/test_matrix.py`, `harness/PHASES.md` | MISSING | HUMAN_REQUIRED owner/reason/procedure/expected_return, quantification and two clean discovery passes |
| 16 | Separate IMPLEMENTED → WIRED → VERIFIED → REGRESSION → ARTIFACT → RECONCILED → COMPLETE | Android `harness/CONSTITUTION.md` rule 13 | MISSING | Portable progress state model and checks; avoid elevating implemented to complete |
| 17 | Proof levels, terminal E2E success, no scope laundering | Android `scripts/acceptance.py`, `scripts/test_matrix.py`; Aurel `verification/gates.json` | PARTIAL | Gate level labels exist but no requirement-owned min scope or terminal/artifact evidence validator |
| 18 | Persistent evidence registry, dependencies, provenance, honest NOT_RUN/PASS | Aurel `verification/gates.json`, `scripts/engineering.py` | MISSING | Cross-project gate registry with SHA/ref/result/dependency validation |
| 19 | Research/upstream/design-basis before major implementation | Android `scripts/design_basis.py`, `harness/design_basis.yaml` | PARTIAL | Principle in AGENTS/Bible; no deterministic discovery or design-basis approval/check |
| 20 | Regression CI: trustworthy results and no false green | Android `scripts/ci_verdict.py`, `docs/CI.md` | PARTIAL | Shared CI only runs controller tests; no required-id manifest, malformed/missing result fail-closed, real-project CI records |
| 21 | Emulator, ADB, live network, navigation, speech and hardware evidence | Android `.github/workflows/device-checks.yml`, `voice-checks.yml` | ADAPTER | Use real Android CI runner/verdict/artifact integration; `adapters/android.json` alone doesn't provide it |
| 22 | GPU/VRAM/latency/native replay and neural world-model evidence | Aurel `docs/ENGINEERING_WORKFLOW.md`, `verification/gates.json` | ADAPTER | Native/GPU adapter validating real artifacts; CLI CTest must not substitute for live neural verification |
| 23 | Persistent canonical state, generated state and reproducible handoff | Android `scripts/collect_state.py`; Aurel `docs/PROJECT_STATE.md` | PARTIAL | Portable canonical state reconciliation, compact handoff, no shadow ledgers |
| 24 | Reusable SKILL.md procedures, benchmarked skill evaluations | Android `.claude/skills/`, `scripts/skill_metrics.py` | MISSING | Portable skills and eval harness with client-specific adapters |
| 25 | Architecture/owner drift, secret scans, source-code budgets, pruning | Android `docs/AGENT_MAINTENANCE.md`, `behavior-test` | PARTIAL | Maintenance audits, source-based checks, test invalidation and deletion policy |
| 26 | Capability registry and source-owned acceptance requirements | Android `config/capabilities.yaml`, `scripts/test_matrix.py` | MISSING | Capability truth and required-scope contract, cross-reference with acceptance |
| 27 | Canon/source provenance, version locks and approvals | Edria `AGENTS.md`, `canon/canon-lock.json` | ADAPTER | Generic immutable source-input/version provenance + domain-specific authority policy |
| 28 | Save/push/checkpoint and verify remote SHA before further generation | Edria `AGENTS.md`, `LOCAL_AGENT_HANDOFF.md` | MISSING | Safe progress checkpoint + remote ref verification + takeover recovery; preserve uncommitted work |
| 29 | Visual benchmark and human review gate before large generation | Edria `manga/tools/benchmark_gate.py` | ADAPTER | Portable benchmark/review lifecycle and image evidence hooks |
| 30 | Experimental research reproducibility/held-out evaluation/UQ | Shared research plans, domain-specific materials/ML experiments | MISSING | Research adapter for seed/splits/datasets/artifacts/metrics, leakage guard, independent review |

## Implementation update — public repository, 2026-10-22

New, tested local components (see [enforcement guide](ENFORCEMENT.md)):

- `scripts/governance.py`: approved task-contract hash; self-asserted non-Executor approver; recursive path allow/deny including default protected governance paths; current-worktree review fingerprint; exact-tip PASS and optional independent requirements scope check, local SHA-256 terminal traces with naturally-ended terminal state and fingerprint binding. **This is not branch protection, authenticated role separation or hardware attestation.**
- `scripts/frontier.py`: dependency/cycle validation, ranked autonomous task frontier, blocker propagation, HUMAN_REQUIRED batch, two self-attested clean-pass human gate. **It does not automatically discover tasks from arbitrary existing documents or invoke agents.**
- `scripts/ai_native.py`: each verdict now binds to a task contract hash as well as source snapshot; previous external executor/reviewer loop preserved.
- `scripts/pre_tool_guard.py` + `.claude/settings.json`: opt-in PreToolUse checks for file-tool path allow/deny and common destructive shell commands. The guard requires `AI_NATIVE_GUARD_ENABLED=1` and a task contract with `approved_paths`; it is defense-in-depth, **not** an OS sandbox and not automatically active for Codex/Cursor.
- `tests/test_governance.py` and `tests/test_frontier.py` cover unauthorized changes, stale review, altered contract, scope laundering, blocked-independent work, cycle rejection and batching. Nine focused pre-tool guard tests were added and passed in an isolated test harness; the full repository test suite and GitHub Actions run were not verified during this update.
- `examples/work.json`, `examples/requirements.json` and CI syntax/registry checks.

Remaining material gaps: real required GitHub branch rules, immutable/protected approval records and authenticated separation, non-claim-based E2E artifact truth, automatic discovery from specs/debt/capabilities, unattended termination Decider, actual model/cost measurement, source-project opt-in integration and device/GPU/visual adapters. The original matrix below reflects **baseline coverage before this implementation update**; this section is the latest delta, not blanket parity.

## Important safety and correctness gaps

1. The shared controller presently accepts a reviewer PASS for passing *declared* gates, even if the task omitted a required device or terminal-outcome gate. **Required scope must be owned by an independent requirement registry**, not just the Executor's contract.
2. Local approved-path checks now exist in `scripts/governance.py` and the optional PreToolUse guard. They are **not** a full sandbox: shell scripts/redirection or other tool APIs can still modify out-of-scope files, and required CI/branch protection is not installed automatically.
3. The controller does not inspect a durable candidate backlog or dependency graph when deciding to stop. Its bounded retry loop is **not** Android's autonomous continuation engine.
4. Calling a read-only Codex sandbox is an *invocation configuration*, not proof that an independent model ran, that the intended model ID is available, or that an external reviewer actually examined the right artifacts. Verify the actual session and result.
5. No shared branch protection or exact-tip merge gate has been installed in Android, Aurel or Edria by publishing this repo; those projects must opt in and validate their own workflows.
6. Some practices are *deliberately application-specific*. Copying the Android TEST_MATRIX or Edria canon into the shared core would violate the design goal. Extract the **protocol** and keep their providers/adapters local.

## Migration order (dependency-aware)

**P0 — truthful completion and safety before scale**
- Requirement-owned acceptance scope, mandatory artifact provenance and exact-tip evidence bind (rows 16–18, 26).
- Approved immutable task contracts, branch/worktree scope guard, protected files and review-before-merge eligibility (rows 03–05, 09).
- Real CI/verdict integration; fail closed on missing required results (rows 20–22).

**P1 — autonomous multi-task work**
- Canonical-state discovery and dependency/blocked frontier with independent clean-pass checks (rows 11–15, 23).
- Actual task/termination Decider invocation with bounded no-progress behavior; no self-authorization (rows 02, 13, 14).
- Cost-aware model routing and measured `cost / accepted task`, wall time, human interventions, regression incidence (rows 01, 10).

**P2 — portable ecosystem and specialized production**
- Thin Claude/Codex/Cursor adapters, skills and evals; design-basis + best-practice lookup gate (rows 19, 24, 25).
- Edria source locks and progressive remote checkpoints; research reproducibility/benchmark adapters (rows 27–30).
- Integration tests **inside** all source projects; compare resulting behavior, not script line counts.

## Definition of completion for this migration

Do not claim “all practices included” unless every row is CORE or a **tested ADAPTER** with a specific source-project integration and evidence; cross-client selection, CI and human/device/GPU evidence have actually been exercised on the targeted runtimes; unresolved exceptions are explicitly accepted. Local Python tests alone cannot certify the claim.

**Current result:** inventory complete for the reviewed files/known decisions; implementation migration **NOT_COMPLETE**. This is an engineering audit, not evidence of production integration.


## Deterministic core update — 2026-10-22

The shared repository now includes a pure decision engine at scripts/control_plane.py and behavioral tests at tests/test_control_plane.py. The engine itself has no LLM calls, subprocesses, network access or clock reads. ai_native.py delegates bounded retry/stop decisions to it; frontier.py delegates dependency scheduling and human handoff decisions; governance.py delegates final merge-eligibility logic. Review results now bind to both the source fingerprint and contract hash, and verification gate runs bind to the source fingerprint captured before tests.

The pre-tool scope guard at scripts/pre_tool_guard.py is also present for Claude Code. It is deterministic but only covers its configured hook boundary and listed tool types; it is not an OS sandbox. The current core is more deterministic, but complete source-project parity is still NOT_VERIFIED until the test suite runs in CI and the real project adapters, required branch rules, model sessions, device/GPU/visual evidence and recovery workflows are exercised.
