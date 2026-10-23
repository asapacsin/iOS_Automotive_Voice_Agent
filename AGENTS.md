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
