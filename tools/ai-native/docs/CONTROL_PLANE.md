# Deterministic control plane

## Purpose

The control plane is the single deterministic authority for decisions that can be expressed as rules. It must not call a model, shell command, network service or clock. Model output is treated as an input claim and checked against observed evidence.

Implementation: [scripts/control_plane.py](../scripts/control_plane.py). The module exposes pure functions for cycle, frontier and integration decisions; each decision has a canonical SHA-256 digest.

## Decision boundaries

| Decision function | Observed inputs | Example outputs |
|---|---|---|
| `decide_cycle(state)` | executor exit state, required gate results, gate/source fingerprint, reviewer process/verdict, reviewer independence, source and contract hashes, attempt/deadline budgets | `RETRY_EXECUTOR`, `WAIT_EXTERNAL`, `CONFIGURE_REVIEWER`, `REVIEW_REQUIRED`, `TASK_VERIFIED`, `STOP_NOT_VERIFIED`, escalation |
| `decide_frontier(work, ...)` | canonical work registry, dependency edges, status, owner, evidence, blocker, human-validation fields, discovery-pass fingerprint | `CONTINUE_FRONTIER`, `WAIT_EXTERNAL`, `DISCOVERY_REQUIRED`, `HUMAN_HANDOFF`, `STOP_COMPLETE` |
| `decide_integration(state)` | independently computed approval, scope, exact-tip review, required gate, evidence, source-cleanliness and completion predicates | `READY_TO_MERGE` or `NOT_ELIGIBLE` |

The functions return a structured result with rule version, action, reason codes, and `decision_sha256`. Use `verify_decision(record)` before accepting a saved decision.

## Core invariants

1. **No LLM self-approval.** The reviewer is a separate process; its verdict alone is not sufficient.
2. **No false green.** Required gate failure, missing evidence, blocked dependencies, or absent reviewer data cannot become PASS.
3. **Bind review to the exact input.** The reviewer must return the exact source fingerprint and task-contract hash from the review packet.
4. **Bind gates to the pre-test tree.** If a gate changes tracked or untracked source state, the evidence is rejected as stale.
5. **Bounded retries.** Retry is allowed only when an Executor is configured and the attempt budget remains. Exhaustion escalates instead of looping.
6. **No dependency-wide deadlock.** A blocked GPU or external-resource task blocks its dependants, not unrelated authorized tasks.
7. **Batch real human work.** A human handoff requires actionable instructions and two clean discovery passes against the same registry fingerprint.
8. **No automatic merge.** `TASK_VERIFIED` means the task passed its cycle. Merge eligibility is a separate deterministic decision and GitHub branch protection remains a required deployment control.

## Run it

From the repository root:

```bash
python3 -m unittest discover -s tests -v
python3 scripts/control_plane.py cycle --state examples/control-cycle-state.json --expect-action TASK_VERIFIED
python3 scripts/control_plane.py frontier --state examples/work.json --expect-action CONTINUE_FRONTIER
```

The example state is a deterministic policy fixture, not evidence that an external model, Android device, Aurel GPU pipeline, or manga rendering run occurred.

## Limits

- The work registry is still supplied by a project adapter; the core does not autonomously mine every spec, issue, test failure or design-basis document yet.
- The approver identity and the human clean-pass flag are local procedural attestations unless a protected CI service verifies them.
- A hash proves that a record matches its bytes; it does not prove a device, GPU, network service or human test actually ran. Domain-specific runners must produce trustworthy attestations.
- Publishing this code does not enable branch protection, install the hook in target projects, authenticate Codex, or configure production credentials.
- Hosted CI remains unverified until an actual GitHub Actions run appears and passes.
