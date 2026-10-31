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
