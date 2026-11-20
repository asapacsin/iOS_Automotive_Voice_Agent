# F-09b Flexible assistant: the model understands, code checks the action (随机应变)

**Status:** APPROVED (owner 2026-11-16: "you just write the spec for this so call more flexibile stuff"); owner's go
to build 2026-11-16 ("pull and implment this flexible spec"). iOS only.
**Replaces:**
- the T-031c owner decision (F-12 §14 items 14–15): the model-chosen path becomes the only comfort path;
- F-09a §2–4 (word-list areas, comfort refusal, tired silence in code), withdrawn by T-017c.

**Depends on:** F-12 §14 (model-chosen comfort, `VehicleActionPolicy`, `get_vehicle_state`, claims), F-09 (catalog,
dispatch), F-18 §21 (silent `[系统]` notes, `AgentState.flushNote`), F-24 §15 (kept resumption), F-21 (base
instruction, `maxBaseCharacters`), F-06 (claims and corrections), contracts/voice-agent.md

## 1. Why

**What the mentor asked (2026-11-16):** 「要让大模型加持下的这个车载语音助手能够随机应变」. The LLM-powered assistant
should handle whatever comes up.

**What NovaDrive does today (code at 6306d0b):**
- **Comfort default is a fixed table** (`ComfortMode.table`). Gemini picks a scenario name and the table picks the
  actions: 有蚊子 opens all windows 50%, every time.
  - The model-chosen mode exists but is an experimental setting, off by default (「由模型决定舒适动作（实验）」).
- **A word list gates the comfort tools** (F-09a `CarRequestRouter`). A sentence with no listed car word gets
  `NOT_A_CAR_REQUEST`. A tired-word list silences her in code.
  - Anything not on a list falls through.
- **Gemini sees the car only if it asks.** `get_vehicle_state` exists only in model mode, and the prompt tells her to
  call it rarely (F-12 §15 item 8).
- **Nothing carries over to a new session.** Only a resumption handle kept after a give-up (F-24 §15). A conversation
  that ended and was started again begins empty.

**The test numbers do not show a worse model.** In both scored rounds the model was as accurate as the table and made
fewer wrong actions (F-12 §15, §16):

| | Table | Model |
|---|---|---|
| Overall, round 1 / round 2 | 148/168, 182/198 | 149/168, 180/198 |
| No wrong action, round 1 / round 2 | 21/27, 24/30 | 27/27, 28/30 |
| Comfort first audio, median, round 2 | 1640 ms | 1966 ms |

It missed the T-031c bars on time and on one unbacked claim.

**The two device mistakes were not poor judgment:**
- **11-10, "Ah" → air conditioning and fan (F-12 §20).** Our own rule 5 listed tiredness as a feeling that gets a
  small action. She followed the prompt.
- **11-10, 「好困」 → air conditioning (F-09a §1).** Gemini's transcript was 「好看」, so this was mishearing. The
  sleepy sentence was in the prompt and she did not follow it.

## 2. Sources

- **One model understands and plans; the old way classifies first and dispatches by domain.**
  - 火山引擎's 2026 cockpit replaces 「意图分域+多Agent协同」 with one model that fuses voice, location and vehicle
    state ([腾讯新闻](https://news.qq.com/rain/a/20260427A08OKE00), [汽车之心](https://www.autobit.xyz/news/4763.html)).
  - Its stated reason: cross-domain tasks stitched by rules break, and modules share no context.
- **Permission by function, not by words.**
  - 火山引擎 splits car control into 黑/灰/彩 tiers: brakes and steering are 「AI 禁区」, while air conditioning and
    seats are open to the model ([腾讯新闻](https://news.qq.com/rain/a/20260427A08OKE00)).
- **The model outputs the action; a policy layer checks it.**
  - A published cockpit design checks every write before it runs: value ranges (clamp and say so), speed locks,
    rate limits ([h89.cn](https://h89.cn/archives/690.html)).
  - In that design, comfort writes run at once and are confirmed by saying what was done. Risky ones (unlock,
    sunroof) are read back and need a yes first.
  - It injects vehicle state every turn as a system message, and carries a structured summary of each turn into the
    next.
- **An independent check, not model judgment, is the safety authority.**
  - A vehicle benchmark found no model free of wrongful actions, and recommends rule-based validation before any
    vehicle function ([arXiv 2609.19630](https://arxiv.org/abs/2609.19630)).
  - CAR-bench: top models act too early on unclear requests, consistently passing under 50%
    ([arXiv 2601.22027](https://arxiv.org/html/2601.22027)). Perfect judgment is not the goal; cheap correction is.

## 3. Comfort: the model decides (T-031c)

1. **One path.**
   - `ComfortMode.model` becomes the only comfort path. The setting 「由模型决定舒适动作（实验）」 is removed.
   - `run_scenario`, `ScenarioToolHandler`, the scenario step table and their tests are removed.
   - The table-mode base (rule 5's fixed feeling table 「有点热：调低一度…」) is removed. The model-mode base
     (`modelComfortBase`) becomes `base`.
2. **Checks that stay, unchanged.**
   - `VehicleActionPolicy` (value range, window at speed) runs on every vehicle action (F-12 §14 item 11).
   - The claim rules: 「车窗开了」 needs the window tool's ok (F-12 §14, F-06).
   - Phone calls keep their confirmation (F-19). Sunroof stays `UNSUPPORTED_BODY_PART`.
3. **Rule 5, rewritten.** It must fit `maxBaseCharacters`. The `get_vehicle_state` sentence is dropped, since the
   state now arrives by note (§5).
   > 5. 司机说车里的感受或情况：按车内状态选一个合理的小动作直接做，不要反问。要做动作就先调用工具。做了就用一句话说改成了什么（例如「空调调到24度了」）；司机说「不用」「改回去」「刚才那个不要」就调用 undo_last_change。只是提到别处的事或问知识时不做任何操作。只说真正做成的，没做成的要说。

   The sleepy sentence (F-12 §20 item 1, 「司机只是说累、犯困：不要调用任何工具，不要操作车辆，也不要说话，不回应。」) and
   座位有点高 stay as they are.
4. **Comfort test.**
   - The F-12 comfort set and runner keep running on the one path.
   - Table-only scoring and the table baseline are removed.
   - The ten sleepy cases stay `noTool` and `silent`.

## 4. Undo in one sentence (T-031j)

1. **Tool.** `undo_last_change()`, no arguments. The catalog text:
   > 撤销刚才的车辆调整：「不用」「改回去」「刚才那个不要」「还是原来的好」。按结果答：一句话说恢复成了什么；NOTHING_TO_UNDO 说没有可以撤销的。
2. **What it undoes.**
   - The app keeps the cabin state from before the last comfort change set: every vehicle action ok in one model
     turn counts as one set.
   - The undo restores that state through the same port and `VehicleActionPolicy`. The result gives the restored
     values (`restored`).
   - Only one set is kept, for 5 minutes. A second undo, or an undo after 5 minutes, returns `NOTHING_TO_UNDO`.
   - A tap on a comfort control clears the kept set.
3. **Claims.** An undo's ok backs the claims for the restored functions, as an action tool's ok does.

## 5. She sees the car without asking (T-031j)

1. **State note.** A silent note in the F-18 §21 form: `[系统] … 这句不用回答。`, `turnComplete: false`, only when
   idle (`noteIdle`), never interrupting a reply:
   > [系统] 车内状态：空调<开|关>，<t>度，风量<f>；车窗 主驾<p>% 副驾<p>% 后左<p>% 后右<p>%；座椅 主驾<h>档；音乐<在放|没放>；车速<v|未知>公里。这句不用回答。
   - Values are the same as `get_vehicle_state`. Location fields are never included.
2. **When it is sent.**
   - On (re)connect.
   - After a completed turn in which the state changed, including a tap.
   - When speed crosses `VehicleActionPolicy.windowSpeedKmh`.
   - Not more than once per completed turn.
   - It goes through the same queue as the destination note. If both are pending, they go in one text turn.
3. **`get_vehicle_state` stays declared** for the rare case the model wants it again. The prompt no longer tells her
   when to call it.

## 6. Memory across sessions (T-016p)

1. **What the app keeps.**
   - The last 6 completed exchanges of the conversation, in memory only (I-7: never written to disk, never logged).
   - Each exchange is the driver's line as shown on screen (F-05a §16) and her final reply text, each cut to 60
     characters.
   - Plus the tool results of that exchange as names and ok/codes.
2. **When it is sent.**
   - When a new session starts without a resumption handle, within 30 minutes of the last exchange.
   - It goes as one silent note before the state note:
     > [系统] 接着之前的对话。最近几句：司机「…」→ 你「…」；…。这句不用回答。
   - A session that resumes with a handle gets no summary: Gemini already has the context.
3. **Clearing.**
   - Kept exchanges are dropped when the driver says 结束对话, after 30 minutes of no exchange, and on app restart.
   - The trip list (F-15b) is not part of this. The app keeps it itself.

## 7. Word lists withdrawn (T-017c)

1. **Withdrawn (F-09a §2–4):**
   - `CarRequestRouter` areas, `NOT_A_CAR_REQUEST`, the 800 ms call wait for the area;
   - tired-turn silencing in code, `tired-silenced`;
   - the `area` record line.
   - The F-05a §6 rule is back in full: no tool guard reads the driver's words.
2. **Kept:** local stop phrases (别说了, 结束对话), the local pick on lists (F-15), the wake word. These are fast lanes
   for exact commands, not gates on understanding.
3. **If 「好困」 changes the car again on the device (row 9):**
   - the driver hears what changed (§3 item 3) and can undo it (§4);
   - the fallback, only with the owner's say, is to restore F-09a §4's tired silence alone, not the areas.

## 8. Record and log

Codes and numbers only (I-8).

| Line | When |
|---|---|
| `undo ok=<yes\|no> restored=<n>` | After `undo_last_change`. |
| `state-note reason=<connect\|changed\|speed>` | When a state note is sent. |
| `summary-note exchanges=<n> age_s=<s>` | When a summary note is sent. |
| `vehicleBlocked …` | Unchanged. |

## 9. Acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Any build | No `run_scenario` declared or handled; no comfort-mode setting; `base` equals the old `modelComfortBase` with the §3 item 3 rule 5; within `maxBaseCharacters` | unit |
| 2 | Climate set to 30 °C at 120 km/h; window 50% at 120 km/h | `VehicleActionPolicy` blocks as today | unit |
| 3 | One model turn sets temperature and opens a window, then `undo_last_change` | Both restored through the policy; claims for both backed; a second undo is `NOTHING_TO_UNDO` | unit |
| 4 | Undo 6 minutes after the change; undo after a tap on the fan | `NOTHING_TO_UNDO` both times | unit |
| 5 | Connect; a turn that changes the fan; a turn that changes nothing; speed crosses 100 km/h | State notes on connect, after the fan turn and on the speed cross only; never while a reply is open; destination and state in one text turn when both pending | unit |
| 6 | Session ends; a new session starts 10 minutes later without a handle; another 40 minutes later; one with a handle | Summary note with ≤ 6 exchanges for the first only; nothing written to disk or RuntimeLog | unit |
| 7 | Comfort calls from 讲个笑话 and 好困 (no area) | They run (no `NOT_A_CAR_REQUEST`); policy and claims still apply | unit |
| 8 | Existing F-12 comfort set on the one path, held out cases, 3 runs | No wrongful action in at least 95% of `noTool` and `refuse` runs; no unbacked claim; comfort first audio median ≤ 2.5 s | D |
| 9 | Device: 有点热, 不用, 有蚊子, 蚊子出去了, 车里有烟味, 好困 (3 times), 我朋友车里有蚊子, 讲个笑话, 再热一点 after 「空调调到24度了」 | Each acts sensibly or not at all; she says what she changed; 不用 restores it; the record has `state-note` and `undo` lines | D |
| 10 | Device: end the conversation, wake her again within 10 minutes, ask 「刚才那个再调低一点」 | She knows what "刚才那个" was | D |
| 11 | Navigation, music, call and F-15b suites | Unchanged | unit |

## 10. Tasks

| Task | Scope | Verify |
|---|---|---|
| T-031c | §3: model path only, table and `run_scenario` removed, rule 5 rewritten, comfort test on one path; rows 1, 2, 8 | unit, build, D |
| T-031j | §4–5: `undo_last_change`, kept change set, state notes; rows 3–5, 9 | unit, build, D |
| T-016p | §6: in-memory exchange summary for a new session without a handle; rows 6, 10 | unit, build, D |
| T-017c | §7: F-09a areas, refusal and tired silence withdrawn; rows 7, 11 | unit, build |

Order: T-031c first, then T-031j and T-017c together (the undo is the safety net for the withdrawn lists), then
T-016p. Trace ids are added with the tests (`T-031c: F-12 F-09b` and so on), not before.

## 11. Implementation notes (T-031c, T-031j, T-016p, T-017c)

1. **One catalog.** `ToolCatalog.specs` is the Android catalog without `run_scenario`, with the model-chosen climate
   and window texts, then `set_volume`, `get_vehicle_state` and `undo_last_change`. The generated Android mirror is
   unchanged; `run_scenario` is filtered out of it and is `UNKNOWN_TOOL`. `ToolCatalog.ComfortMode`,
   `declarations(for:)` and `PersonaInstruction.base(for:)` are gone. The record header still writes
   `comfortMode model` so old and new records read alike.
2. **Rule 5** is §3 item 3's text, then the sleepy sentence, then 座位有点高. `get_vehicle_state`'s description no
   longer says when to call it.
3. **Comfort test.** One path; the table comparison is replaced by `ComfortBars` (row 8: no wrongful action in at least
   95% of the scored runs, no uncorrected claim, comfort first audio median ≤ 2.5 s). The latest full report is kept in
   `comfortEval.json`; the old per-mode files are not read.
4. **Change sets.** The tool runner gives each executor its model turn as `ToolTurn.current`. `ChangeSetRecorder`
   wraps the three vehicle tools and keeps the state from before the first ok change of a turn (`get_state` and a
   failed or blocked call keep nothing). The store lives for the app run (memory only), so an undo can follow a new
   session within the 5 minutes. A partial undo returns ok with `not_restored`; an undo where every step failed is
   `VEHICLE_EXECUTION_FAILED`.
5. **Taps.** The 车辆 tab runs its own simulator, not the session's car, so today no tap reaches the kept set;
   `ChangeSetStore.clear()` is the hook for a comfort control that uses the session's car.
6. **State note.** The shell sends `AgentEvent.vehicleState` at session start, after each vehicle tool or undo, and
   every 5 s (speed and music). The core sends a note only for §5 item 2's reasons. The connect note counts as that
   turn's note, so a speed crossing before the first completed turn waits for it. Summary, destination and state
   notes due together go as one text turn, in that order.
7. **Summary.** `AgentState` emits `.exchange` for each completed turn with her judged subtitle, the driver line and
   the tool results (`name ok` or `name CODE`). The note lists them as `司机「…」→ 你「…」（tool ok）`. An exchange
   whose tools include `end_conversation ok` clears the memory instead of being kept.
8. **Withdrawn (T-017c).** `CarRequestRouter`, `CarRequestArea`, the `area` timer, `NOT_A_CAR_REQUEST`, the
   `carArea` / `tiredSilenced` diagnostics and their record lines are removed; `carRequestAreas` is no longer an
   `AgentState` argument. The diagnostics `stateNote` and `summaryNote` take their place in the closed set.

## 12. A sleepy driver gets a rest suggestion and nearby places (iOS, APPROVED 2026-11-19)

**Why.**
- **What happened.** Owner 2026-11-19, ipa150 (d9d75fe): 「有点困了」, demo step 1, got nothing; "the agent just don't understand what to do".
- **The cause.** At d9d75fe, rule 5 still contains F-12 §20's sleepy sentence, 「司机只是说累、犯困：不要调用任何工具，不要操作车辆，也不要说话，不回应。」 (`PersonaInstruction.sleepySentence`, `SpeakingStyle.swift:67`). The ten sleepy comfort cases require `noTool` and `silent` (§3 item 4). She stayed silent because she was told to.
- **Why §20 was written.** It answered a wrong car change: "Ah" → air conditioning and fan, and 「好困」 → air conditioning. That reason is still right for the car; it was never a reason to say nothing.
- **What the owner wants.** "the llm would has more automatic action to perform this kind of task".

**Sources (2026-11-19).**
- **Mercedes ATTENTION ASSIST.** When the system warns of fatigue, the multimedia system offers to search for a rest area. The driver selects one and starts navigation to it ([Mercedes owner's manual](https://moba.i.mercedes-benz.com/baix/cars/223.9_mbux_2021_a/en_GB/page/ID_bdd61d85e3a05610354ae3652659ca25-02b35b494ffd9e61ac190d2b6b7f8385-en-GB.html)). The break symbol is a coffee cup ([Mercedes press](https://media.mercedes-benz.it/international-coffee-day---prenditi-una-pausa-lattention-assist-celebra-il-suo-decimo-anniversario/)).
- **EU DDAW (2021/1341).** A drowsy driver must be warned, and the driver cannot switch the warning off ([EUR-Lex](https://eur-lex.europa.eu/eli/reg_del/2021/1341/oj/eng)).
- **The common pattern.** Suggest a break, offer nearby places, let the driver choose. No source changes the climate for drowsiness, and none stays silent.
- **Not found.** No reliable source on what NIO, XPeng or Li Auto do for 「我困了」.

**Rule in plain words.** When the driver says they are tired, she says one short sentence suggesting a rest. She lists nearby coffee shops (or rest areas on a highway) on the screen with `navigate_to`. Nothing starts until the driver picks one. Nothing in the car changes.

1. **The sleepy sentence (rule 5) becomes:**
   > 司机说累、犯困：不要调空调、车窗、座椅或音乐。用一句话建议找地方休息，并调用 navigate_to，destination=附近的咖啡店（在高速上用 附近的服务区），让司机在屏幕上选；司机没选就不开始导航。
   - It replaces `PersonaInstruction.sleepySentence` in rule 5, in the same place.
   - The base must stay within `maxBaseCharacters`. If it doesn't fit, raise the limit to the measured length and record the number in STATUS. The sentence itself is not shortened.
2. **`navigate_to` is unchanged.** It already handles 「附近的X」: a list of candidates on the screen, one sentence from `next`, and `choose_navigation_option` for the driver's pick. No route starts before the pick.
   - If the search fails or finds nothing, she says one sentence suggesting a rest, with no list.
   - During active guidance it is the same: the list shows, and the current route keeps running until the driver picks.
3. **Comfort test (§3 item 4 changes).**
   - The ten sleepy cases (drowsy, drowsyMusicOn, fallingAsleep, hEyelids, hDizzy, h2EyesClosing, h2Yawning, t3Exhausted, h3Nodding, h3Foggy) expect one `navigate_to` call whose `destination` contains 附近 and one of 咖啡, 服务区 or 休息.
   - They forbid every vehicle and music facet, and are no longer `silent`. A reply of at most one sentence passes.
   - whyDrowsy (为什么开车容易犯困) is unchanged: no tool.
   - `ComfortEval`'s `spoke` failure for these ten cases is removed.
4. **Superseded.** F-12 §20 items 1, 3 and 4. Its acceptance row 4 is replaced by row 5 below. F-09b §3 item 3's sentence 「The sleepy sentence … stays as it is」 now points here.
5. **Not changed.**
   - `VehicleActionPolicy`, the claim rules, and `undo_last_change`: if a car change happens anyway, 「不用」 restores it (§4).
   - No word list or code-side silencing returns (§7).
6. **Log.** No new lines. The record's existing `toolCall name=navigate_to` and comfort-eval lines show the result.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | The base instruction | Contains item 1's sentence and not 「不要说话，不回应」; length ≤ `maxBaseCharacters` | unit |
| 2 | Comfort set definitions | The ten sleepy cases expect `navigate_to` (附近 + 咖啡/服务区/休息), forbid vehicle and music facets, and are not silent; whyDrowsy unchanged | unit |
| 3 | Comfort eval run, model mode (PC, Gemini) | ≥ 9 of 10 sleepy cases pass, 3 runs each; no vehicle or music call in any run | unit (eval), record result in STATUS |
| 4 | `navigate_to` fixture: 「附近的咖啡店」 with no results | One sentence suggesting a rest; no route | unit |
| 5 | Device: 「有点困了」, 「好困」, 「我快睡着了」 | She suggests a rest in one sentence; nearby coffee shops listed on screen; nothing starts; AC, windows, seat and music unchanged | D |
| 6 | Device: after row 5, 「第一个」 | Navigation to that place starts | D |
| 7 | Device: 「为什么开车容易犯困」 | She answers; no list, no car change | D |

**Trace gate.** Add `T-031k: F-09b` to `specs/trace-ids.txt` together with the first `@Test` that names T-031k.

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031k | Items 1–6; rows 1–7 | unit, eval, build, D |

## 13. She says it in her own words; code gives the facts and the rules (iOS, APPROVED 2026-11-19)

**Why.**
- **What the mentor and the owner hear.** The answers sound robotic (mentor, reported by the owner 2026-11-19). In the Zhuhai test a search that found nothing got 「换个说法」 (F-15b §51).
- **The cause is our code, not the model.** The code writes her sentence about 190 times (count at 8a895e9):

  | Where | Count | Example |
  |---|---|---|
  | `advice:` on a failure | 81 | 「没有找到这个地点。请如实说没找到，请用户换个说法。」 (`NavigationController.swift:304`) |
  | `ToolFailureAdvice` default table (from Android) | 63 | 「屏幕上的候选里没有这个名字。请如实说…」 |
  | `next: "只说一句：…"` on a success | about 48 | 「只说一句：加上了X，现在清单有N个地点。」 (`TripPlanner.swift:1157`) |
  | Base instruction | 2 rules | car and travel section: 「只说一句」; rule 3: 「工具返回 next 或 instruction 时照着做，只说一句」 |

  She does what we wrote: one fixed sentence. Each time she made something up, the fix was a script for her line.
- **PC test, 2026-11-19 (stand-in model).** There is no Gemini key on the PC, so Qwen (`qwen3.7-plus`) was given the real base instruction, the `navigate_to` description and a `NO_CANDIDATES` result in three styles, 5 runs each, for 「我想喝点咖啡」 and 「有点困了」:

  | Result style | Typical reply |
  |---|---|
  | Today's script | 「没找到附近的咖啡店，要不换个说法试试？」 |
  | A fixed line (F-15b §51 item 4 as written) | 「附近没找到咖啡店，要不要找远一点的？」 (almost the same every run) |
  | Facts (searched what, where, radius, nearest outside) | 「附近3公里内没找到咖啡店，5.2公里外有一家瑞幸咖啡（拱北口岸店），要去吗？」 |

  The facts style named only places in the result and called no extra tool. Gemini Live was not tested.

**Sources (checked 2026-11-19).**
- **Rasa (CALM).** Business logic is fixed; an LLM rephraser rewrites fixed responses, and Rasa names repeated fixed responses as the case where rephrasing "sounds more natural and less robotic" ([Rasa rephraser](https://rasa.com/docs/reference/primitives/contextual-response-rephraser/), [assistant tone](https://rasa.com/docs/pro/customize/assistant-tone/)).
- **Anthropic, writing tools for agents.** Tools return meaningful context for the model, designed for agents rather than as developer APIs ([Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)).
- **Home Assistant voice.** Fixed intents where a wrong target or a fake "done" matters; a generative model for the conversation around them ([guide](https://localsmarthomeguide.com/articles/echo-show-8-to-home-assistant-smart-display/)).
- **Alexa.** Tuning for accuracy made Alexa "increasingly robotic"; the goal became a system that is both deterministic and creative ([ZenML case study](https://www.zenml.io/llmops-database/transforming-a-voice-assistant-from-scripted-commands-to-generative-ai-conversation-at-scale)).

**Rule in plain words.**
- Code decides what happens, and what is true: the action, the facts, and what she may never say.
- She decides how to say it, in her own words, short.
- A tool result never contains a sentence for her to read out.

1. **One result shape (`ToolReply`, NovaKit).**
   - `facts`: the data she may use, as JSON (names, counts, distances, states, what was searched and where).
   - `may`: moves she may make on her own, as enum values with a short Chinese gloss, for example `search_wider` 「可以自己再搜远一点」, `similar_place` 「可以搜相近的地方（比如服务区、休息区）」, `offer_nearest` 「可以提议去 facts 里最近的那个」, `ask_pick` 「可以问司机选哪个」.
   - `must_not`: hard rules, enum values with a gloss, for example `claim_started` 「不要说已经开始」, `claim_done` 「不要说已经做好」, `invent` 「不要说 facts 里没有的地点、数字或时间」, `ask_rephrase` 「不要让司机换个说法」, `read_list` 「不要念屏幕上的列表」.
   - `next` stays as the field the model reads, built only by `ToolReply` from `may` and `must_not`: 「用自己的话简短地说。可以：…。不要：…。」 It never quotes a sentence to say.
   - `ToolReply.success(facts:may:mustNot:)` and `ToolReply.failure(code, facts:may:mustNot:)` replace hand-written `advice:` and `next:` strings.
2. **Base instruction (F-21 base).**
   - The car and travel section's 「只说一句」 becomes 「用自己的话，简短自然，一般一两句」. 「只按工具返回的结果回答」 stays.
   - Rule 3 becomes 「工具返回的 next 是规则，不是台词：照规则做，用自己的话说，不要照念。屏幕上已经显示的列表不要念出来。」
   - The comfort rule's example 「（例如「空调调到24度了」）」 is removed, so she does not copy it.
   - The base must stay within `maxBaseCharacters`; if it does not fit, raise the limit to the measured length and record it in STATUS.
3. **Stage 1 (T-031l): items 1–2 and not-found or failed lookups.**
   - Places: `NavigationController` 304, 394, 401, 404, 405, 711, 1044, 1057, 1103; `SavedPlaces` 70, 72, 74, 77, 85; `LiveInfoExecutor` 96, 116, 154, 210, 369, 372, 376, 395, 431, 433, 435; `TripPlanner` 378, 399, 499, 548, 894, 1124 (line numbers at 8a895e9).
   - `NO_CANDIDATES` from `navigate_to` gives `facts` `{what, around (phone|demo|city), radius_km, found: 0}`, plus `nearest_outside {name, distance_km}` when 高德's far result has one (F-16), with `may` [`offer_nearest` when there is one, `search_wider`, `similar_place`] and `must_not` [`ask_rephrase`, `invent`].
   - This replaces F-15b §51 item 4 (its fixed line). T-040y leaves item 4 to this task.
4. **Stage 2 (T-031m): "not done / not yet" and choosing.**
   - Not done or not yet (`must_not` `claim_started` / `claim_done` always): `NavigationController` 592, 677, 684, 688, 750, 753, 781, 786, 831, 844, 849, 888, 946; `OpenAppExecutor` 35; `MusicToolHandler` 60; `CameraQuestionHandler` 48, 69, 74, 75, 89, 91 (with `must_not` `describe_view`); `LiveInfoExecutor` 400; F-15b §51 item 2's `tripHidden` line.
   - Choosing (`facts` = what is on screen: count, the matching names; `may` `ask_pick`): `NavigationController` 1036, 1039, 1079, 1084, 1088, 1093, 1181, 1193, 1194, 1199, 1205, 1216, 1228, 1243; `SavedPlaces` 59, 63; `MusicToolHandler` 78; `TripPlanner` 2212, 2227, 2293.
5. **Stage 3 (T-031n): success confirmations.**
   - Every `next: "只说一句：…"`, 「只说这一句」 and 「用一句话说…」 on a success: `NavigationController` 368, 629, 822, 1069; `SavedPlaces` 92; `TripPlanner` 412, 670, 676, 979, 1050, 1065, 1080, 1095, 1101, 1133, 1148, 1157, 1688, 1701, 1731, 1829, 2260, 2276, 2284, 2298, 2322, 2381, 2385; `OpenAppExecutor` 38; `CurrentTime` 46; `VolumeController` 111; `PhoneCallHandler` 85; `CameraQuestionHandler` 86; `LiveInfoExecutor` 385 and the `ForecastWeather` next texts.
   - `facts` carry what changed (name, count, day, level, time). `must_not` keeps `read_list` where a list is on screen.
   - `TripPlanner` 1061 (「按 stops 的顺序念清单」, the driver asked to hear it) keeps its order rule as `may` `read_list_in_order`.
6. **Stage 4 (T-031o): the `ToolFailureAdvice` table.** Each of its 63 entries becomes `may`/`must_not` values with `facts` from the caller. `ToolFailureAdvice+Generated.swift` comes from the Android text: the iOS override (`iosTable`) holds the new entries and the generated file is left as it is.
7. **Kept fixed on purpose.**
   - Messages that correct the model's call and are never heard by the driver: `NavigationController` 241, `TripPlanner` 456, 462, `CurrentTime` 21, `CameraQuestionHandler` 150, `LiveInfoExecutor` 360 (use `web_search`).
   - The tone confirmation (F-21 §17 item 3, T-034d): it must not promise a different voice.
   - Code checks outside the prompt: F-06 claims and corrections, `VehicleActionPolicy`, no navigation before the driver picks, the call confirmation, I-8.
   - Ending a trip day, spoken guidance turns and the volume level itself (guidance voice, F-08) are not replies.
8. **A gate keeps scripts out.** `scripts/gates/check_scripts.py` fails on 「只说一句：」, 「只说这一句」, 「请如实说：」, 「请用户换个说法」 or 「换个说法」 in `Packages/*/Sources` and `App`, except the item 7 allow-list. It runs in `run_static.sh` from the end of stage 3 (until then it reports without failing).
9. **How each stage is proven.**
   - **Unit:** each changed result has `facts`, `may` and `must_not` as listed; `next` contains no quoted sentence and none of the item 8 phrases.
   - **Model eval (PC):** for each stage, a fixture set of 20 results (both outcomes, all groups in the stage), 3 runs each, through the base instruction and the catalog. Gemini when a Gemini key is on the PC, otherwise Qwen as stand-in, recorded as such in STATUS. Pass: every place, number and name she says appears in `facts` (100%); no `must_not` broken (0); no item 8 phrase and no reply equal to the old script (≥ 95%); at least 2 different replies over 3 runs for ≥ 80% of fixtures.
   - **Device (D):** the demo sentences, read from the record.
10. **Not changed.** Which tool runs and when; F-06 claim checks; `VehicleActionPolicy`; navigation, trip and music behaviour; the voice; F-09b §12's sleepy rule.
11. **Log.** No new lines. `toolResult` lines keep logging codes and enums only (I-8); `may` and `must_not` values are logged as their enum names.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `ToolReply.failure(.noCandidates, facts:may:mustNot:)` | JSON has `facts`, `may`, `must_not`, and a `next` built from them with no quoted sentence | unit |
| 2 | The base instruction | No 「只说一句」 in the car section; rule 3 as item 2; no comfort example; length ≤ `maxBaseCharacters` | unit |
| 3 | `navigate_to 附近的咖啡店`, 高德 none within 3 km, far result 5.2 km | `facts` with what, around, radius, found 0, nearest_outside; `may` offer_nearest, search_wider, similar_place; `must_not` ask_rephrase, invent | unit |
| 4 | Each stage 1 place (item 3) | Returns `ToolReply`; no `advice:` sentence left | unit |
| 5 | Each stage 2 place (item 4) | Not-done results carry `claim_started` or `claim_done`; choosing results carry the on-screen facts and `ask_pick` | unit |
| 6 | Each stage 3 place (item 5) | Success results carry what changed; `read_list` where a list is shown | unit |
| 7 | Each stage 4 entry (item 6) | Table entries are `may`/`must_not` values | unit |
| 8 | `check_scripts.py` on the tree after stage 3 | 0 findings outside the allow-list; a planted 「只说一句：」 fails it | unit (gate) |
| 9 | Model eval per stage (item 9) | Facts 100%, `must_not` 0 broken, ≥ 95% no script, variety ≥ 80%; recorded in STATUS with the model used | eval (PC) |
| 10 | Device: 「我想喝点咖啡」 where nothing is within 3 km | She names the nearest one with its distance, or offers a wider or similar search; no 「换个说法」 | D |
| 11 | Device: 「导航去珠海站」 then 「第五个」 with 3 on screen | She says there are 3 in her own words and asks which one; nothing starts | D |
| 12 | Device: trip cards shown, 「把第二个去掉」 three times on different trips | She confirms each change in her own words, not the same sentence each time; the list is not read | D |
| 13 | Device: 「打开空调」 with the climate tool failing | She says it did not work; never says it is on | D |

**Not verified.**
- Gemini Live's replies with this shape; the PC test used Qwen.
- Whether replies get longer while driving; row 9's eval and the record will show it.

**Trace gate.** Add `T-031l: F-09b`, `T-031m: F-09b`, `T-031n: F-09b` and `T-031o: F-09b` to `specs/trace-ids.txt` together with the first `@Test` that names each.

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031l | Items 1–3, 8 (report only), 9–11; rows 1–4, 9 (stage 1), 10 | unit, eval, build, D |
| T-031m | Item 4; rows 5, 9 (stage 2), 11, 13 | unit, eval, build, D |
| T-031n | Item 5, item 8 made failing; rows 6, 8, 9 (stage 3), 12 | unit, eval, build, D |
| T-031o | Item 6; rows 7, 9 (stage 4) | unit, eval, build |

## 14. She gets the state, the context and the tools, and decides; code keeps only the safety checks (iOS, APPROVED 2026-11-20)

**Why.**
- **What happened.** Owner 2026-11-20, ipa b5c0933:
  - 「有點困了」 got a tool call or a sentence that made no sense, not 「要不要去個咖啡廳，或者找個地方坐坐」.
  - 「想帶家人玩三天，但不知道去哪」 got a whole plan for a place the model picked, with no question.
- **What the owner wants (2026-11-20).** "the agent know the current state, the context, the available tools, let her able to decide and give response, not rule base". If the driver has decided, she follows. If not, she is proactive: she suggests something with a reason and the driver's answer steers her.
- **The cause is our text, not the model.** Each earlier complaint was fixed with a rule for one phrase, and the rules now decide for her. Audit at b5c0933:

  | Where | What it does now | Example |
  |---|---|---|
  | Base instruction, rules 4–9 (`SpeakingStyle.swift`) | Phrase → tool scripts | 「我现在在哪」 → `query_live_info kind=current_location`; 「现在几点」 → `current_time` |
  | Rule 5 + sleepy sentence (§12) | Fixed actions for feelings, 「不要反问」 | 累 → `navigate_to 附近的咖啡店` at once; 「座位有点高：座椅降低一级」 |
  | 34 tool descriptions (`ToolCatalog+Generated.swift` from Android, `ToolCatalog.swift`) | About 245 quoted driver phrases, most mapped to an action or value | `control_climate`: 「有点热」 → `adjust_temperature,value=-2`, 「不要反问」 |
  | 「不要反问」 | In `control_climate`, `control_seat`, `run_scenario`, `make_trip_list`, rule 5 | `make_trip_list`: 「没推荐过就直接凭自己的知识挑有名的景点，不要反问去哪里」 (F-15b §15 item 6) |
  | Notes from code that say what to reply | Trip arrival, corrections | 「问司机要不要现在去下一站」; 「请用一句简短的话问司机…」 |

- **What she is not told.** She gets notes for the car state (§5), the destination, the trip and screen edits. She is not told where the car is (city or district), whether it is on a highway, or the local time. To suggest 「清远，开车一个半小时」 or a service area, she must call a tool first or guess.

**Sources (checked 2026-11-20).**
- **OpenAI, function calling, "Best practices for defining functions".** "Explicitly describe the purpose of the function and each parameter (and its format), and what the output represents." "Use the system prompt to describe when (and when not) to use each function." "Include examples and edge cases, especially to rectify any recurring failures", and "Adding examples may hurt performance for reasoning models." "Offload the burden from the model and use code where possible." The "intern test": could a person use the tool with only what the model is given? ([OpenAI](https://developers.openai.com/api/docs/guides/function-calling))
- **Anthropic, define tools, "Best practices for tool definitions".** "Provide extremely detailed descriptions", "by far the most important factor in tool performance": what the tool does, when it should be used and when it shouldn't, what each parameter means. "Prioritize descriptions"; examples are an addition for complex tools. ([Anthropic docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools))
- **Anthropic, writing tools for agents.** Describe a tool "to a new hire on your team"; too many or overlapping tools distract the agent. ([Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents))
- **Google Gemini function calling.** In the default `auto` mode the model decides whether to call a function or answer; descriptions should give a clear explanation of the function's purpose. ([Google](https://aistudio.google.com/docs/function-calling); the best-practices part was read only as a summary)
- **OpenAI Model Spec.** If intent is unclear, make a safe guess, "stating assumptions and asking clarifying questions as appropriate"; "The expected benefit of clarification should justify its cost." ([model_spec.md](https://raw.githubusercontent.com/openai/model_spec/main/model_spec.md))
- **OpenAI GPT-5 prompting guide.** "Do not ask the human to confirm or clarify assumptions, as you can always adjust later" is the `<persistence>` setting for agents whose steps can be undone. Our 「不要反问」 is that setting used for actions the driver feels. ([guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide))
- **Google conversation design, Questions.** Use what you already know before asking; one narrow question per turn; give the information first, then ask. ([Google](https://developers.google.com/assistant/conversation-design/questions))
- **In-car offers.** Nuance's CES demo offers a stop ([GearBrain](https://www.gearbrain.com/car-voice-assistant-nuance-ces-2625657420.html)); Cerence Co-Pilot offers coffee ([Voicebot](https://voicebot.ai/2021/12/22/cerence-co-pilot-introduces-proactive-car-voice-assistant)); Mercedes ATTENTION ASSIST offers a rest-area search and the driver picks (§12).
- **Travel planning.** Ask-before-Plan: find what is missing, ask, then plan ([arXiv 2406.12639](https://arxiv.org/html/2406.12639v2)).

**Rule in plain words.** Code gives her the facts (car, place, time, trip, conversation) and the tools, each described like to a new colleague. She decides what to do and what to say. Code still checks every action and every claim (I-1..I-14, §4, F-09b §13). No phrase lists, no fixed replies, no 「不要反问」.

1. **Context in (code).** A `[系统] 现在` note with: city and district (reverse geocode of the phone, or the trip location per F-15b §51 item 9 while the trip cards are shown), on a highway or not when known from the route, local date and time, navigating or not, trip shown or not. Sent at session start and when one of them changes (district change, not every GPS fix). It ends 「这句不用回答」, as the other notes. It is the same kind of note as §5's car state; no new permission, no place text in the log (I-8).
2. **Base instruction rewritten in four parts**, with no phrase list:
   - **Who and where:** 小诺, a voice assistant; the driver is driving and listening, so short spoken sentences.
   - **What she has:** the `[系统]` notes are the current facts; the tools and what each does; a tool result is the only proof something happened.
   - **How she decides:** if the driver has decided (named the place, the setting, or said yes to her suggestion), do it. If not, and a guess could go the wrong way, suggest one concrete thing from what she knows, with a short reason, and ask what the driver thinks; one question per turn; do not ask what the notes or the conversation already say. 「随便」 means her suggestion. Small car changes the driver can undo at once (temperature, fan, seat) are done, not asked.
   - **Safety:** never say done without a tool result; driving first (stop when told, short during guidance); the three languages (F-05a).
   - The text is written once, from the sources above, and measured (item 5). It is not tuned by adding sentences for single phrases; a failure is fixed in the tool description or the facts given (item 3), and recorded with its eval number.
   - Length: `maxBaseCharacters` is re-measured and recorded in STATUS.
3. **Tool descriptions rewritten** (iOS override for every tool the model sees; Android's generated text stays as data):
   - Each says what the tool does, when to use it and when not, each parameter, and what the result means. 3–5 sentences, more for the trip tools.
   - No 「phrase」 → value tables, no 「不要反问」, no wording for her reply.
   - Examples only where item 5 shows a recurring failure: at most two per tool, each recorded with the eval run that needed it.
   - Values the model must not invent stay code-side (current temperature, positions, ids): the description says to use the result, not to compute.
4. **Code keeps (unchanged):** the vehicle action policy, claim guards and correction notes (their wording becomes facts under §13), `AMBIGUOUS_REFERENT`, navigation never starting before the driver's pick, `undo_last_change`, the trip planner's checks.
5. **Measured before and after (the gate for each stage).** One eval run on the PC with the live model (Gemini, user env `GEMINI_API_KEY`) and the app's real instruction, notes and tools:
   - the comfort set (F-09b §3), `NearEval` (F-15b §51), the live-info set (F-18);
   - **`AskOrActEval`** (new, multi-turn, scripted driver replies): 「有點困了」 → 「好」 / 「不用」; 「想带家人玩三天，不知道去哪」 → 「太近了」 → 「好」; 「周末带孩子去哪玩」 → 「随便」;
   - **the complaint set**: every phrase an earlier rule was written for, with what the driver expected then: 「有点热」, 「广东三天」, 「做个打卡清单」 after a recommendation, 「再低一点」, 「我现在在哪」, 「现在几点」, 「导航去珠海站」, 「第二个」, 「为什么开车容易犯困」.
   - Scoring is by behaviour, not wording: tool called or not, right tool, nothing done before agreement where the driver had not decided, a question only where the driver had not decided, claims match results.
   - Baseline first, at today's text. A stage passes when no set drops by more than 2 points, the complaint set has no new failure, and `AskOrActEval` ≥ 9 of 10 per case. Results in STATUS with the model name.
6. **Stages** (one build and phone test each, so a drop is found in one place):
   - **A:** item 1's note, `AskOrActEval`, the complaint set, the baseline run. No text change.
   - **B:** the base instruction (item 2).
   - **C:** the car tools' descriptions (climate, window, seat, music, volume, camera, call, undo, state).
   - **D:** navigation, trip and live-info tools' descriptions.
7. **Superseded.** §12 item 1's sleepy sentence; rule 5's fixed examples; F-15b §15 item 6's 「不要反问去哪里」 (removed with the `make_trip_list` text in stage D). Their acceptance rows stay as complaint-set cases (item 5).
8. **Log.** One line when the `现在` note is sent: `contextNote fields=<names>` (field names only, I-8).

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Session start in Zhuhai, then a district change, then a GPS fix in the same district | Note sent at start and on the change, not on the fix; fields as item 1; log has field names only | unit |
| 2 | Trip cards shown | The note's place is the trip location (F-15b §51 item 9) | unit |
| 3 | `AskOrActEval` and complaint-set definitions and scorer | Item 5's cases; scorer fails a tool before agreement and a question in a decided case | unit |
| 4 | Stage A baseline on the PC | All sets run; numbers in STATUS | eval (PC) |
| 5 | The base instruction after stage B | Four parts; no quoted driver phrase mapped to a tool; no 「不要反问」; length recorded | unit |
| 6 | Every model-visible tool description after stages C and D | No 「不要反问」; no 「phrase」 → value table; examples ≤ 2 per tool, each listed in STATUS with its eval run | unit |
| 7 | Eval after each of stages B, C, D | Item 5's pass line against the baseline | eval (PC) |
| 8 | Device: 「有點困了」, then 「好」 | She offers a rest in her own words with a reason; nothing starts before 「好」; then nearby places to pick | D |
| 9 | Device: 「想带家人玩三天，不知道去哪」 → 「太近了」 → 「好」 | One place with a reason, then another, then the plan; no plan before 「好」 | D |
| 10 | Device: 「有点热」, 「准备一个广东三天的旅游行程」, 「导航去公司」 | Acts at once, no question | D |

**Not verified.**
- Whether Gemini Live keeps to one question per turn over a long drive; the record will show it.
- How much the base and tool text costs per turn after the rewrite; measured in stage B (F-21 §14).

**Trace gate.** Add `T-031p: F-09b`, `T-031q: F-09b`, `T-031r: F-09b` and `T-031s: F-09b` to `specs/trace-ids.txt` together with the first `@Test` that names each.

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-031p | Stage A: items 1, 5, 8; rows 1–4 | unit, eval |
| T-031q | Stage B: item 2; rows 5, 7, 8 | unit, eval, build, D |
| T-031r | Stage C: item 3 for the car tools; rows 6, 7, 10 | unit, eval, build, D |
| T-031s | Stage D: item 3 for navigation, trip and live-info tools, item 7; rows 6, 7, 9, 10 | unit, eval, build, D |

### 14E. Stage E: she decides, code runs the step (owner request 2026-11-20)

**Why.** Owner 2026-11-20: "you actually can build some deterministic code here that let llm decide to call". Stages A–D let her decide; stage E gives her three tools whose steps run the same way every time, so "nothing before the driver agrees" and "real places with real drive times" are done by code, not hoped for.

**Sources (checked 2026-11-20).**
- **Rasa CALM.** The LLM picks a flow by its description; inside the flow, code runs fixed steps (collect missing information, conditions); "LLMs keep the conversation fluent but don't guess your business logic". ([CALM](https://rasa.com/docs/learn/concepts/calm/), [flows](https://rasa.com/docs/reference/primitives/flows), [command generator](https://rasa.com/docs/pro/customize/command-generator))
- **Home Assistant.** The LLM picks a tool; the tool runs Home Assistant's own intent handlers; the tool list is built per request. ([developers](https://developers.home-assistant.io/docs/core/llm/))
- **Ask-user tools.** Asking is itself a tool: the model calls `ask_user(question, options)`, the runtime shows it and waits, the answer comes back as the result; use it sparingly or the agent becomes a form. ([Spring AI](https://spring.io/blog/2026/01/16/spring-ai-ask-user-question-tool/), [TrueFoundry](https://www.truefoundry.com/docs/agent-platform/agent-harness/ask-user-questions), [LangChain](https://reference.langchain.com/python/deepagents-cli/ask_user/ASK_USER_TOOL_DESCRIPTION))
- **LangGraph human-in-the-loop.** Code pauses a tool whose required details are missing and asks; an open ask tool for general questions plus code checks for details that must never be filled in silently (the second part is a forum post). ([docs](https://docs.langchain.com/oss/python/langgraph/human-in-the-loop), [interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts), [forum](https://forum.langchain.com/t/what-is-the-right-way-to-conditionally-interrupt/4637))
- **Anthropic, Building effective agents.** Predefined code paths for well-defined tasks; model-directed where flexibility is needed. ([Anthropic](https://www.anthropic.com/research/building-effective-agents))

1. **`offer_choices` (new tool).** She calls it when she decides the driver has not decided.
   - Arguments: `question` (her words); `options`, 1–3 items of `label`, `reason`, and `action` = one of `navigate_to {place_id}`, `make_trip_list {place, days}`, `none`.
   - Code shows the options as cards and keeps the offer open for 120 s (`Tuning.offerOpenSeconds`). The driver's next turn is matched before it reaches her:
     - 「好」「可以」「行」 with one option, or 「第N个」, or a label word → that option;
     - 「随便」「你定」「都行」 → option 1;
     - 「不要」「不用」「都不要」 → declined;
     - anything else → no match; the turn goes to her as usual and the offer stays open.
   - On a pick, code runs the option's `action` itself; a tap on a card is the same pick.
   - Result to her (§13 facts): `picked` {label, action result} / `declined` {round} / `timeout`. Three declined rounds in a row: `may` [ask_what_kind], `must_not` [offer_again].
   - **Check:** while an offer is open, a direct `navigate_to` or `make_trip_list` call is refused with `OFFER_OPEN` (`may` [wait_for_pick]); the action runs only through the pick.
   - The matching words are a fixed list in NovaCore for the answer to an open offer only (§7's withdrawn word lists judged what she should do; this one reads a pick, as `choose_navigation_option` reads 「第N个」).
2. **`suggest_destinations` (new tool).**
   - Arguments: `days` (1–7), `max_drive_hours` (optional, default 3 for ≤ 3 days, else 6), `interests` (optional strings).
   - Code: from the `现在` note's location (item 1 of §14), a fixed data table in NovaCore of cities and scenic areas (name, coordinate, country, tags such as 亲子, 山水, 美食, 海边, 温泉); drive times from the route service already used by the trip planner, cached per origin district for a day; returns up to 5 within `max_drive_hours`, best tag match first: name, drive minutes, tags.
   - The table covers mainland China, Hong Kong and Macau at first; abroad returns `NO_CANDIDATES` with `may` [suggest_from_knowledge] and she says the drive time is not checked.
3. **`find_rest_stop` (new tool).**
   - Argument: `kind` = `any` | `coffee` | `service_area`.
   - Highway with a route running: the next two service areas ahead on the route through `AlongRouteCorridor`, with distance and minutes.
   - Otherwise: the nearest 2–3 coffee shops or rest places around the `现在` location through the existing nearby search (F-15b §51 item 9 for the trip location), with distance.
   - Each result has the `place_id` that `offer_choices` and `navigate_to` take. Nothing is shown and nothing starts.
4. **`make_trip_list` without a place.** A call with no place the driver named or picked (no `places`/`days`, or the driver's turns name no place) returns `DESTINATION_MISSING` with `may` [suggest_destinations, offer_choices]; nothing is planned. With a place named (「广东三天」) nothing changes.
5. **Descriptions** follow stage C/D's form (what, when, when not, parameters, result). `offer_choices`: "use when the driver has not decided and a wrong guess would go the wrong way; not for car comfort changes or when the driver named what they want".
6. **Log.** `offer opened n=<count>`, `offer picked index=<i> by=<voice|tap>`, `offer declined round=<r>`, `offer timeout`, `offer refused tool=<name>`, `restStop source=<route|nearby> n=<count>`, `suggestDestinations n=<count>`. No place names (I-8).

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 11 | Offer open with 2 options; driver says 「第二个」, 「清远那个」, 「随便」, 「都不要」, 「今天天气怎么样」 | Option 2; option with 清远; option 1; declined; no match (turn goes to her, offer stays open) | unit |
| 12 | Offer open; model calls `navigate_to` directly | `OFFER_OPEN`, nothing starts | unit |
| 13 | Offer open 121 s | `timeout`; cards removed | unit |
| 14 | Pick an option with `navigate_to {place_id}` | Code starts navigation to that place; result `picked` with the navigation result | unit |
| 15 | Three declined rounds | Result has `may` ask_what_kind, `must_not` offer_again | unit |
| 16 | `suggest_destinations days=3 interests=[亲子]` from Zhuhai with fixed drive times | ≤ 5 places within 3 h, 亲子 first, drive minutes from the fixture | unit |
| 17 | `find_rest_stop` on a highway route fixture; and in a city | Two service areas ahead with distance; nearest coffee shops with distance | unit |
| 18 | `make_trip_list` with no place in the driver's turns | `DESTINATION_MISSING`; nothing planned | unit |
| 19 | §14 item 5 eval with stage E tools | Not decided: `offer_choices` before any action ≥ 9 of 10; decided: no `offer_choices` | eval (PC) |
| 20 | Device: 「有點困了」 on a highway route → 「好」 | She offers the next service area with its distance; navigation starts after 「好」 | D |
| 21 | Device: 「想带家人玩三天，不知道去哪」 → 「太近了」 → 「第一个」 | Cards with real drive times; a farther set; the plan for the picked place | D |
| 22 | Device: offer open, tap a card | Same as saying it | D |

**Not verified.** How often Gemini reaches for `offer_choices` when the driver has decided; row 19 measures it.

**Trace gate.** Add `T-031t: F-09b` to `specs/trace-ids.txt` together with the first `@Test` that names T-031t.

| Task | Scope | Verify |
|---|---|---|
| T-031t | Stage E: items 1–6; rows 11–22 | unit, eval, build, D |

## 15. Her setup has a version, and every record says which one (iOS, APPROVED 2026-11-20)

**Why.** Owner 2026-11-20: "this system would have a version assigned by the system rule setting; after build into app it would record the log labelled with that version". Records are collected and read for patterns (F-12 §21). A build commit alone does not say whether her behaviour changed: many builds change only audio or UI. Comparing her behaviour needs a version of what shapes it.

**Sources (checked 2026-11-20).**
- **Langfuse.** Every prompt change is a new, unchangeable numbered version; each generation links to the version it used; metrics are grouped per version; a label such as `production` points at a version and moving it back is a rollback. ([version control](https://langfuse.com/docs/prompt-management/features/prompt-version-control), [link to traces](https://langfuse.com/docs/prompt-management/features/link-to-traces), [at scale](https://langfuse.com/resources/engineering/prompt-management-at-scale))
- **MLflow Prompt Registry.** Git-like: unchangeable versions with a commit message and a diff; lineage from a prompt version to the application version. ([MLflow](https://mlflow.org/docs/3.5.0/genai/prompt-registry), [Databricks](https://docs.databricks.com/aws/en/mlflow3/genai/prompt-version-mgmt/prompt-registry/track-prompts-app-versions))
- **OpenTelemetry GenAI conventions** (status Development). `gen_ai.agent.version`, `gen_ai.request.model`; guides add `gen_ai.response.model`, because the model that answered can differ from the one asked. ([registry](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/), [agent spans](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-agent-spans.md), [explainer](https://www.dash0.com/knowledge/opentelemetry-genai-semantic-conventions-explained))
- **Not taken from Langfuse:** changing the live prompt from a server. Her setup stays in the app build (App Store guideline 2.5.2 on changing features after review; the safety rules are tested against the exact texts).

**Rule in plain words.** What shapes her behaviour has a version number in a registry file and a fingerprint the app computes from what it really sends. A test fails when the fingerprint changes without a new version. Every record names the version, the fingerprint and the model.

1. **Her setup** (`AgentSetup`, NovaCore) is, in a fixed order:
   - the model id requested;
   - the base instruction as sent, for each value of the session settings that change it (speaking style, comfort mode, web search on or off, language);
   - every tool the model can see: name, description, parameter schema, in catalog order, for each such setting;
   - the `[系统]` note templates (with their variable parts as placeholders);
   - behaviour values in `Tuning` that she acts on (marked `// agentSetup` in `Tuning.swift`; e.g. `offerOpenSeconds`, the suggestion limit).
   - Not in it: audio, UI, network and log code; keys.
2. **`agentHash`.** SHA-256 over item 1's parts as UTF-8 with a separator, first 12 hex characters. Computed at session start from the texts actually sent, for that session's settings (`agentHash`), and in the test for all settings combined (`agentSetupHash`).
3. **Registry `specs/contracts/agent-versions.md`.** One row per version, newest first: `agentVersion`, `agentSetupHash`, date, first commit, a one-line note, the spec sections. `AgentSetup.version` in code equals the newest row. This section starts at `1.0.0`, the setup at the commit that implements it.
4. **Bump rules.**
   - **Major:** a tool added or removed, a tool parameter added or removed, or a whole part of the base instruction (§14 item 2's four parts) rewritten, or the model id changed.
   - **Minor:** any other text change in the base instruction, a tool description or a note template.
   - **Patch:** an item 1 `Tuning` value changed.
   - The note says which rule applied.
5. **Gate.** A unit test computes `agentSetupHash` and compares it with the registry row for `AgentSetup.version`. A different hash fails with "agent setup changed: add a version row". `scripts/gates/check_agent_version.py` (Linux, in `run_all.sh`) checks the registry: versions in order, each bump matches item 4 against the previous row's recorded parts list (the test writes `agentSetup.parts.json` next to the fixtures with each part's own hash), no row without a note and a spec section.
6. **Record and log.**
   - The record header (F-12 §21) gains `agentVersion <v>`, `agentHash <h>`, `model <requested>` after the `app` line; and a `model-served <name>` line when Gemini's setup or first response names the model that answers, if it names one. This is a header change, so F-12 §21's `recordFormat` goes up by one.
   - `RuntimeLog` gets one line at session start: `agent version=<v> hash=<h> model=<requested>` (no text, I-8).
   - The field names follow OpenTelemetry: `agentVersion` = `gen_ai.agent.version`, `model` = `gen_ai.request.model`, `model-served` = `gen_ai.response.model`.
7. **PC side.** F-12 §21's reader returns `agentVersion`, `agentHash` and `model` with every row; `index.csv` gains the three columns. Reports compare by `agentVersion` (several builds can share one). A record whose `agentHash` matches no registry row for its version is flagged `setup=unregistered` (a debug build).
8. **Rollback** is a rebuild at an older commit (Codemagic); the registry row shows which.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `AgentSetup` for each session-setting combination | Parts in item 1's order; audio, UI and keys not included | unit |
| 2 | One character changed in a tool description, version unchanged | Gate test fails with "agent setup changed" | unit |
| 3 | Same, with a minor row added to the registry | Passes | unit |
| 4 | A tool added with only a minor row | `check_agent_version.py` fails (major required) | unit (gate) |
| 5 | A marked `Tuning` value changed, patch row added | Passes; an unmarked value changed: hash unchanged | unit |
| 6 | Session start | Record header has `agentVersion`, `agentHash` for that session's settings, `model`; `RuntimeLog` line has no text | unit |
| 7 | `read.py` on a record with the new header | Rows carry the three fields; index has the columns; an unknown hash flagged `setup=unregistered` | unit (PC script test) |
| 8 | Device: one session with speaking style changed between two sessions | Two records, same `agentVersion`, different `agentHash` | D |

**Trace gate.** Add `T-031y: F-09b` to `specs/trace-ids.txt` together with the first `@Test` that names T-031y.

| Task | Scope | Verify |
|---|---|---|
| T-031y | Items 1–8; rows 1–8 | unit, gate, build, D |

## 16. She gets the screen state: every panel on or off, from what the display really shows (iOS, APPROVED 2026-11-20)

**Why.** Owner phone test 2026-11-20, ipa e195ea4 (records `20261120-170741`, `-170902`, `-171536`):
- 「明明没有音乐却说音乐放起来了」, three times. `control_music play` answered `status=playing` once the player node
  was started; nothing checked that sound came out. When the driver said 「我没听到」 she said 「我再试一次」 and
  called nothing.
- 「把这个东西收起来」 / 「停止导航」 on the candidate list and the route-picking page: her note says only
  正在导航 / 没在导航 (§14 item 1), so she did not know which page was open.
- 「介绍一下这个地方」 should show a picture and text; she said 「我无法直接向您展示图片」.
- The record has no screen state, so what she was told could not be compared with what the driver saw.

**Owner rule (2026-11-20).** The state she gets is made each time something really changes on the display. Each key
is only `on` / `off`; volume is a number. Nothing else in the state: no names, counts or minutes (those come from
tool results).

1. **Keys.** One per panel `DriveView` shows, plus music:

   | Key | On when the display shows |
   |---|---|
   | `destinationList` | the candidate list (`nav.listOpen`) |
   | `routePicking` | the route choice (`nav.routeTapTargets` not empty) |
   | `routeCalculating` | the calculating / resolving state |
   | `navigation` | the guidance panel |
   | `tripScreen` | the trip cards |
   | `tripDetail` | a trip stop's detail sheet (`TripDetailSheet`) |
   | `tripPlans` | the saved-plans sheet (`TripPlansSheet`) |
   | `musicCard` | the song card (`PreviewCardView`) |
   | `camera` | the camera window |
   | `working` | the work-progress panel |
   | `settings` | the settings page |
   | `music` | sound is really coming out of the media lane (item 3) |
   | `musicVolume` | 0–10, the saved media volume |

2. **Source: the display, not the code's intent.** Each panel's view reports `on` in `onAppear` and `off` in
   `onDisappear` (App, `ScreenState` reporter). `ScreenState` (NovaCore, pure) holds the keys; a key changes only
   from that report. A flow that thinks it closed a page while the view is still shown keeps the key `on`.
3. **`music`.** `on` only when the media node plays, the engine runs, `musicVolume` > 0 and a tap on the media mixer
   measures an RMS above `Tuning.mediaAudibleRms` within `Tuning.mediaCheckMs` (800 ms). Otherwise `off`.
4. **Sent to her.** One line, every key, fixed order:
   > [系统] 屏幕：destinationList off；routePicking on；routeCalculating off；navigation off；tripScreen off；tripDetail off；tripPlans off；musicCard off；music off；musicVolume 0；camera off；working off；settings off。这句不用回答。
   - On connect, and after any key changes. Changes within `Tuning.screenSettleMs` (300 ms) go as one line.
   - Never during her reply: queued and sent when the reply ends (same queue as §5 item 2), only the latest line.
   - Replaces `navigating` and `trip` in the §14 item 1 note and `音乐<在放|没放>` in the §5 note.
5. **Her instruction (one sentence, §14 item 2 「你有什么」).** 「屏幕状态就是司机眼前看到的；"这个"指屏幕上开着的东西。」
6. **Tools answer from the screen state.** After acting, a tool waits up to `Tuning.screenConfirmMs` (1500 ms) for the
   key it changes:
   - closing a panel (`exit_navigation_mode` and the trip hide): done only when its key is `off`; else not done
     (F-09b §13) with fact `still_on=<key>`.
   - `control_music play` / `play_music`: done only when `music` is `on`; with `musicVolume` 0 not done with fact
     `musicVolume=0`; the fixed 「说一句：音乐放起来了」 is removed.
   - 「没有在导航」 only when `destinationList`, `routePicking`, `routeCalculating` and `navigation` are all `off`.
7. **Bundled song.** A real audio file `nova_drive_loop.m4a` (royalty-free, owner approves the file) ships in the App
   bundle; the generated sine loop is removed.
8. **Place card.** 「介绍一下X」 for a place on screen (candidate list, destination, trip stop) opens the same
   `TripDetailSheet` (photo + intro) through a `show_place` tool; `tripDetail` goes `on`.
9. **Record.** On every sent line: `screen <key>=<on|off> … musicVolume=<n>` (I-8: no names).
10. **One navigation phase enum.** `NovaKit/States.swift` and `NovaNav` both define `NavigationPhase`; merge into one.

**Acceptance.**

| # | Check | Expected | Kind |
|---|---|---|---|
| 1 | Unit: panel reports on/off | key follows the report only; a flow cancel without the view's `off` keeps it `on` | unit |
| 2 | Unit: line text | all keys, fixed order, on/off and a number only | unit |
| 3 | Unit: changes during her reply | one line after the reply, latest state | unit |
| 4 | Unit: play with `musicVolume` 0; node on but RMS under the floor | not done; `music off` | unit |
| 5 | Unit: close with the key still `on` after `screenConfirmMs` | not done, `still_on` | unit |
| 6 | Gate: one `NavigationPhase` | a second definition fails | gate |
| 7 | Device: candidate list, 「把这个收起来」 | list closes; record `destinationList on` then `off` | D |
| 8 | Device: route page, 「不去了」 | page closes; record `routePicking on` then `off` | D |
| 9 | Device: volume 0, 「放首歌」 | she says the volume is 0, never 「放起来了」 | D |
| 10 | Device: 「放首歌」 at normal volume | song heard; record `music=on` | D |
| 11 | Device: 「介绍一下华发商都」 on the candidate list | photo and text card; record `tripDetail=on` | D |

| Task | Scope | Verify |
|---|---|---|
| T-031z | Items 1–10; rows 1–11 | unit, gate, build, D |
