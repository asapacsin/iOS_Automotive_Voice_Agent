# NovaDriveIOS
- Specs live in specs/. Before a task, read the sections of specs/features/<feature>.md it names and only the contracts it
  lists. Do not read other features unless the task names them. Tasks: specs/implementation-plan.md.
- Read only the section a task names: `scripts/spec_section.py <feature>` lists sections with line ranges,
  `scripts/spec_section.py <feature> <§>` prints one (trip-plan.md is ~160 KB; §51 alone is ~19 KB).
  A Read of a file over 40 KB without offset is refused by `scripts/hooks/read_guard.py`.
- Token budget (specs/token-budget.md): build and fix in the main session; a subagent only for the required
  PASS review (`spec-reviewer`, high effort); re-checks after a fix at medium effort; parallel agents only when
  the owner asks; no `/goal` while the work waits on the owner; `/clear` between batches, not a new session.
- Never open the Android repository unless the feature file says "allowed Android lookup" for a
  specific symbol; request it with an EVIDENCE_REQUEST (specs/ai-agent-workflow.md) instead of browsing.
- Pure logic goes in Packages/NovaCore (no UIKit/AVFoundation). Vendor SDKs only in their adapter
  package (specs/ios-architecture.md §3.2); `scripts/gates/check_imports.py` enforces it.
- Product invariants I-1..I-14 (specs/product-spec.md) are code-enforced, never prompt-only.
- Owner rule (2026-11-11, replaces 2026-10-27; specs/ci-linux.md): no macOS GitHub Actions runners; automatic triggers
  only for Linux jobs that pass `scripts/gates/check_runners.py` (public repository, time limit); everything else is
  `workflow_dispatch` only. No app build, simulator or secrets in CI.
- Owner rule (2026-11-05), search prompt only (`QwenWebSearchClient` system text or its replacement): never
  invent wording or rules; copy a published vendor/community practice and cite it in the spec.
- Gates: `scripts/gates/run_all.sh`. Done = gates green + reviewer PASS. Device-only acceptance rows
  stay NOT_VERIFIED until a device run. Record results in specs/STATUS.md.

## AI-native control plane (tools/ai-native, copied from asapacsin/ai-native-engineering)
- Operating contract: tools/ai-native/AGENTS.md and tools/ai-native/docs/AI_BUILDER_BIBLE.md apply here.
- Work registry: specs/work.json (only recorded work is authorized). Check it with
  `python3 tools/ai-native/scripts/frontier.py next --registry specs/work.json`.
- The Stop hook in .claude/settings.json runs the bounded keep-going continuation over that registry
  (AI_NATIVE_CONTINUE_ENABLED=1). End-state review (AI_NATIVE_STOP_ENABLED) and the pre-tool guard
  (AI_NATIVE_GUARD_ENABLED, contract specs/contracts-ai/active.json) stay off until an external
  reviewer CLI is configured.
- A task moves to PASS in specs/work.json only with gate evidence plus an independent read-only review
  at high effort; the reviewer's verdict never overrides a failed gate.
- Owner rule (2026-11-13): preparing a phone test is Claude's job end to end: trigger the Codemagic build of the
  branch under test, get the IPA, and install it on the owner's iPhone as an **update** of the installed NovaDrive
  (same bundle id, keep its data and keys), never a delete-and-reinstall. Then hand over the checklist. Only ask the
  owner for what Claude cannot reach (a credential, or a computer connected to the phone). The steps are the
  `phone-test` skill (.claude/skills/phone-test/SKILL.md); fix it when a step is wrong so the next session knows.
