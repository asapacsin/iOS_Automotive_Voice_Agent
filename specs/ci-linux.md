# CI without an iOS build (Linux gates on GitHub Actions)

**Status:** PROPOSED (2026-11-11). Needs the owner's yes on §4 before it is built: it changes the owner rule of
2026-10-27 for Linux jobs only. Task T-000c.
**Depends on:** ios-architecture.md §13 (gates), implementation-plan.md §2, AGENTS.md owner rules,
`scripts/gates/run_all.sh`, `scripts/gates/check_runners.py`.

## 1. Why

Owner 2026-11-11: CI was turned off because it used more than the GitHub free allowance; asked whether some CI
can run without an iOS build. Today:
- **What used the minutes.** Until 5c3fbcd (2026-10-27) `ci.yml` had three macOS jobs (`core-macos`, `xcode`,
  `simulator`) and `ipa.yml` built the app on macOS. 5c3fbcd removed them, made every workflow
  `workflow_dispatch` only and added `check_runners.py`. Since then nothing runs unless the owner starts it.
- **What is left.** `ci.yml` has one Linux job (`core-linux`, `swift:6.0.3-noble`) running `run_all.sh`;
  `ai-native.yml` has one Linux job (controller tests, registry check). Neither has been started since.
- **What actually needs a Mac.** Only App/ and the iOS-only adapter packages (NovaAudio, NovaNavAmap,
  NovaPlatform, NovaWakeIflytek), swiftlint and the simulator. Everything else in `run_all.sh` runs on Linux:
  the Python gates and the build and unit tests of NovaCore, NovaRealtime and NovaServices (about 890 tests).
  Every PASS in STATUS.md since 2026-10-27 was produced by these Linux gates inside cloud sessions.
- **Version drift.** `ci.yml` pins Swift 6.0.3; the gates recorded in STATUS.md ran on Swift 6.1.2.

**Sources (GitHub docs, 2026-11-11).**
- Standard GitHub-hosted runners are free and unlimited in **public** repositories and do not reduce the account's
  included usage; larger runners are billed even there
  ([GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).
- In **private** repositories, standard Linux 2-core is $0.006 per minute and macOS is $0.062 per minute, about
  10× ([Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)).
- The GitHub API reports `asapacsin/ios_automotive_voice_agent` as public (`private: false`, checked 2026-11-11).

## 2. Rule in plain words

CI comes back for the Linux checks only. No macOS job, no app build, no simulator, no signing, no secrets.
A job may start by itself only while the repository is public, where standard Linux runners cost nothing; if the
repository becomes private the automatic jobs skip themselves and only an owner-started run spends minutes.
Every job has a hard time limit. A Mac is still needed for anything that builds the app; that stays with
Codemagic or a device build started by the owner, unchanged.

## 3. What is built

1. **Split the gate script.** New `scripts/gates/run_static.sh` runs the Python-only gates, in today's order:
   gate self-tests, `check_runners.py`, `check_imports.py`, `check_secrets.py`, `check_kws_tokens.py`,
   `ios_spec_check.py`, `spec_trace.py`. `run_all.sh` calls `run_static.sh` and then the Swift build and tests,
   so a local or cloud-session run checks exactly what it checks today. `spec_trace.py` stays last in the output
   so `gates: PASS` still means everything passed.
2. **`ci.yml`, two jobs, both `runs-on: ubuntu-24.04`** (a standard runner; no `-cores` or other larger label):
   - `static`: checkout, `run_static.sh`, then the two `ai-native.yml` steps (controller tests,
     `frontier.py check`, `ai_native.py validate`). No Swift. `timeout-minutes: 5`.
   - `swift`: container `swift:6.1.2-noble`, python3 installed, `run_all.sh`. `timeout-minutes: 25`.
     `actions/cache` keeps `Packages/*/.build`, keyed on the Swift version and a hash of every `Package.swift`
     and `Package.resolved`, so a run rebuilds only what changed.
   - `ai-native.yml` is deleted; its steps live in `static`.
3. **Triggers.**
   - `workflow_dispatch` (as today).
   - `push` on `main` and `claude/**`, and `pull_request` to `main`, both with `paths-ignore` for `**/*.xlsx`
     and `specs/progress/**` only (spec edits still run: `spec-trace` and `ios-spec-check` read the specs).
   - `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }`, so a new push to a branch stops
     the run for the previous push.
   - Never `schedule`, never `pull_request_target`.
4. **Public-only guard.** Each job has
   `if: github.event_name == 'workflow_dispatch' || github.event.repository.private == false`.
   A skipped job uses no runner time. An owner-started run still runs in a private repository.
5. **Least access.** `permissions: contents: read` at the top of the workflow. No `secrets.` reference and no
   `env` holding a credential anywhere in `.github/workflows/`.
6. **`check_runners.py` (the gate, extended).** It keeps failing on any macOS runner and on `schedule` or
   `pull_request_target`. A workflow with `push` or `pull_request` passes only if **every** job in it:
   - has `runs-on: ubuntu-24.04` or `ubuntu-latest` exactly (no larger runner, no matrix that adds another OS);
   - has `timeout-minutes` of 30 or less;
   - has the item 4 guard, word for word;
   - and the workflow has `permissions: contents: read` and no `secrets.`.
   A `workflow_dispatch`-only workflow needs only the macOS and `secrets.` checks, as today.
7. **Docs.** AGENTS.md owner rule text: "no macOS GitHub Actions runners; automatic triggers only for Linux jobs
   that pass `check_runners.py` (public repository, time limit); everything else is `workflow_dispatch` only."
   The comments at the top of `ci.yml` say the same. Done is unchanged: gates green (local, cloud session or CI)
   plus reviewer PASS; a CI run is extra evidence, not required.

## 4. Owner decision needed

The 2026-10-27 rule forbids every automatic trigger. This spec keeps the macOS ban and allows automatic runs
for Linux jobs while the repository is public. If the owner prefers to keep everything manual, build §3 items
1, 2, 5 and the Swift 6.1.2 pin only, skip items 3 (keep `workflow_dispatch` only), 4 and 6, and leave AGENTS.md
unchanged. A manual `static` run then costs about a minute in a private repository.

## 5. Not in scope

- Any macOS, Xcode, simulator, swiftlint or `.ipa` job (Codemagic and `codemagic.yaml` unchanged).
- Device rows: they stay NOT_VERIFIED until a device run.
- Starting a run: building this task does not start CI; the first run happens when the owner pushes or starts it.
- The known NoiseCorpus issue in NovaCore (an expected-failure marker; it does not fail `swift test`).

## 6. Acceptance

| # | Row | Check |
|---|---|---|
| 1 | `run_static.sh` runs the seven Python gates and exits non-zero if any fails; `run_all.sh` output still ends `gates: PASS` with the same checks as before | U (gate self-test in `scripts/gates/tests`), local run |
| 2 | `check_runners.py` fails a planted `runs-on: macos-15` in a dispatch-only workflow and in a push workflow | U |
| 3 | It fails a push workflow job without `timeout-minutes`, with `timeout-minutes: 45`, with `runs-on: ubuntu-latest-4-cores`, or without the item 4 guard | U |
| 4 | It fails `schedule`, `pull_request_target`, a missing `permissions: contents: read` in a push workflow, and any `secrets.` reference | U |
| 5 | It passes the new `ci.yml` and a dispatch-only Linux workflow | U |
| 6 | `ci.yml` uses `swift:6.1.2-noble`; `ai-native.yml` is gone and its three commands are in `static` | review |
| 7 | AGENTS.md and the `ci.yml` header carry the §3 item 7 wording | review |
| 8 | First real run after a push: `static` and `swift` green, `swift` under 25 min, a second push with no Swift change reuses the cache | O (owner pushes or starts it) NOT_VERIFIED |
| 9 | After a week of pushes, Settings → Billing shows no included Actions usage spent by this repository | O NOT_VERIFIED |

The gate rows are Python tests, so they are not in `specs/trace-ids.txt` (spec-trace reads Swift `@Test` names).
