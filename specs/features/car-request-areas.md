# F-09a Car tools only for car requests (落域)

**Status:** APPROVED (owner 2026-11-10, "Yes, build it"). iOS only. Both comfort modes.
**Depends on:** F-09 (dispatch and guards), F-05a §6 and §12 (the phone's own recognizer), F-12 §14 and §20 (comfort
modes, sleepy driver), F-06 (reply pipeline), F-04a (driver turns), contracts/voice-agent.md

## 1. Why

Device record 20261110-131646 (build 7f1ef66, model mode). The phone's recognizer heard 「好困」 every time. On the
second one, Gemini's own transcript said 「好看」, then Gemini called `control_climate` adjust_temperature −1 and
power_on, and said 「空调已打开并调低了温度。」 F-12 §20's sleepy rule was a sentence in the prompt, and Gemini did not
follow it. On the other two tries Gemini called no tool, but each time about 1 s of her audio still played.

Owner 2026-11-10: "what the hell when i said 好困 this would turn on the air conditioner". On the proposal to confirm
first: "the 豆包 setting just don't need to ask user to do something like that". On the design: "isnt only the
intention that mapping the tool would map there, and these command just outside the tool area would route to chat
area with no tool available". Then: "Yes, build it".

**Sources.**
- Volcano Engine's mass-produced Doubao cockpit uses 「意图分域+多Agent协同」: a sentence is routed to a domain first,
  and only that domain's agent acts ([36Kr](https://www.36kr.com/p/3780897368595720),
  [CSDN, Beijing auto show 2026](https://gitcode.csdn.net/69eb1c160a2f6a37c5a5d178.html)). Industry write-ups
  describe a 落域 decision on the recognized text before anything runs
  ([woshipm](https://www.woshipm.com/ai/6385938.html)).
- Arm's in-car assistant puts a rule-based guardrail in front of the model. The guardrail blocks out-of-scope commands
  before they reach the car tools, and each agent gets only the tools it needs
  ([Arm](https://developer.arm.com/community/arm-community-blogs/b/automotive-blog/posts/building-an-on-device-multimodal-assistant-for-automobiles)).
- A vehicle voice-command benchmark found that no model eliminated false executes. It concluded the LLM should not
  be the final safety authority, and recommended rule-based validators before any vehicle function runs
  ([arXiv 2609.19630](https://arxiv.org/abs/2609.19630)).

**This replaces:**
- **F-05a §6 (revised 2026-10-29), "no tool guard reads the transcript".** It is replaced for the comfort tools only,
  as set out in §2. The words used are the phone's own recognizer's final text (F-05a §12, `DriverWords.final`).
  Gemini's transcript is still never read by a guard.
- **F-12 §20 item 4, "not code-enforced".** Her silence for a sleepy driver is now code (§4).

## 2. Areas

Every closed driver utterance gets exactly one **area**, from the phone recognizer's final text of that utterance.
The text is normalized first (`TranscriptText.normalize`). The rules below run in order, and the first one that
matches decides the area.

1. **unknown.** There is no local final: the recognizer's result was `.unclear`, or none came within the wait in §3
   item 3. This keeps today's behaviour: everything is allowed.
2. **car.** The text contains a car word (contains, not whole-word):
   - climate: 空调, 温度, 风, 暖, a number followed by 度;
   - windows and seats: 窗, 座椅, 座位, 椅子;
   - heat: 热, 晒, 汗, 闷, 憋, 透不过气, 喘不过气, 蒸笼, 桑拿, 黏;
   - cold: 冷, 冻, 凉, 抖, 鸡皮疙瘩, 飕;
   - air and smell: 味, 臭, 烟, 空气, 潮, 霉, 焦;
   - insects: 蚊, 虫, 苍蝇, 蛾.
3. **tired.** The text contains a tired word and none of the exceptions:
   - tired words: 困, 累, 睡着, 想睡, 睡觉, 瞌睡, 哈欠, 眼皮, 睁不开, 点头, 昏昏, 浆糊, 疲, 乏, 撑不住;
   - not a question: no 为什么, 怎么, 什么, 吗, 呢, 如何, 是不是, ？ or ?;
   - no request for something else: no 歌, 音乐, 播放, 导航, 去, 回家, 服务区, 打电话, 打给, 帮我, 给我 or 请;
   - not 困难 or 困扰.
4. **car (follow-up).** The previous closed utterance was `car` or `car (follow-up)`, a comfort tool returned ok
   for it, and the text contains a follow-up word: 再, 还, 关, 开, 调, 一点, 掉, 上, 下, 大, 小, 高, 低, 停, 别, 算了,
   回去, 恢复.
5. **chat.** Everything else.

The lists were written after reading every F-12 comfort case, held-out ones included. So the held-out cases no longer
measure this router; the device rows (§6 row 9) and later conversation records do. A miss found on the device is
added to the list with the record that showed it.

## 3. What each area allows

1. **Comfort tools:** `control_climate`, `control_window`, `control_seat` and `run_scenario`. They run only when the
   utterance's area is `car`, `car (follow-up)` or `unknown`.
   - In `chat` or `tired` they are refused with the new code `NOT_A_CAR_REQUEST`, and nothing in the car changes.
   - The refusal's advice to the model: 「司机这句话不是车辆操作请求，没有执行。不要提这个操作，正常回应司机。」
   - A call from a tap (`fromTap`) is never refused by this rule.
2. **Every other tool keeps today's behaviour**, whatever the area. That covers navigation, music, calls, apps, saved
   places, live info, the camera, `get_vehicle_state`, `web_search`, speaking style, speech output and
   `end_conversation`.
   - Their own past word guards failed on bad transcripts (F-05a §6, run 9f48c45: 「最快的」 refused three times).
   - Giving them areas is T-017b. It starts only after this task's device rows pass and the owner asks for it.
3. **Which utterance a call belongs to.** A call belongs to the newest closed utterance.
   - If that utterance's local final has not arrived yet, a comfort call waits for it. The wait is at most
     `TranscriptSelector.Tuning.localFinalWait` (800 ms) from when the call arrived.
   - If the final still has not come, the area is `unknown` and the call runs.
   - While it waits, the turn's reply is held, as for any pending call (F-06).

## 4. Tired: no car change and no voice

1. For a `tired` utterance, nothing she produces for it is heard or shown. This covers every model turn that opens
   after that utterance closed and before the next driver utterance closes. Her audio and text are dropped in code,
   and playback queued for that turn is flushed. Comfort tools are refused (§3 item 1).
2. No empty-response re-ask (「请回应我刚才说的话」) and no correction is sent for a `tired` utterance.
3. The next driver utterance is handled normally.
4. The F-12 §20 prompt sentences and the empty `drowsy` step list stay as they are. They are now a second line of
   defence, not the only one.

## 5. Record and log

- **Record:** one line per closed utterance: `area utterance=<n> area=car|follow-up|tired|chat|unknown`.
  It holds codes and numbers only; the words are already on the `heard-local` line.
- **Refusals:** a refused call already writes `tool-result … ok=false code=NOT_A_CAR_REQUEST`.
- **Tired silence:** each silenced turn writes `tired-silenced turn=<n>`.
- **RuntimeLog:** the same codes, never text (I-8).

## 6. Acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Every F-12 comfort case expected to act or refuse, except the three music cases (playSong, stopMusic, t3MusicOff) | Area `car`. The music cases are `chat` and their music calls still run (§3 item 2) | unit |
| 2 | The ten sleepy cases (drowsy, drowsyMusicOn, fallingAsleep, t3Exhausted, hEyelids, hDizzy, h2EyesClosing, h2Yawning, h3Nodding, h3Foggy) | Area `tired` | unit |
| 3 | 讲个笑话, 讲个小故事, 明天会下雨吗, 为什么开车容易犯困, 帮我调一下, 有点困难, 好困，放首歌 | `chat` (为什么…犯困 is a question; 放首歌 is a request for something else) | unit |
| 4 | `chat` utterance, Gemini calls `control_climate` power_on | Refused with `NOT_A_CAR_REQUEST`, climate unchanged, advice sent; a `query_live_info` call in the same turn runs | unit |
| 5 | `tired` utterance; Gemini opens a turn with text and audio, then a second turn | Nothing of either turn is played or shown; no re-ask after the timeout; the next utterance 有点热 is answered and its climate call runs | unit |
| 6 | 有点热 (climate call ok), then 再低一点, then 好困 | `car`, `car (follow-up)`, `tired` | unit |
| 7 | Local result `.unclear`, or none within 800 ms of a comfort call | Area `unknown`; the call runs as today | unit |
| 8 | Tap on a comfort control while the area is `chat` | Runs | unit |
| 9 | Device, both modes: 好困 (three times), 我快睡着了; then 有点热, 开空调, 再低一点, 车窗开一半 | The first four: nothing in the car changes and nothing of her is heard or shown. The rest work as before. The record shows the `area` lines | D |
| 10 | Navigation, music and call flows (existing suites) | Unchanged | unit |

## 7. Tasks

| Task | Scope | Verify |
|---|---|---|
| T-017a | `CarRequestArea` (pure, NovaCore), area per closed utterance from the local final, comfort-tool refusal `NOT_A_CAR_REQUEST`, the call wait (§3 item 3), tired silence (§4), record lines; rows 1–10 | unit, build, D |
| T-017b | Areas for navigation, music and calls. Not started: needs the owner's request after T-017a row 9 passes | — |
