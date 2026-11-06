# AI-Native Engineering — Next Steps Roadmap

**Updated:** 2026-10-23  
**Purpose:** turn this repository into a reliable, reusable engineering control plane for multiple projects—not a growing collection of prompts and architecture ideas.

## Executive decision

**Do not start another architecture rewrite.** Stabilize the current runtime, prove its real execution path, then close the highest-value portability gaps. Work in small, independently verifiable PRs.

The intended loop is:

1. Explicit, approved task contract
2. Isolated Executor implementation
3. Deterministic acceptance gates
4. Independent Reviewer tied to the exact source and contract fingerprints
5. Bounded recovery or explicit human handoff
6. Evidence-backed task status and, separately, project-release eligibility

A model saying it is done is not completion evidence. A passing controller test is not proof that a real provider or product runtime was exercised.

## Repository state at this roadmap's creation

- [PR #1 — Port Android bounded hook cycle](https://github.com/asapacsin/ai-native-engineering/pull/1) is merged into `main`.
- [PR #2 — Harden runtime and add verified task supervisor](https://github.com/asapacsin/ai-native-engineering/pull/2) is open. It adds subprocess environment scoping, log redaction, task-versus-release eligibility, bounded supervision/checkpoints, and regression tests.
- [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) defines controller tests, Python compilation, frontier/control-plane examples, and contract validation. Confirm the actual run and required checks on GitHub; a workflow file alone does not prove a successful run or protect `main`.
- [Practice coverage audit](PRACTICE_COVERAGE.md) records important remaining gaps. Reconcile that audit and README claims after PR #2 lands so documentation reflects the actual merged implementation.

## Phase 0 — Finish the current runtime hardening

**Priority: immediate.** Treat PR #2 as the current integration candidate; avoid piling unrelated features into it.

### Actions

- [ ] Review all changed files in [PR #2](https://github.com/asapacsin/ai-native-engineering/pull/2), especially subprocess environment construction, redaction, supervisor locking/recovery, mutable registry validation, and release evidence.
- [ ] Confirm the PR's GitHub Actions checks actually ran and passed. If not, diagnose the workflow rather than inferring success from local tests.
- [ ] Run the documented local verification on the PR branch:
  ```bash
  python3 -m unittest discover -s tests -v
  python3 -m compileall -q scripts tests
  python3 scripts/ai_native.py validate --contract examples/contract.json
  python3 scripts/frontier.py check --registry examples/work.json
  ```
- [ ] Check that the regression tests cover malformed/stale reviewer evidence, failed required gates, credential redaction, registry races, lock recovery, and interrupted tasks. Add a focused test for any uncovered failure that could produce a false PASS or unsafe concurrent run.
- [ ] Keep the distinction explicit: test-double E2E proves the controller protocol; it does **not** certify a real authenticated Executor/Reviewer, Android device, live navigation/audio, or GPU workload.
- [ ] After merge, update the coverage audit and README to distinguish what is now implemented, what is unit-tested, and what has been proven with real integrations.

### Exit criteria

- Required CI checks pass on the exact PR commit.
- No known false-PASS path or unbounded retry/lock behavior remains in the reviewed scope.
- The documentation makes no stronger claim than the evidence supports.

## Phase 1 — Enforce repository-level merge safety

**Priority: high.** Local governance code is not the same as GitHub enforcement.

- [ ] Configure a GitHub ruleset or branch protection for `main`.
- [ ] Require the relevant CI status check(s) and prevent accidental bypass where practical.
- [ ] Document who may approve changes to governance, acceptance rules, and protected paths.
- [ ] Verify the rule by opening a small test PR and confirming that a failing or missing required check prevents merge.

### Exit criteria

A local PASS cannot silently substitute for hosted CI or repository review policy; enforcement is verified through a real PR.

## Phase 2 — Prove one real end-to-end agent cycle

**Priority: high.** Do this in a disposable branch/worktree with a low-risk task before enabling long autonomous runs.

- [ ] Configure actual authenticated Executor and separate read-only Reviewer CLI commands.
- [ ] Run one tiny task with an observable acceptance criterion and deterministic gate.
- [ ] Verify the actual selected model/effort from provider/session evidence rather than assuming a role label changes the provider.
- [ ] Inspect the generated contract, source fingerprint, gate output, review packet/result, and final control-plane decision.
- [ ] Deliberately induce one gate failure and one stale/malformed reviewer result; confirm the run does not report PASS.
- [ ] Record provider/model, task, elapsed time, retries, token/cost data when available, and what was not tested.

### Exit criteria

One successful live cycle and negative failure-path checks are reproducible. Keep this result separate from test-double coverage.

## Phase 3 — Validate portability on real projects

Use existing adapters; do not copy project-specific business logic into the shared controller.

### Android voice agent

- [ ] Run the shared cycle on a small, scoped Android task.
- [ ] Distinguish static/unit/JVM checks from emulator, physical-device, microphone, network, navigation, and interruption tests.
- [ ] Require device evidence for changes whose acceptance depends on live audio or vehicle/navigation behavior.

### Aurel game

- [ ] Run the shared cycle on a small, scoped game task.
- [ ] Distinguish reference/native tests from real renderer, GPU/VRAM, frame-time, visual quality, and artifact evidence.
- [ ] Do not mark neural or GPU acceptance PASS based on CLI/reference tests alone.

### Exit criteria

At least two different project types use the same core contract → gates → independent review → evidence protocol, while their domain-specific checks remain in adapters.

## Phase 4 — Close the highest-value workflow gaps

Build these in separate PRs, ordered by risk reduction and reuse:

1. **Canonical task discovery:** derive candidate work from named, trusted project sources (for example test failures, `OPEN_PROBLEMS.md`, requirements, and stale evidence). Each source adapter must preserve provenance and produce a reviewable candidate; never let the model invent an unrestricted backlog.
2. **Task isolation and ownership:** create/reuse a dedicated worktree or branch per task, detect dirty/conflicting work, and protect source-of-truth files.
3. **Explicit lifecycle and reconciliation:** track `IMPLEMENTED → WIRED → VERIFIED → REGRESSION → ARTIFACT → RECONCILED → COMPLETE`. Require evidence for each transition instead of equating implementation with completion.
4. **Terminal-state review and human handoff:** independently verify that no authorized work remains, distinguish blocked/external/human-only actions, and batch human decisions at a clear boundary.
5. **Evidence registry:** bind each result to requirement ID, source fingerprint, contract hash, artifact path and SHA-256, verification scope, and freshness. A source change invalidates stale evidence.
6. **Provider/model routing:** route by task complexity and observed quality/cost, and escalate only on defined uncertainty or failure. Do not add model tiers without measuring whether they improve outcomes.

### Exit criteria

Every added feature has a failure-path test, a stated security boundary, and a clear distinction between local enforcement and hosted/provider enforcement.

## Phase 5 — Measure whether the system is actually better

Establish a baseline before tuning prompts or adding agents.

Track per task:

- verified completion rate and false-PASS rate;
- required-gate failures and stale-evidence rejections;
- retries, elapsed time, and human interventions;
- token/API cost per verified task, where measurable;
- blocked tasks by cause and recovery success;
- live integration coverage versus test-double-only coverage.

Compare the same representative task set before and after a workflow change. Optimize **cost per correctly verified outcome**, not raw token price or number of agents.

## Operating rules

- One independently reviewable PR per major capability; do not bundle discovery, provider routing, security, and project adapters into one rewrite.
- Prefer deterministic code for state, limits, hashes, evidence validation, and routing decisions; use models for implementation, analysis, and review.
- Keep Executor and Reviewer permissions genuinely separate where possible. A read-only prompt alone is not a security boundary.
- Use bounded task/time budgets, explicit escalation conditions, and fail-closed behavior for missing or stale evidence.
- Preserve project-specific acceptance logic in adapters; keep the shared engine small and vendor-neutral.
- Do not claim a feature is production-ready until its relevant real integration has been exercised.

## Current implementation checkpoint

- [x] PR #2 merged: bounded external supervision, role-scoped subprocess environments, task-versus-release decisions, and task-bound release evidence.
- [x] Release evidence now binds the registry task ID and contract hash to the exact reviewed report path/hash and current source fingerprint.
- [x] Secret values passed as separate CLI arguments are redacted from saved command logs.
- [x] First source-backed discovery adapter implemented: explicit Markdown/text checklists produce deterministic, provenance-bound candidates. Candidates are not automatically approved or executed.
- [ ] Run the repository's full test suite in a real runner. At this checkpoint GitHub reports no Actions runs or commit status checks for the PR head, so hosted CI execution has not been confirmed.
- [ ] Configure and verify hosted branch protection/rulesets. The local governance code is not a substitute.
- [ ] Run a real authenticated Executor/Reviewer smoke test in a disposable target worktree; then test the Android and Aurel adapters at their relevant runtime/evidence levels.

## Next concrete action

**Restore verifiable CI first:** enable/confirm GitHub Actions for this repository and require the existing controller test workflow on `main`. Then run the live authenticated smoke test. After that, extend source-backed discovery to test failures, requirements/specifications, and stale evidence, with an explicit human-review step before candidates can enter the executable frontier. Continue with isolated worktrees and evidence-backed lifecycle transitions in separate PRs.
