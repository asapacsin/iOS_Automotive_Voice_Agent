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
