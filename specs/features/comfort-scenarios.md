# F-12 Comfort scenarios

**Android status:** IMPLEMENTED (JVM + LIVE text).
**Depends on:** F-11

## 1. Purpose
Multi-step responses to situations: mosquito, mosquito done, mosquito still there, stuffy, drowsy.

## 2. User-facing behaviour
有蚊子 → windows half open; 蚊子还没走 → AC on, fan +1 (windows untouched); 蚊子出去了 → close; 有点闷 → AC on, fan +1, front windows 20; 好困 → AC on, temp −2, front windows 20, music play, suggests a rest stop.

## 3. Preconditions
None.

## 4. Inputs and outputs
`run_scenario{name ∈ mosquito, mosquito_done, stuffy, drowsy}`; partial completion reports `partial`.

## 5. State transitions
Steps executed in order.

## 6. Events and triggers
Tool call.

## 7. Dependencies and external services
F-11, F-13 (music).

## 8. Error handling and recovery
Partial result is reported honestly (ActionClaimGuard).

## 9. Concurrency, cancellation, timeouts
Sequential.

## 10. Acceptance criteria (iOS)
- Each scenario produces the same state changes as Android (golden tests).
- If one step fails, the reply does not claim the full scenario.

## 11. Existing Android tests
`T/tools/ComfortScenariosTest`.

## 12. Source references (Android)
`A/vehicle/ComfortScenarios.kt:29-58`; `A/voice/DriverTurnPipeline.kt:395`.

## 13. Implementation constraints


## iOS notes (PROPOSED unless labelled)
Portable (A).

## 14. Model-chosen comfort actions (iOS, APPROVED 2026-11-02)

**Why.** Today Gemini only picks a scenario name, then a fixed table decides the actions (§2) and she reads the returned `announce`. The table cannot use the situation: 有蚊子 opens all windows 50% every time. The owner and their mentor want the model to judge from the conversation which vehicle tools fit and to reply in its own words. Owner 2026-11-02: "ok write this in spec and push to remote".

Community review 2026-11-02:
- Home Assistant lets the model control devices through a small tool set, gives it device state, and benchmarks with identical state per run. It says model output cannot be fully trusted.
- The vehicle benchmark (arXiv 2609.19630) scored 202 scenarios across seven decisions. The best model reached 89.1%, and the API models still wrongly acted in 2–3 of 161 non-execution scenarios. It concludes that an independent layer must check permissions and vehicle state before any vehicle function runs.
- Microsoft's voice guidance: small tool lists, small results, state only what tools return, one or two sentences, spoken failures.
- Anthropic favours combined tools for many workflows and tests with realistic tasks and a held-out set. So combined tools are not wrong in themselves; this change removes one because here the right action depends on the situation.
- Hyundai (COLING 2025) uses a separate intent classifier for speed and treats 3 s as the production response limit. Gemini already handles every request here, so no classifier is added; time is measured instead.

Nobody publishes results for vague comfort requests such as 有蚊子, so this is unproven. Hence the comparison before any switch.

**Rule in plain words.** The model decides what to do and what to say. Code decides whether it is allowed and reports what really happened. The old table stays the default until the owner has seen both scores.

### Part A: scored test set (T-031a)
1. **The set.** A file of at least 55 cases in `Packages/NovaCore`: Chinese sentence, starting vehicle state, optional earlier turns, expected decision, and what is acceptable. 40 cases are for tuning. At least 15 are held out: they are scored but never used to change a prompt or a description.
2. **Decisions.** Each case expects one of: `act`, `ask`, `refuse`, `noTool`. They cover at least:
   - comfort: 有蚊子, 蚊子还没走, 蚊子出去了, 有点闷, 有异味, 好困, and at least 10 wordings not in any prompt (车里飞进来一只蚊子, 有烟味, 我快睡着了);
   - direct: 打开空调, 车窗开一半;
   - state: 再冷一点 at minimum temperature, 关窗 with windows closed;
   - should ask: 帮我关一下;
   - should not act: 讲个笑话, 蚊子是什么动物, 我朋友车里有蚊子;
   - blocked by code: a request the checks of item 11 must block.
3. **Scoring is on outcomes, not exact calls.** A case lists required and forbidden state results, for example 有蚊子: windows or fan changed, and temperature and music unchanged. A pure scorer in `NovaCore` returns pass or fail with the reason. Different valid answers can all pass.
4. **Runner.** 设置 → 舒适场景测试 sends each case with `sendText` through the real session, tools and checks. The simulated vehicle is reset per case and each case is new context. Each case runs 3 times. The app's keys are used as usual and never appear in the report.
5. **Report.** On screen: score per decision and per set, every failure with the reply text for reading, median and worst time from sending to first audio, tool calls per case, and blocked actions. Logs get only numbers and case ids (I-8). The owner screenshots it, and the numbers go in specs/STATUS.md.
6. **Baseline.** Run it on the current table first and record the score. The sentences are typed, so transcription errors are not covered; rows 8–9 cover speech.

### Part B: model-chosen mode behind a setting (T-031b)
7. **Setting.** 设置 → 「由模型决定舒适动作（实验）」, default off. Off is exactly today's catalog, prompt and table. It applies at the next session, because the catalog is set at session start. This is an F-09 exception to the byte-for-byte Android catalog: the Android-equal catalog stays for the off path, and the on path is a separate list.
8. **Catalog when on.** `run_scenario` is removed. `control_window`, `control_climate`, `control_music` and `play_music` stay. In their descriptions the sentence-to-action rules for feelings go, including 「有点闷」→`run_scenario`; direct-request examples stay.
9. **State tool.** A new read-only `get_vehicle_state` returns window percents, AC power, temperature, fan level, whether music plays, whether navigating, and speed in km/h, using the phone's speed when fresh and otherwise null. It never returns coordinates or an address. Weather stays with `query_live_info`, which the model may call when it matters.
10. **Prompt when on.** The base instruction replaces rule 5 and the scenario words with a goal: when the driver describes a feeling or situation in the car, check the state if it matters, use the tools to help, do not ask if a reasonable small action exists, and take no action for a mere mention (我朋友车里有蚊子). 好困 also suggests a rest stop. Replies are one or two sentences, say what was actually done, and say what failed. The base stays within `maxBaseCharacters`.
11. **Code checks (`VehicleActionPolicy`, pure, in NovaTools).** Every vehicle action passes it before the port, on both paths, so buttons and voice share it (I-6, I-11). A blocked action returns `ok=false` with a code and advice, and logs `vehicleBlocked tool code`. Rules:
    - values stay inside `CabinLimits` and the climate limits;
    - `windowSpeedKmh` (100) and `windowMaxAtSpeed` (30%): opening a window beyond that percent above that speed is blocked. These two numbers are PROPOSED; the owner may change them;
    - unknown speed does not block, because the vehicle is simulated and a window is low risk. Actions that are not safe with unknown state need a new rule and a new spec.
12. **She cannot claim what did not happen.** I-1, I-5 and I-14 stay. `DriverTurnPipeline` treats any ok action as proof of any action claim, which is too weak once the wording is free: an ok fan call would prove 「车窗开了」. Claims naming windows, AC or temperature, fan, or music now need an ok result of that tool in the turn. Words from eval failures are added to `ClaimLexicon`.
13. **Removed when on.** The `mosquitoWindowsOpen` flag and `noRecentMosquito`. 蚊子出去了 is judged from the conversation and state.

### Part C: decide and clean up (T-031c, owner decision)
14. **Pass bars for switching the default**, on the held-out cases, typed, 3 runs each:
    - overall score at least as high as the table's baseline, and clearly better on unprompted wordings;
    - `noTool` and `refuse` cases: no wrongful action in at least 95%;
    - no unbacked claim in any run;
    - median time to first audio at most 1 s slower than the table, and every comfort turn under 3 s;
    - device rows 8–9 pass.
15. **If the owner approves:** the setting is removed and on becomes the only path. `run_scenario`, `ScenarioToolHandler` and its tests are removed, F-12 §2, §4 and §10, F-09 and the catalog are updated, and J5 in product-spec.md changes to 「有蚊子」 gets a sensible action and an honest reply. If not, the table stays and the setting stays off.
16. **Out of scope.** Navigation, phone, camera and stop phrases keep their rules. No new vehicle functions. Real vehicle hardware needs its own permission rules before this design is used on it. Her answering her own voice is F-08.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Scorer with passing, forbidden-state and wrong-decision results | Pass or the matching reason; two different valid outcomes both pass | unit |
| 2 | The set | At least 55 cases, every decision present, at least 15 held out, at least 10 unprompted comfort wordings | unit |
| 3 | Setting off | Catalog, prompt and scenario results equal today's (existing F-12 and catalog tests unchanged) | unit |
| 4 | Setting on | No `run_scenario`; `get_vehicle_state` present and without location fields; base within its limit | unit |
| 5 | Policy: outside the limits; window 50% at 120 km/h; window 20% at 120 km/h; window 50% with unknown speed | Blocked; blocked; allowed; allowed; on both paths | unit |
| 6 | Claim 「车窗开了」 with only a fan call ok; with a window call ok; with fan ok and window failed | Disproven; proven; disproven | unit |
| 7 | Device, table, then model mode: the runner, whole set | Report completes; scores and times recorded in specs/STATUS.md | D |
| 8 | Device, setting on, spoken: 有蚊子, 车里飞进来一只蚊子, 蚊子出去了, 有点闷, 有烟味, 好困, 我朋友车里有蚊子, 讲个笑话 | Sensible action or none as expected; the vehicle state matches what she says; one or two sentences | D |
| 9 | Device, setting on: 关窗 with a failing simulated window, if the simulation can fail; 打开空调 | She says the failure; the direct action still works | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031a | Items 1–6: test set, scorer, runner, baseline on the table; rows 1, 2, 7 | unit, build, D |
| T-031b | Items 7–13: setting, catalog, state tool, prompt, `VehicleActionPolicy`, specific claims; rows 3–6, 7–9 | unit, build, D |
| T-031c | Items 14–15, **only after the owner approves the numbers**: make it the only path and remove the table | unit, build, D |

**Trace.** No current test name contains F-12, so these tasks are not yet in specs/trace-ids.txt. T-031a names its tests with F-12 and adds `T-031a: F-12`; T-031b adds `T-031b: F-12 F-09` in the same way.

## 15. Comfort tuning round after the first scores (iOS, APPROVED 2026-11-02)

**Why.** First device scores on ace916f, 56 cases, 3 runs each. Owner 2026-11-02 said yes to one tuning round.

| Measure | Table | Model |
|---|---|---|
| Overall | 148/168 | 149/168 |
| Held out | 38/45 | 37/45 |
| Unprompted wordings | 38/42 | 35/42 |
| No wrongful action | 21/27 | 27/27 |
| Unbacked claims | 0 | 0 |
| Median / worst first audio | 1946 / 5446 ms | 2358 / 14744 ms |
| Tool calls per run | 1.00 | 1.45 |
| `timedOut` failures | 12 | 9 |

The model is safer but does not pass §14 item 14. The numbers do not explain the timeouts:
- `ComfortEvalRunner.timeout` (20 s) starts before `connect`, so it includes opening a new session for every run.
- `.failed` and `.closed` are also scored `timedOut`, so connection and quota problems look like slow answers.
- `worstMs` covers every case, not only comfort turns.
- Blocked actions (3 and 6) are only counted, so we cannot see which rule blocked them.

Differences of 1–3 passes may be chance.

**Rule in plain words.** First make the test tell the truth, then tune the prompt on tuning cases only, then score both versions again. The table stays the default.

### Part A: make the test report the cause
1. **Separate failures.** Replace `timedOut` with: `sessionFailed` (`.failed`, `.closed`, or no `setupComplete`), `noAnswer` (nothing after `sendText`), `stuckAfterTool` (no answer after tool responses), `slowAnswer` (an answer started but `responseDone` did not arrive). `sessionFailed` is retried once. If it fails again it counts as `infrastructure`: it is shown on its own and left out of the score, and a run with more than 5% `infrastructure` is reported as not valid.
2. **Timer.** The answer timeout starts at `sendText`, not at `connect`. Connecting has its own limit of 10 s. Find out why `hNoAir` (感觉透不过气) failed 3 of 3 with the table, including whether Gemini returned a block or finish reason, and log that reason as an enum, without words.
3. **Time per stage.** For each run, without words: send to first event, send to first tool call, tool response to first audio, send to first audio. The report and `comfortEval` show median, 90th percentile and worst for comfort cases and for all cases separately.
4. **Blocked actions.** The report lists case id, tool and rule for each block. Log them as `vehicleBlocked`, as in a drive. If a wrongly blocked action caused a failure, record it, and do not change a rule without saying so in the PR.
5. **Fresh held-out cases.** The first held-out failures have now been read, so add 10 new held-out cases, at least 6 of them unprompted comfort wordings, written before any tuning. The earlier held-out cases stay as they are and are still never used for tuning.

### Part B: tune (tuning cases only)
6. **Allowed changes.** The model-mode rule 5 and comfort-related tool descriptions; the choice below in item 8. Not allowed: changes to the table path, to the checks of §14 item 11 to gain score, to case expectations, or any sentence copied from a held-out case. A case expectation found to be wrong is reported to the owner and left unchanged.
7. **Asking and refusing.** On tuning cases `fallingAsleep` and `drowsyMusicOn`, the model refused or asked instead of helping. Read the replies, find the cause, and change the rule so a driver saying they are sleepy gets a small action and a rest-stop suggestion. Keep the 27/27 result on mentions of other cars and knowledge questions.
8. **Speed.** Use the stage times to find where the time goes. If `get_vehicle_state` is a main cause, the prompt calls it only when state changes the choice, and acting tools keep returning their state. Do not add a second model or a classifier (§14 Why).

### Part C: score again
9. **Both versions, same build, same day, same network.** Table first, then model. Results go in specs/STATUS.md with the build id.
10. **Change to §14 item 14, owner approved 2026-11-02.** Held-out and unprompted scores must be at least equal to the table's, replacing "clearly better": the table already passes 38/42, so a clear gain cannot be measured on these cases. The 3 s limit stays, measured on comfort cases only. The table missed it too (5446 ms across all cases), so if both versions miss it the owner decides from the percentiles.
11. **Stop after this round.** The owner sees the scores and decides on T-031c, another round, or keeping the table. No further tuning without a new request.
12. **Out of scope.** Removing the table (T-031c), interruption, and her answering her own voice.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Runner: session fails once then works; fails twice; nothing after send; nothing after tool response; answer without `responseDone` | Retried and scored; `infrastructure`, not scored; `noAnswer`; `stuckAfterTool`; `slowAnswer` | unit |
| 2 | Slow connect within its limit, then a normal answer | Not a timeout; the answer timer starts at `sendText` | unit |
| 3 | Report with comfort and other runs, more than 5% `infrastructure`, and a block | Separate stage percentiles; marked not valid; block listed with case, tool and rule | unit |
| 4 | The set | 66 cases; earlier held-out cases unchanged; no prompt or description contains a held-out sentence | unit |
| 5 | Setting off | Catalog, prompt and scenario results equal today's | unit |
| 6 | Device: whole set on the table, then the model, same build | Both reports valid; numbers and failure causes in specs/STATUS.md | D |
| 7 | Device, setting on: checklist 13-03…13-05, and the driver says 我快睡着了 | Small action and rest-stop suggestion; what she says matches the car | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031d | Items 1–11; rows 1–7 | unit, build, D |

## 16. Trustworthy comfort test, then targeted fixes (iOS, APPROVED 2026-11-03)

**Why.** Scores on c4fa669, 66 cases, 3 runs each, 198 runs, both reports valid:

| Measure | Table | Model |
|---|---|---|
| Overall | 182/198 | 180/198 |
| Held out | 67/75 | 69/75 |
| New held out | 24/30 | 24/30 |
| Unprompted wordings | 63/63 | 62/63 |
| No wrongful action | 24/30 | 28/30 |
| Unbacked claims | 0 | 1 |
| Comfort first audio, median / 90% / worst | 1640 / 2858 / 4203 ms | 1966 / 2809 / 4714 ms |
| `slowAnswer` | 4 | 8 |

Owner 2026-11-03: "what ever you just take those approach and write that on spec", after a review of community practice.

Community review 2026-11-03:
- [Google's Live API reference](https://aistudio.google.com/api-reference/live): content is generated as quickly as possible, the last output transcription comes before `generationComplete`, and with realtime playback there is a delay between `generationComplete` and `turnComplete`.
- [Anthropic on agent evals](https://anthropic.com/engineering/demystifying-evals-for-ai-agents): read transcripts to validate graders, give tasks a known passing answer, two experts should reach the same verdict, test both when a behaviour should and should not occur.
- [Miller, Adding Error Bars to Evals](https://arxiv.org/html/2411.00640): compare models on per-question differences with a confidence interval; more questions help more than more repeats.
- [CAR-bench](https://arxiv.org/html/2601.22027) and [EVA](https://huggingface.co/blog/ServiceNow-AI/eva): final state scoring, and consistency over 3 runs reported beside single-run success. CAR-bench: top models pass consistently under 50% on disambiguation, largely from acting too early. So perfect judgment is not the goal.
- [Vehicle authorization benchmark](https://arxiv.org/html/2609.19630): paired exact McNemar tests; decisions are read from a structured field, not inferred from explanatory text.
- [Full-Duplex-Bench v3](https://arxiv.org/abs/2604.04847): real human audio; self-correction is a consistent failure across systems, including Gemini Live.

What the code and the c4fa669 replies show:
- The runner waits for `responseDone`, which comes from `turnComplete`, and ignores `generationComplete` (`.audioDone`). 7 of the 8 model `slowAnswer` runs are complete 3–5 sentence knowledge answers. Not proven on device: all 8 fall in a recorder gap, 10:25:23–10:32:59.
- `ComfortScorer.decision` treats ？, ?, 吗 or 呢 anywhere in a reply as asking, and refusal words anywhere as refusing. A joke containing 「你是不是瞎呀？」 scored `wrongDecision:ask`.
- `mosquito#1` and `flewIn#2` scored `missingChange`, which needs an ok acting call. So she acted, the state did not change, and she said 「车窗都关好了」. She did not ignore the sentence.
- The base instruction asks for 大约三到五句 on knowledge questions, so those lengths are as specified, not a fault.
- Audio and transcription arrive independently, so a claim cannot be checked before it is heard without delaying every reply. Live, `DriverTurnPipeline` corrects afterwards with `sendCorrection`. The runner does not, so `unbackedClaim` does not show what a driver finally gets.

**Rule in plain words.** First make the test trustworthy and check the test itself on real replies. Then make only the small fixes below. Then score both versions. The table stays the default.

### Part A: the test
1. **End of reply.** A run ends at `.audioDone` when an answer has arrived and no tool response is awaited, or at `.responseDone`, whichever is first. The 20 s limit stays. Add stage `answerDone`, send to end of reply, to the report. No change to the live session.
2. **Reading a decision from text.** Split the reply on 。！？!? and newlines. `ask`: the last sentence is a question (ends with ？ or ?, or with 吗 or 呢). `refuse`: a refusal word in the first or last sentence. Decisions from tool calls stay as they are.
3. **Test the test.**
   - Unit fixtures use real c4fa669 replies: the joke above; 「请问您想调整哪里呢？是温度、座椅还是车窗？」 is `ask`; 「听起来昨晚肯定很难受，今天车里温度还可以吗？」 is `ask`; a knowledge answer of several sentences is `noTool`.
   - Every case has a known good outcome that the scorer passes, built in a unit test, and a known bad one where the case forbids or requires something.
   - 舒适场景测试 gets 「试跑」: 12 cases covering every decision, once each, about 2 minutes, showing every reply. A full run is only started after someone has read a trial's replies.
4. **Expected answers.** The owner and their mentor each give a verdict without seeing the other's on: `h2RaiseWhat` 帮我调高一点 (ask, or is raising the temperature fine?), `h2LastNight` 我昨晚热得睡不着, `mosquito` and `flewIn` (is closing already-closed windows acceptable?), `mosquitoGone`. Where they agree, the owner's answer is recorded in specs/STATUS.md and the case follows it. Where they differ the case is shown as 有争议 and left out of the score. Nothing else changes a case's expectation.
5. **More cases.** Grow the set from 66 to 100. The 34 new cases are written before any fix in Part B: at least 20 held out, at least 12 where she should not act or should ask, and at least 10 unprompted comfort wordings. Existing held-out cases have now been read, so all Part B work uses only tuning cases, and the score that decides is the 20 new held-out ones plus the overall.
6. **Consistency.** Report per case 「3 次都过」 (pass^3) beside the run scores, overall and per decision.
7. **Comparison.** Keep the latest report per mode in a local file, never logged, so both survive a restart. When both come from the same build, 对比 shows: the difference per case; the mean of those differences with a 95% interval from their standard error (Miller); every case where the versions differ; and 「看不出差别」 when the interval includes zero. Totals alone are not compared.
8. **Length.** Report how many `act` runs say more than two sentences, as `tooLong`. It is reported, not a failure. Knowledge answers are not counted.
9. **A clean run.** The screen stays on during a run. If the app leaves the foreground, that run is marked `interrupted`, repeated and not scored, and the report shows the count. Log the summary, each failure and each block as separate lines with numbers and ids only (I-8), because one long line was cut off in the log.

### Part B: small fixes, model mode only, tuning cases only
10. **False claims.** Do not delay audio to check it first. The runner does what a drive does: on an unbacked claim it sends the same `CorrectionReason` text in the same session, waits up to 20 s more, and scores the final state and final reply. Report `firstReplyClaims` and `uncorrectedClaims`. Rule 5 adds: 要做动作就先调用工具，不要说「我这就做」却不调用。
11. **Insects.** Default: rule 5 adds a goal, 车里有虫子：开点窗或调大风量让它出去，窗已经关着时不要只说关好了. If item 4 accepts closing windows, leave this out. No table backup: she did act here, so a backup for doing nothing would not fire.
12. **Not changed.** The table path, the checks of §14 item 11 to gain score, knowledge answer length, and any sentence from a held-out case in a prompt or description.

### Part C: score and decide
13. **Order.** Trial first; someone reads it. Then the table, then the model, same build, same day, same network. Results go in specs/STATUS.md with the build id. About 30 minutes per version.
14. **Decision bars, replacing §14 item 14 and §15 item 10.** Numbers are PROPOSED until the owner has seen them.
    - `uncorrectedClaims` is 0. `firstReplyClaims` is shown for the owner.
    - No wrongful action in at least 95% of `noTool` and `refuse` runs.
    - Model minus table, overall: the lower end of the 95% interval is no worse than −5 points. A smaller gap is not treated as a difference in either direction.
    - Comfort first audio: median at most 1 s slower than the table, 90th percentile under 3 s, and the worst shown for the owner.
    - Device row 8 passes.
15. **Stop after this.** The owner sees the numbers and decides on T-031c, another round, or keeping the table.
16. **Out of scope.** Interruption and her answering her own voice (F-08), and removing the table (T-031c).

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Runner: text, then `.audioDone` with no `.responseDone`; `.audioDone` before a tool call's response; nothing ends by 20 s | Run ends with no problem; keeps waiting; `slowAnswer` | unit |
| 2 | Scorer with the real replies of item 3 | Decisions as listed there | unit |
| 3 | Every case | A known good outcome passes; a known bad one fails where one exists | unit |
| 4 | The set and a case marked 有争议 | 100 cases, counts as in item 5, earlier held-out cases unchanged, no prompt contains a held-out sentence; the case is shown and not scored | unit |
| 5 | Report and comparison with known per-case results | pass^3, mean difference and interval as calculated by hand; 「看不出差别」 when it includes zero; different builds are not compared | unit |
| 6 | An unbacked claim, then the correction: tool call ok; no tool call but an honest reply; the claim again | Not uncorrected, `firstReplyClaims` 1; same; `uncorrectedClaims` 1 | unit |
| 7 | App leaves the foreground in a run; setting off | Run repeated and not scored; catalog, prompt and scenario results equal today's | unit |
| 8 | Device, setting on, spoken: checklist 13-03…13-06, 有蚊子 with windows closed, 「打开车窗，不对，关上」 | The car matches what she says; one or two sentences; the self-correction ends with windows closed | D |
| 9 | Device: trial, then both whole sets | Both valid with no `interrupted` scored; `slowAnswer` near 0, otherwise the cause is recorded; numbers in specs/STATUS.md | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031e | Items 1–14; rows 1–9 | unit, build, D |

## 17. Conversation record for testing (iOS, APPROVED 2026-11-03)

**Why.** On 2026-11-03 the owner reported, in model mode, 13:45:11–13:49:16, that she gave the same reply to every sentence. The log showed 9 sentences sent and 9 replies, but no words and no tool calls, because I-8 keeps transcripts out of logs. So the cause could not be found. Owner: "you should build that for testing" and "you jsut wrie a spec and push to cloud".

**Rule in plain words.** A setting, off by default, writes each conversation to a file on the phone. It records what happened and changes nothing she does.

1. **Setting.** 设置 gets 「保存对话记录（测试用）」, default off, read at session start. Off: no file is created and nothing else changes.
2. **File.** One UTF-8 text file per session at `Documents/conversations/<yyyyMMdd-HHmmss>.txt`, so it can be read through file sharing or pulled from the PC. Keep the newest 50 and delete older ones. 设置 gets 「删除全部对话记录」, which asks for confirmation.
3. **First lines.** App version, comfort mode, 可以打断她 on or off, speaking style. Never a key or the system instruction.
4. **One line per event.** Milliseconds since the session started, a kind, then the content:
   - `heard-local`: the final words from the bundled recognizer, or `（没听清）`.
   - `heard-gemini`: Gemini's final input transcription.
   - `utterance`: id, sent to the model or not, and the mute reason.
   - `reply`: her text as Gemini sent it, merged into one line per turn.
   - `reply-out`: for each turn, whether it was released, held and released, or voided, with the reason.
   - `tool-call`: name and arguments.
   - `tool-result`: name, ok, code and data.
   - `correction`: the `CorrectionReason` sent.
   - `playback`: her audio started and finished.
   - `barge-in`: stopped or rejected.
   - `turn-end`: `generationComplete`, `turnComplete` and the reason.
   - `session`: connected, reconnected, failed with a code, closed.
5. **Privacy (I-8).** Nothing from the record goes to the system log, a network or an analytics call. `RuntimeLog` lines stay as they are. Tool arguments and results are written as they are, so a file can contain addresses; this is why the setting is off by default and the file stays on the phone. A log or transcript from a run with the setting off is unchanged.
6. **Never in the way.** Writing happens off the audio and event paths through a bounded queue. If the queue is full, lines are dropped and the count is written as `dropped=<n>`. A failed write stops the record for that session and never affects the session.
7. **Logic in NovaCore.** Line formatting, merging of reply pieces, and which files to delete are pure logic in `Packages/NovaCore`, with unit tests. Only the file writing and the setting live in `App/`.
8. **Out of scope.** Fixing the repeated reply, which is diagnosed from the first record, and any change to the prompt, the tools or the checks. The comfort test's runner is not recorded.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Reply pieces, a tool call and result, a correction, and a voided turn, in order | One merged `reply` line per turn; the other lines in order with their times and contents | unit |
| 2 | 51 existing session files | The oldest is chosen for deletion; files of other names are left alone | unit |
| 3 | A full queue, then a failed write | `dropped=<n>` is written; the record stops and no error reaches the session | unit |
| 4 | Setting off | No record object is created and no file is written; event order to the core is the same as with it on | unit |
| 5 | A session's first lines and events containing a stored key's name | The key's value and the system instruction never appear; no record line is passed to `RuntimeLog` | unit |
| 6 | Device, setting on: start a conversation, say 有点热, 讲个笑话, 现在几点, end it, then pull the file from the PC | The file shows what she heard, what she said and each tool call, in order, with times that match the system log | D |
| 7 | Device, setting off, same sentences | No new file, and she behaves as before | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031f | Items 1–7; rows 1–7 | unit, build, D |

## 18. Say what the window and climate tools are for (iOS, APPROVED 2026-11-03)

**Why.** On e7e41da, model mode, the record for 有点闷 shows `adjust_fan` +1 and `power_on`, and no window. The owner expected a window. Both tool descriptions list command phrases and neither says what the tool is for. One run does not prove that this is the cause; it may be chance or the model's habit. Owner 2026-11-03: "this make sense then write the spec".

Community review 2026-11-03:
- [Anthropic on writing tools](https://www.anthropic.com/engineering/writing-tools-for-agents): make implied context explicit, and measure every description change.
- [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling): state the purpose; when and when not to use goes in the system prompt; examples may hurt reasoning models.
- [Google function calling](https://aistudio.google.com/docs/function-calling): a clear explanation of the function's purpose.
- [CAR-bench](https://arxiv.org/html/2601.22027): tools say what they do; rules about when they may be used are kept apart.
- [Study of 856 tools](https://arxiv.org/abs/2602.14878): 56% did not clearly state their purpose; augmenting descriptions raised task success by a median of 5.85 points and made 16.67% of cases worse. [Study of 10,831 servers](https://arxiv.org/abs/2602.18914): functionality wording changed selection by +11.6%. Neither is about cars.

**Rule in plain words.** Tools state general facts about what they do. They name no driver sentence or feeling, and they do not choose for her. Then measure, because this can also make her act wrongly.

1. **Baseline first.** Before this build is installed, on e7e41da with model mode and the record on, windows closed, a new conversation each time: 有点闷, 5 times. Record the tools called, from the record files, in specs/STATUS.md.
2. **Window description, model mode only.** `control_window` in `modelComfortSpecs` begins: 「控制车窗（模拟）。开窗能换入车外空气、散掉车内异味；关窗能隔绝噪音和车外空气。」 The rest of today's description follows unchanged.
3. **Climate description, model mode only.** `modelClimateDescription` begins: 「控制空调（模拟）。空调主要调节温度，风量让车内空气流动。」 The rest of today's description follows unchanged.
4. **Not changed.** The table's descriptions, rule 5, the other tools, the checks of §14 item 11, and the test cases and their expected answers. No line about 闷 or insects goes into a tool. A driver's preference, such as always opening a window for 闷, is a separate question and is not part of this task.
5. **After.** The same 5 tries as item 1 on the new build. Then the §16 item 13 order on that build: the trial, someone reads it, the table, then the model. The §16 item 4 verdicts come first, as §16 requires.
6. **Keep or revert.** PROPOSED until the owner has seen the numbers. Keep the change only if the model run meets the §16 item 14 bars. Windows opened in the 5 tries are shown beside the baseline; five tries can only show a large difference, so they do not decide on their own. If the bars for no wrongful action or the overall interval fail, the owner decides whether to revert. A full before-and-after score of the model on different builds is not compared (§16 item 7).
7. **Out of scope.** Removing the table (T-031c), trimming rule 5, and a driver-preference step.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Model-mode declarations | `control_window` and `control_climate` begin with the sentences of items 2 and 3, and the rest of each equals today's text | unit |
| 2 | Table-mode declarations, and every other model-mode tool | Equal to today's | unit |
| 3 | The two new descriptions and every held-out case | No held-out sentence appears; neither contains 闷, 蚊 or 虫 | unit |
| 4 | Device: 有点闷, 5 times, before and after, record on | Tools called and windows opened are in specs/STATUS.md for both | D |
| 5 | Device: the item 5 runs | Both reports valid; numbers and the item 14 bars in specs/STATUS.md | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031g | Items 1–6; rows 1–5 | unit, build, D |
