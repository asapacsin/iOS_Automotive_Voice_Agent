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
