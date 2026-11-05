# Resource-aware execution and remote completion

This guide applies to a **host-run supervisor** (Codex CLI/Claude Code/CI or a
trusted runner). Merely linking this repository from a Codex Cloud prompt does
not install a supervisor, Stop hook, task registry, or persistent environment.

## Rule: one unavailable resource cannot terminate unrelated work

Define independent tasks before running; start from
[`examples/work_resource_aware.json`](../examples/work_resource_aware.json),
then replace each relative `contract_path` with an actual approved task
contract (the example paths are placeholders). For example, a CPU/FFmpeg integration
test should **not** depend on a GPU inference benchmark. Put required resources
on the *individual work item*, never on the whole project:

```json
{
  "id": "gpu-e2e", "owner": "AUTONOMOUS", "status": "NOT_RUN",
  "action": "Verify actual model inference on an approved GPU runner",
  "depends_on": ["cpu-pipeline"],
  "requires": ["nvidia_gpu", "model_weights"],
  "contract_path": "gpu-e2e-contract.json"
}
```

When the trusted runner reports either capability unavailable, the supervisor
marks only `gpu-e2e` as `BLOCKED_EXTERNAL` with the missing capability names.
It continues all other authorized tasks with satisfied dependencies. `WAIT_EXTERNAL`
is an **incomplete handoff**, not a success or a reason to discard CPU results.
When those capabilities later become available, restart the supervisor with a
fresh capability snapshot: it requeues *only* capability-generated blockers.
Human approvals, credentials, reviews and other blockers are never silently
cleared by a GPU becoming available.

## Operational setup (Linux/macOS; Windows uses `python` instead of `python3`)

1. Start with a project that already has a Git initial commit. The current
   source-fingerprint controller requires `git rev-parse HEAD`. For a new empty
   repository, bootstrap its instructions, `.gitignore` and minimal files and
   commit those before starting the controller. This is a separate, authorized
   Git operation; the supervisor does not invent an initial commit.
2. Place a reviewed task contract for **each autonomous work item** under a
   trusted location outside the Executor's write scope. Create the mutable
   `work.json` registry and capability snapshot outside the Git tree or under
   the target repo's **gitignored** `.ai-native/` directory. Do not run the
   illustrative `examples/work.json` unchanged: it lacks `contract_path`.
3. Probe *observed* resources; specify a weight file only when its download and
   use have been separately approved:

   ```sh
   python3 scripts/capabilities.py --output /path/to/project/.ai-native/capabilities.json
   # Optional after approved weights are installed:
   python3 scripts/capabilities.py --weights-file /approved/model.onnx \
     --output /path/to/project/.ai-native/capabilities.json
   ```

4. Configure real authenticated `AI_NATIVE_EXECUTOR_CMD` and
   `AI_NATIVE_REVIEWER_CMD` as in [INTEGRATION.md](INTEGRATION.md). Then run:

   ```sh
   python3 scripts/supervisor.py --repo /path/to/project \
     --registry /path/to/project/.ai-native/work.json \
     --capabilities /path/to/project/.ai-native/capabilities.json \
     --require-remote --delivery-remote origin \
     --max-tasks 10 --max-seconds 1800
   ```

5. The Executor changes only approved task files. A trusted publication path
   commits changes **before** the final exact-tip checks/review, then pushes
   the reviewed SHA to the authorized branch. `--require-remote` checks for a
   clean worktree and an exact remote-branch SHA match; it does not push or
   override protected branches. If the branch or permission is unavailable,
   the task is `BLOCKED_EXTERNAL` with `blocker_kind=delivery`, not `PASS`.
   On the next supervisor invocation a completed push can be recognized if
   the independently reviewed source fingerprint still matches exactly.

## Mandatory stop audit

- An Executor ending its process is **not** a terminal authorization.
- Continue while `decide_frontier` reports `CONTINUE_FRONTIER` and a bounded
  authorized autonomous task remains, including CPU work unrelated to the GPU.
- Do not claim a full project `COMPLETE` while required GPU/device evidence is
  blocked, while the source is dirty, or while the remote delivery gate fails.
- Preserve the checkpoint and report the exact blocked task, missing resource,
  remaining independent tasks, and next permitted action.
- Once a genuine time/attempt/cost bound is hit, return `BOUND_REACHED` rather
  than silently restarting forever. The current supervisor still treats an
  interrupted, unverified `RUNNING` task as an external diagnostic blocker;
  automatically restarting such a task would need a separately reviewed,
  idempotency-safe recovery policy.

## Verification

`python3 -m unittest discover -s tests -v` includes a fake agent/FFmpeg-free
integration scenario in which GPU and weights are absent but independent CPU
work completes, plus Git tests with a local bare remote. These unit tests
**do not prove** that a Codex Cloud task installed this runner, a real GPU
processed a model, or a protected GitHub branch accepted a push.
