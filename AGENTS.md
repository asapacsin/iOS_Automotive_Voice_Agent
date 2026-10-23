# NovaDriveIOS
- Specs live in specs/. Before a task, read specs/features/<feature>.md and only the contracts it
  lists. Do not read other features unless the task names them. Tasks: specs/implementation-plan.md.
- Never open the Android repository unless the feature file says "allowed Android lookup" for a
  specific symbol; request it with an EVIDENCE_REQUEST (specs/ai-agent-workflow.md) instead of browsing.
- Pure logic goes in Packages/NovaCore (no UIKit/AVFoundation). Vendor SDKs only in their adapter
  package (specs/ios-architecture.md §3.2); `scripts/gates/check_imports.py` enforces it.
- Product invariants I-1..I-14 (specs/product-spec.md) are code-enforced, never prompt-only.
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
