# F-21 Persona and speaking style

**Android status:** IMPLEMENTED (JVM + LIVE 5/5).
**Depends on:** F-09

## 1. Purpose
Persona 小诺 with switchable tones that never stop her doing the task.

## 2. User-facing behaviour
说话嗲一点/傲娇一点/温柔一点/元气一点/正常一点 change tone; 霸道一点 is refused with the list of styles.

## 3. Preconditions
None; the default style is 正常.

## 4. Inputs and outputs
- In: `set_speaking_style(style ∈ {嗲, 傲娇, 温柔, 元气, 正常})`; others → `STYLE_NOT_ALLOWED` and she lists
  the allowed ones.
- Out: persisted style (`SettingsKey.personaStyle`, UserDefaults) and the system instruction for the next
  session setup (persona base + style block, ≤ 4000 chars). The settings screen can change it too.

## 5. State transitions
current style → new style; takes effect from the next turn (instruction update) or the next session setup.
iOS: a change applies at the next session set up without a resumption handle (§17, T-034d). The mid-session
instruction update of §16 (T-034c) is withdrawn.

## 6. Events and triggers
`set_speaking_style` tool call; settings change.

## 7. Dependencies and external services
Gemini Live system instruction (F-05); Azure voice for revoicing when configured (F-07).

## 8. Error handling and recovery
Unknown style → `STYLE_NOT_ALLOWED`, style unchanged. A style never overrides a safety rule or skips a
requested action; tool rules sit above the style block.

## 9. Concurrency, cancellation, timeouts
The style write is synchronous; a change during a reply applies from the next reply.

## 10. Acceptance criteria (iOS)
- Style persists across sessions.
- Instructions capped at 4000 chars.
- After a style change, an action request is still executed.

## 11. Existing Android tests
`T/PersonaProfilesTest`, `SpeakingStyleTest`, `SpeakingStyleStoreTest`, `tools/SpeakingStyleToolTest`.

## 12. Source references (Android)
`A/PersonaProfiles.kt:4-6,31,36-49`; `A/SpeakingStyle.kt:4`; `A/SpeakingStyleStore.kt:7`; `A/tools/SpeechDomain.kt:13`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Portable (A); store in UserDefaults.

## 14. Base instruction scope: strict for the car, natural for everything else (iOS, APPROVED 2026-10-30)

**Why.** Device run 25a5cd9 (2026-10-30): 「介绍一下珠海」 got a short "no information" answer, and no reply in the session
was longer than ~6 s, so checklist row 5-02 (interrupt a long reply) could not even start. Cause: the base instruction
(`Persona.instruction`, App/NovaDrive/AgentRuntime.swift) applies car-control rules to every topic: 「一般一两句话」 caps
every answer, rule 1 「只按工具返回的结果回答」 and rule 8 「不知道的事情如实说不知道」 push general questions towards a
refusal although the model knows the answer. Community review 2026-10-30: car assistants keep car functions strict and
let the LLM answer everything else freely (Volkswagen IDA and Mercedes MBUX: car commands to the car's own system,
general questions to ChatGPT in the same voice, the LLM never controls the car); Gemini Live and OpenAI Realtime prompt
guides: persona → conversation rules → guardrails, short, say exactly when each tool is used, no conflicting rules.
NovaDrive already has the strict half in code (tools validated by the app, I-1, F-09 claim check), so no arbitration
layer or second model is added: only the instruction's scope changes. Owner 2026-10-30: "Yes, spec it".

**Rule in plain words.** For the car she is strict: tool first, only what the tool says, never a claim without a result.
For anything else she answers like a knowledgeable passenger: from her own knowledge, naturally, a few spoken sentences.

1. **Two scopes, written as such.** The base instruction has a persona line, then two labelled scopes, then guardrails:
   - **车辆与出行（严格）:** climate, windows, seats, navigation, places to drive to, weather, traffic, current location,
     music, phone, saved places, speaking mode. Always call the tool; answer only from its result; never say something
     was done without an `ok` result (I-1). Rules 2–7 of today's instruction stay in this scope with their wording.
   - **其他问题（自然回答）:** general knowledge, places and history (「介绍一下珠海」), how things work, advice, small talk.
     Answer from her own knowledge, no tool needed, in about 3–5 short spoken sentences; if the driver asks for more
     (「详细一点」「继续」), continue. She says she is unsure only when she is, and never invents numbers, names or facts.
2. **Live facts.** For things that change (news, opening hours, prices, today's events, scores) she says in one sentence
   that she cannot check live information right now and, if useful, gives what she generally knows, marked as possibly
   out of date. (A web-search tool is out of scope; a later spec may add Gemini's Google Search tool.)
3. **Length by scope.** Car scope: one sentence (unchanged, the tool's `next` text). Other scope: 3–5 sentences by
   default. Always spoken style: no lists, no headings, no emoji, short sentences.
4. **Guardrails, last.** Driving first: if the driver seems busy (guidance speaking, manoeuvre), keep it short; 别说了
   stops her at once (F-08 §14); she never asks the driver to look at the screen for long text; Mandarin only.
5. **Speaking style still applies.** `PersonaInstruction.build` keeps appending the chosen style (§1–§10); the scope text
   is part of the base, not of a style.
6. **Size.** The whole base instruction stays ≤ 1 500 characters (it is billed every turn and must stay well under the
   4 000-character limit with the style appended).
7. **Code checks unchanged.** No guard, tool or `ActionClaimGuard` (F-09) rule changes. A general answer that contains
   no action claim is never held or corrected; if F-09 flags a general answer, that is a bug to fix in F-09's claim
   patterns, not a reason to restrict the prompt.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Base instruction text | Contains both scope labels; rules 2–7 wording kept in the car scope; ≤ 1 500 characters; no 「一般一两句话」 rule over all topics | unit (string checks) |
| 2 | Recorded Gemini session (`GeminiRecorder`) or live: 「介绍一下珠海」 | A real introduction of 3–5 sentences (≥ 12 s of speech); no refusal; no tool call | S / D |
| 3 | 「珠海有什么好玩的」, 「为什么天是蓝的」, 「讲个笑话」 | Natural answers, no refusal, no tool call | D |
| 4 | 「详细一点」 after row 2 | She continues with more detail | D |
| 5 | 「今天珠海有什么新闻」 | One sentence that she cannot check live information; no invented news | D |
| 6 | Car scope unchanged: 「打开空调」 with the vehicle tool failing (simulated fault), 「导航去珠海站」, 「我在哪」 | Tool called; failure said honestly, never 「已打开」; navigation and location as today | unit (scripted provider) + D |
| 7 | A general answer during the session | No `claimHeld` / `correctionSent` for it in the log | D (log) |
| 8 | Checklist 5-02 (long reply + 别说了) | Can be run: the reply is long enough to interrupt | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-034a | §14 items 1–7: rewrite `Persona.instruction` into persona → car scope (strict, rules 2–7 kept) → other scope (natural, 3–5 sentences, live-facts sentence) → guardrails; ≤ 1 500 characters; string tests; device rows | unit, S, D (rows 2–8) |

## 15. Camera questions belong to the strict scope (iOS, APPROVED 2026-10-31)

**Why.** Device run ac53787 (2026-10-31 13:36–13:40): camera questions such as 「前面是什么」 never opened the camera.
Log: no camera start, no 看画面中…, no `describe_camera_view` result; instead `claimHeld` ×5, `correctionSent` ×1 and
`turnUnanswered` ×2, i.e. she answered without a tool and the F-09 claim check stopped her. Cause: §14's base
instruction lists the tool topics in 【车辆与出行（严格）】 without the camera, and 【其他问题（自然回答）】 says
「不用工具，凭自己的知识回答」, so a camera question lands in the no-tool scope. The camera feature itself is
implemented (F-20 / F-20a: `describe_camera_view` in the catalog, `CameraQuestionHandler`, `ObservedCameraExecutor`,
camera window); it was never reached on a device. The old instruction did not mention the camera either but had no
"no tools" rule, so the model found the tool on its own. Owner 2026-10-31: "write this on the spec".

**Root cause in the spec process.** The gap came from §14 itself (T-034a, written 2026-10-30): its strict-scope topic
list was written by hand and not checked against the tool catalog, so an existing tool (`describe_camera_view`) was
left in the no-tool scope; the implementation followed the spec exactly. Item 6 adds a test so that a future prompt
change cannot lock out a catalog tool again. Owner 2026-10-31: "ok write this in spec".

**Approach decision (community review 2026-10-31).** Two patterns exist: (A) take one photo when asked (Meta Ray-Ban
"look" phrase → photo → analysis → spoken answer; LiveKit snapshot-on-demand tool calls) and (B) stream camera frames
into the realtime model continuously (Gemini Live video input, at most 1 frame/s; LiveKit live-video mode). Owner
2026-10-31: "A. Take a photo when asked probably i prefer this one". NovaDrive keeps (A), which F-20 / F-20a already
implement: model calls `describe_camera_view` → one still → vision service (Gemini vision when a Gemini key is set,
else Qianfan; `PreferredVision`) → text result → she speaks. (B) is
out of scope: per-frame cost, a camera that uploads all the time in a car, and video filling the session context. This
section only fixes the trigger (when she decides to look); an app-side keyword trigger is added later only if device
rows 2–3 still miss after this change.

**Rule in plain words.** Anything about what the camera sees is a tool question: she always looks through the camera
first and answers only from what the camera answer says. She never describes a scene from her own knowledge.

1. **Add the camera to the strict scope.** The 【车辆与出行（严格）】 topic list gains 「摄像头画面」, and one rule
   line is added beside rules 2–7, in this wording (or shorter with the same meaning):
   「8. 问摄像头、前面/后面/周围有什么、看看画面、这是什么车/什么牌子这类要看画面才能回答的问题：一定调用
   describe_camera_view（question 填用户原话；说后面、倒车时 camera=rear），只按返回的结果回答；工具失败就照实说
   看不到，不要猜。」
2. **Keep the other scope from catching it.** 【其他问题（自然回答）】 gains 「（要看画面的问题除外）」 after 「不用工具」,
   so the two scopes do not conflict (Gemini/OpenAI prompt guides: no conflicting rules).
3. **Size.** The base stays ≤ 1 500 characters (it is about 860 today).
4. **Nothing else changes.** No change to the camera code, the tool schema, the F-09 claim patterns or the tap path
   (camera window 「问一问」 button, which never goes through the prompt). No video is streamed to Gemini (approach B
   stays out).
5. **Diagnostics.** If not already logged, log `toolCall name=describe_camera_view` and its result code (no image, no
   answer text), so a device log shows whether the model asked for the camera.
6. **Every catalog tool is covered by the instruction (guard test).** A unit test reads the tool names from
   `ToolCatalog` (the generated catalog, not a hand-copied list) and a coverage table kept next to the test that maps
   each tool name to the phrase in the base instruction that sends her to it (a topic in 【车辆与出行（严格）】 or a rule
   line naming the tool, e.g. `describe_camera_view` → 「摄像头画面」 / rule 8, `query_live_info` → 「天气」「当前位置」 /
   rule 7, `navigate_to` → rule 6). The test fails when:
   - a catalog tool has no row in the table (a new tool was added without deciding how the prompt reaches it), or
   - a row's phrase is not found in `PersonaInstruction.base` (the prompt was edited and dropped it).
   A tool that is deliberately never reached by voice (if any) is listed with the reason `notByVoice: "<why>"` instead of
   a phrase, so excluding a tool is an explicit, reviewed choice. The failure message names the tool and says to add it
   to the strict scope or mark it `notByVoice`.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Base instruction text | Strict scope lists the camera; rule 8 names `describe_camera_view`; other scope excludes camera questions; ≤ 1 500 characters; §14 row 1 checks still pass | unit (string checks) |
| 2 | Recorded or live session: 「前面是什么」 | `describe_camera_view` called with `question` = the utterance; no `claimHeld` for it | S / D (log) |
| 3 | Device: camera window open, 「前面是什么」「这是什么车」「后面有什么」 | Camera opens if closed, 看画面中…, answer from the picture; 「后面」 uses the rear lens | D |
| 4 | Device: camera permission denied, 「前面是什么」 | Tool called; she says she cannot see (permission), never a made-up scene | D |
| 5 | Device: 「介绍一下珠海」 after this change | Still a natural answer with no tool (§14 row 2 unchanged) | D |
| 6 | Device: camera window 「问一问」 button | Answer shown and spoken (tap path, independent of the prompt); if this fails, it is a camera/vision bug, not this task | D |
| 7 | Guard test with today's catalog | Passes: every catalog tool has a row whose phrase is in the base (or `notByVoice` with a reason) | unit |
| 8 | Guard test after removing 「摄像头画面」 and rule 8 from a copy of the base, or adding a fake tool to a copy of the catalog | Fails and names `describe_camera_view` / the fake tool | unit |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-034b | §15 items 1–6: camera topic and rule 8 in the strict scope, exclusion in the other scope, ≤ 1 500 characters, `toolCall` diagnostic, catalog-coverage guard test; string tests rows 1, 7, 8; device rows 2–6 | unit, S, D (rows 2–6) |

## 16. A new tone applies at once, in the same conversation (iOS, APPROVED 2026-11-10)

**Status:** WITHDRAWN 2026-11-10 by §17 (owner: "just write spec to remove this feature"). Kept for the record;
nothing in §16 is built any more. Was APPROVED (owner 2026-11-10: "write the spec"; order A chosen: "probably i
prefer a").
**Depends on:** §1–§10, F-05 (session setup and resumption), F-24 §15 (handle kept after a give-up),
contracts/api-contracts.md (Gemini).

**Why.** The saved tone is read only when a session starts (`PersonaInstruction.build` in
App/NovaDrive/AgentRuntime.swift, comment 「the saved tone is read once here, at session start」). After 「说话嗲一点」
only her confirmation is sweet, because the tool result hands her a sample line. The instruction for the rest of the
conversation still carries the old style block. §5 ("from the next turn (instruction update)") was never built on iOS.
Owner 2026-11-10 asked how 豆包 does it and whether the community sets this up. Azure revoicing is out of scope: the
owner said it is already removed on another branch (2026-11-10).

**Sources (community review 2026-11-10).**
- 豆包's realtime voice API sets the tone with `speaking_style`, plain persona text such as 「你口吻拽拽的。」, and
  replaces it during a call with the `UpdateConfig` event. It has no emotion parameter
  ([Volcano Engine](https://www.volcengine.com/docs/6561/1594356)).
- Google's SDK google-genai v2.33.0 (2026-10-22) adds `send_context_update(system_instruction=, tools=)`. It sends the
  client message `contextUpdate`, and the Gemini API gets the same message as Vertex. Updates "are guaranteed to be
  processed *in order* with the rest of the inputs". Updating the instruction "invalidates the prefix cache"
  ([python-genai live.py](https://github.com/googleapis/python-genai/blob/main/google/genai/live.py),
  `types.LiveClientContextUpdate`). The ai.google.dev Live reference does not list it yet (checked 2026-11-10).
- Pipecat ([#6476](https://github.com/pipecat-ai/pipecat/pull/6476), open) uses this update on `gemini-3.8-live` to
  change the instruction without a reconnect. After a resumed reconnect it sends the instruction again when it differs
  from the session's original setup, because a resumption handle is not documented to carry later updates.
- LiveKit ([#7944](https://github.com/livekit/agents/pull/7944), merged 2026-11-03) found that on `gemini-3.8-live` a
  session resumed from a handle keeps its original instruction and tools and ignores the new setup. So a reconnect
  with the handle cannot change her tone.
- No source publishes how much the update delays the next reply (Pipecat, LiveKit, Google SDK; checked 2026-11-10).

**Rule in plain words.** When the tone changes during a conversation, the app gives Gemini her new instruction on the
same connection, right after she has said the confirmation. From her next reply on she speaks in the new tone. Nothing
reconnects, and the conversation is kept. The first reply after the change may start a little later, once.

1. **What is sent.** The whole instruction, rebuilt as `PersonaInstruction.build(base:style:)`. The base is the one
   the session was set up with, so comfort mode and web search stay as they were; only the style block differs. The
   wire message is `{"contextUpdate": {"systemInstruction": {"parts": [{"text": "<instruction>"}]}}}`. `tools` is
   never sent, because the tool list does not change.
2. **When: after her confirmation (order A).** The update goes out when the turn that answers the
   `set_speaking_style` result ends, at its `turnComplete` or `interrupted`. It is not sent before the tool result, and
   not while she is still generating the confirmation. The confirmation stays as today: the tool's sample line, already
   in the new tone. If the connection closes first, nothing is sent; the next setup reads the saved style as today.
3. **Only when something changed.** The app tracks the instruction the server holds: the setup's, then each update it
   sent. An update is sent only when the new instruction differs from that. The same tone again (「嗲一点」 while
   already sweet), `STYLE_NOT_ALLOWED` or a failed tool call sends nothing, because every update costs one slower reply.
4. **Settings screen.** A tone picked in 设置 while a session is running takes the same path. It is sent at once when
   she is not replying, or else when her current reply ends.
5. **After a reconnect with a handle (copied from Pipecat).** The app keeps the instruction of the setup that began
   the resumption chain: the first setup sent without a handle, or for a give-up resume (F-24 §15) the one kept with
   that handle. It is in memory only, like the handle. When a connection set up with a handle reaches `setupComplete`
   and the current instruction differs from that original, the update of item 1 goes out before any audio or text. A
   connection set up without a handle needs nothing, since its setup already holds the current tone.
6. **Only on a model that has it.** The update is sent only when `SessionConfig.model` is `gemini-3.8-live`. On any
   other model the tone applies at the next session as today.
7. **No acknowledgement.** The API documents none. If the server closes the connection within 2 s of an update with a
   non-retryable error (`MALFORMED`, 1007 or 1008 not about resumption), updates stop for the rest of the app run and
   the normal reconnect follows. This keeps item 5 from looping.
8. **Record and log.** `style-update sent style=<raw> chars=<n> reason=tool|settings|resume`;
   `style-update skipped reason=same|model|disabled`; `style-update rejected code=<code>`. Codes and numbers only;
   RuntimeLog the same (I-8). The delay is read from lines the record already has: `utterance` to the next
   `playback started`.
9. **Nothing else changes.** The tool schema, the sample confirmation lines, the style block wording, the
   4 000-character cap, the base size and the voice name stay as they are.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Encode an update | Exactly the item 1 JSON; no `tools` key | unit |
| 2 | Scripted provider: `set_speaking_style` sweet ok, then the reply turn | No update before that turn's `turnComplete`; one update after it, with the session's base unchanged and the sweet block | unit |
| 3 | Same tone again; `STYLE_NOT_ALLOWED` | Nothing sent; `style-update skipped reason=same` for the first | unit |
| 4 | The confirmation turn ends with `interrupted` | Update sent at `interrupted` | unit |
| 5 | `setupComplete` on a connection set up with a handle, current ≠ original; current = original; set up without a handle | Update before the first audio frame; nothing; nothing | unit |
| 6 | Model `gemini-3.1-flash-live-preview` | Nothing sent; `style-update skipped reason=model` | unit |
| 7 | Server closes with `MALFORMED` 1 s after an update, then another tone change | `style-update rejected`; the later change is `skipped reason=disabled`; no repeated updates after the reconnect | unit |
| 8 | Tone changed in 设置 while listening; while she replies | Sent at once; sent when that reply ends | unit |
| 9 | Device: 「说话嗲一点」, then 「今天天气怎么样」, 「开空调」, 「讲个笑话」, then 「正常一点」, 「讲个笑话」 | The three replies after 嗲 are sweet; the AC turns on; the last reply is normal; the record has two `style-update sent` | D |
| 10 | Device, row 9's record | `utterance` → `playback started` ms of the first reply after each update, and the median of the other replies, written to STATUS. No pass threshold: the owner judges whether it is noticeable | D |
| 11 | Device: after 嗲, airplane mode for 5 s, then 「讲个笑话」 | Still sweet; the record has `style-update sent reason=resume` | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-034c | §16 items 1–9: `contextUpdate` in the codec and the realtime port, update after the confirmation turn, server-held instruction tracking, settings path, re-send after a resumed setup, model check, rejection stop, record lines; rows 1–11 | unit, build, D (rows 9–11) |

## 17. Remove the mid-conversation tone update; the tone starts with the next conversation (iOS, APPROVED 2026-11-10)

**Status:** APPROVED (owner 2026-11-10: "just write spec to remove this feature that fix this big"). Withdraws §16.
**Depends on:** §1–§10, F-05 (session setup), F-24 §15 (handle kept after a give-up).

**Why.** §16 (T-034c) was built and recorded PASS without a device run. Device records 2026-11-10 (app 0.1.0(1)):
- 175100: 「说温一点」 → `set_speaking_style gentle`, her confirmation, `style-update sent reason=tool` at 20084 ms,
  then `session closed code=1006` at 24544 ms, a reconnect, `style-update sent reason=resume`, and no further reply.
- 175232: `set_speaking_style sweet`, `style-update sent reason=tool` at 14989 ms; the next utterance (43002 ms, a
  32 s garbled transcript) got no reply and the record ends.
- In both, the update went out only after the confirmation, so the confirmation was spoken under the old instruction,
  and no reply after any update was heard. The owner heard no difference.
- §16 item 7 stops updates only on `MALFORMED`/1007/1008 within 2 s, so neither failure stopped it.

**Sources (community review 2026-11-10).**
- Google's Live capabilities guide documents no client message that replaces the system instruction mid-session; it
  documents `send_client_content` for text turns ([Live API capabilities](https://ai.google.dev/gemini-api/docs/live-guide)).
  `contextUpdate` comes only from the python-genai SDK (§16 sources).
- Google: tone is guided "using system instructions", set at setup
  ([Vertex: configure language and voice](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/live-api/configure-language-voice)).
  Affective dialog is "Removed in Gemini 3.8 Live" (capabilities guide).
- Forum thread 184558 (2026-09 to 2026-11): on `gemini-3.8-live` a voice-style instruction (accent) is often not
  followed once the prompt is production-sized (1 500–13 000 characters, 5–13 tools); a 400-character persona with no
  tools kept it. No Google fix ([thread](https://discuss.ai.google.dev/t/gemini-live-3-8-follows-british-english-accent-instructions-less-consistently-than-3-1-flash-live/184558)).
  Our setup is about 1 740 characters and about 20 tools, so the tone changes her wording at most, not her voice.

**Rule in plain words.** A tone change is saved and starts with the next conversation. Nothing is sent to Gemini
during the conversation. Her confirmation says that, and does not promise a different voice.

1. **No mid-session update.** The app never sends `contextUpdate`. Removed from code: the `contextUpdate` encoder in
   `GeminiCodec`, the instruction-update call of the realtime port and its `GeminiLiveProvider` implementation,
   `StyleUpdates` and `StyleUpdateLine` (NovaAgent/Persona/StyleUpdate.swift), the `styleUpdates` wiring in
   `AgentState`, and `styleUpdatesStopped` / `styleUpdatesRejected` in App/NovaDrive/AgentRuntime.swift. Their tests go
   with them. `SessionConfig.contextUpdateModel` and `supportsContextUpdate` are removed when nothing else uses them.
2. **When the tone applies.** `SpeakingStyle.saved(in:)` is read when a session is set up without a resumption handle,
   as before §16. A reconnect with a handle (in-session, or a F-24 §15 give-up handle) keeps the server's original
   instruction (LiveKit #7944, §16 sources), so the old tone lasts until a session starts without a handle. Nothing is
   done to change that.
3. **The tool result (I-14).** `set_speaking_style` still saves the tone and returns `ok=true` with `style`. Its
   `instruction` and `next` become 「只说这一句：<line>」 with the line built in code:
   - `default`: 「好的，下次对话开始我恢复正常的说法。」
   - `sweet`: 「好呀，下次对话开始我说话甜一点。」
   - `tsundere`: 「哼，下次对话开始就换傲娇的说法。」
   - `gentle`: 「好的，下次对话开始我说话温柔一点。」
   - `lively`: 「好嘞，下次对话开始我说话元气一点！」
   No line says her voice or sound changes. The catalog description stays byte-for-byte (F-09 iOS notes).
4. **设置.** The tone picker stays and only saves. Its note becomes 「下次对话开始生效。」 A pick while a session runs
   sends nothing.
5. **Record and log.** No `style-update` lines. The existing `tool-call` / `tool-result` lines stay.
6. **Nothing else changes.** The style block wording, the 4 000-character cap, the base instruction, the voice name and
   the tool schema stay as they are.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Scripted provider: `set_speaking_style` gentle ok, the reply turn ends; then a tone picked in 设置 | Nothing but the tool response is sent; no `style-update` line | unit |
| 2 | `set_speaking_style` with each of the five styles | Tone saved; `next` is the item 3 line; no line mentions 声音 | unit |
| 3 | Tone gentle saved, a new session set up without a handle | The setup instruction carries the gentle block | unit |
| 4 | Tone changed, then a reconnect with a handle | The setup is sent as today; no extra message after `setupComplete` | unit |
| 5 | Search the sources | No `contextUpdate` encoder or `StyleUpdates` type is left | unit / grep |
| 6 | Device: 「温柔一点」, then 「介绍一下珠海」, then end the session; start again and 「介绍一下珠海」 | She says the item 3 line; the first session keeps going with no 1006 and no lost reply; the second session's record shows `speakingStyle gentle`; the owner judges the wording | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-034d | §17 items 1–6: remove the §16 code and tests, new confirmation lines, 设置 note; rows 1–6 | unit, build, D (row 6) |
