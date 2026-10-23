# AI-agent workflow for the iOS repository (requirements, not implemented here)

Mirrors the control plane already in this repo (`tools/ai-native/`, copied from the owner's
ai-native-engineering repo): Executor → deterministic gates → independent Reviewer → PASS / REWORK /
BLOCKED / NOT_VERIFIED, with bounded retries.

## Minimal root AGENTS.md for the iOS repo (proposed text)

```
# NovaDriveIOS
- Specs live in specs/. Before a task, read specs/features/<feature>.md and only the contracts it
  lists. Do not read other features unless the task names them.
- Never open the Android repository unless the feature file says "allowed Android lookup" for a
  specific symbol; request it with an EVIDENCE_REQUEST (below) instead of browsing.
- Pure logic goes in Packages/NovaCore (no UIKit/AVFoundation). Vendor SDKs only in their adapter package.
- Product invariants I-1..I-14 (specs/product-spec.md) are code-enforced, never prompt-only.
- Done = gates green + reviewer PASS. Device-only acceptance rows stay NOT_VERIFIED until a device run.
```

## Task packet (input to the Executor)

`TASK_ID, FEATURE (F-xx), SPEC_VERSION, ACCEPTANCE (copied rows from §10), OWNED_PATHS, GATES (commands),
BUDGET (max attempts 3, max 40 min, token cap)`. The packet is the contract hash bound by the control plane.

## Context retrieval policy (dependency-based)

1. Feature file. 2. Contracts in its "Depends on". 3. Feature files named in "Depends on" — section 10
only. 4. Android evidence only via EVIDENCE_REQUEST. Nothing else by default.

## Requesting missing Android evidence

```
EVIDENCE_REQUEST
feature: F-11
question: exact enum of ClimateToolHandler.ACTIONS
android_ref: A/vehicle/ClimateToolHandler.kt:102
```
A human or a read-only helper answers with the excerpt and the Android commit; the answer is appended
to the feature file (bumping its version) so the next agent does not ask again.

## Deterministic gates (end-state hook)

| Gate | Command (proposed) | Level |
|---|---|---|
| build | `swift build` for packages; `xcodebuild build` for the app | static |
| unit | `swift test` (NovaCore and fixtures) | unit |
| contract | replay tests over `Tests/fixtures/gemini/*.jsonl` and `fixtures/amap/*.json` | contract |
| lint | `swiftlint --strict` | static |
| secrets | scan for key patterns in source and Info.plist | static |
| spec-trace | every acceptance row in the task has a test referencing its ID | static |

Simulator UI tests and device tests are separate, opt-in gates; a reviewer may not PASS a row whose
level is D or M without attached evidence (video/log) — verdict NOT_VERIFIED.

## Reviewer evidence required

| Verdict | Requires |
|---|---|
| PASS | diff within OWNED_PATHS; all required gates PASS on the reviewed fingerprint; each acceptance row mapped to a passing test or attached device evidence; no invariant weakened |
| REWORK | at least one concrete finding with file:line and the failed acceptance row |
| BLOCKED | an external dependency (key, entitlement, SDK answer, device) named |
| NOT_VERIFIED | evidence missing or stale (fingerprint/spec version mismatch, device row without evidence) |

The Reviewer gets: the diff, the feature file, the listed contracts, gate results. Not the Android repo.

## REWORK and budgets

REWORK produces one narrowly scoped corrective packet per finding (same feature, same owned paths).
Max 3 attempts per task, 40 minutes, token cap per role; on exhaustion → escalate to the owner with
the latest verdict. The control plane, not the model, decides retry vs stop.

## Recording results

After each task: append to `specs/STATUS.md` the feature ID, acceptance rows now PASS (with level),
NOT_VERIFIED rows and why, and new open questions. The next task reads STATUS.md for its feature only.
