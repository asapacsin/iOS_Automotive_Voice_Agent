# Portable Stop-hook continuation

This is a port of the bounded Stop-hook continuation principle from
`Android_Automotive_Voice_Agent/.claude/hooks/keep-going.py`, adapted to the
AI-native repository's existing deterministic `control_plane.py` and `frontier.py`.
It does not copy Android's Gradle/APK/task-discovery assumptions.

## Enable in Claude Code

First create a real project work registry in the same schema as `examples/work.json`.
Only explicitly recorded work is authorized; the sample registry is a demonstration,
not an inferred production backlog. Run these from the AI-native repository root:

```bash
python3 scripts/frontier.py check --registry /path/to/project-work.json
export AI_NATIVE_CONTINUE_ENABLED=1
export AI_NATIVE_WORK_REGISTRY=/path/to/project-work.json
claude
```

PowerShell equivalents (in the repository root):

```powershell
python scripts/frontier.py check --registry C:\work\project-work.json
$env:AI_NATIVE_CONTINUE_ENABLED = '1'
$env:AI_NATIVE_WORK_REGISTRY = 'C:\work\project-work.json'
claude
```

The checked-in `.claude/settings.json` registers one ordered Stop entry point:
`.claude/hooks/ai-native-stop.py` performs enabled end-state review first, then
calls `.claude/hooks/keep-going.py` for enabled continuation. Two independent
Stop commands would risk a stale-review race. Continuation is off by default.
To disable it, unset the environment variable or set it to `0`.

## Deterministic case routing

| Observed state | Stop-hook behavior |
| --- | --- |
| An eligible autonomous task exists | Block Stop with its ID and next action |
| One task is blocked, another independent task is eligible | Continue only the eligible task |
| Same unfinished task repeats without registry progress | Stop after 3 blocks on the unchanged frontier |
| Too many continuation blocks across different tasks | Stop after 20 blocks in one Stop chain |
| All work finished with recorded evidence | Allow Stop |
| External-only work remains | Allow Stop; report blocker in handoff |
| Human-only work remains | Allow Stop; keep human work deferred and require normal human gate |
| Invalid/unknown registry or missing config | Allow Stop with diagnostic, never invent work |
| End-state review enabled but missing, failed, or stale | Allow Stop from this hook; existing review hook owns REWORK |

**Important:** The hook never executes a task, sets PASS, or invokes an LLM on its
own. It only supplies a bounded continuation instruction to the running Claude
session. After real verification, the executing agent must update the registry
status/evidence. A changed task contract or source invalidates previous review
proof. With `AI_NATIVE_STOP_ENABLED=1`, continuation additionally requires the
latest end-state review to be a current deterministic TASK_VERIFIED result.
The existing review logic remains the sole owner of REWORK blocking. Both
hooks are serialized by the same Stop entry point.

## What was intentionally not ported

The Android repo's `scripts/discover_work.py` scans Android-specific test outputs,
APK artifacts, SPEC tables and debt lists. This portable hook instead consumes a
validated project work registry. Automatic extraction from external project documents
still requires a project-specific discovery adapter that emits the same schema.
Neither a Stop hook nor local state files are a security boundary, and no
automatic model routing/independent termination Decider is added by this change.

Run `python3 -m unittest discover -s tests -v` to verify behavior.
