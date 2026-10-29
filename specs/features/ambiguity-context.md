# F-10 Driver context and ambiguity resolution

**Android status:** IMPLEMENTED (JVM); FZ-14 clarification not yet proven in a recording (runs 298, 317, 319).
**Depends on:** F-09, F-11

## 1. Purpose
Resolve vague follow-ups (再凉一点, 再低一点) from what was really adjusted, or ask one short question.

## 2. User-facing behaviour
After 有点热 (temperature) and 座位有点高 (seat), 「再低一点」 → 「是座椅还是温度？」; answer 座椅 → seat lowers.

## 3. Preconditions
Referents exist from ok=true tool results within 180 s.

## 4. Inputs and outputs
In: transcript, tool call args, referents. Out: Adjust(dimension, delta) or Clarify(options).

## 5. State transitions
Pending clarification recorded per epoch; next one-word answer resolves it.

## 6. Events and triggers
A relative tool call (adjust_temperature/fan, seat adjust_height, window adjust).

## 7. Dependencies and external services
None.

## 8. Error handling and recovery
Clarify reasons: no_referent, ambiguous, nothing_to_reverse. A line with no direction word uses the tool call's direction only when referents exist (fix 2026-10-22, commit 488d7ab).

## 9. Concurrency, cancellation, timeouts
Stale-words rule: a call judged against the previous turn's transcript is not held.

## 10. Acceptance criteria (iOS)
- Given seat and temperature both changed, when 「再低一点」 (or the misheard 「第一点」) with seat adjust −1, then `AMBIGUOUS_REFERENT` and options 座椅/温度.
- Given only seat changed, then seat lowers again (FZ-05).
- Given nothing changed and 「再量一点」, then no question is asked.

## 11. Existing Android tests
`T/voice/ContextResolverTest`, `BodyContextResolverTest`, `T/ToolCallGuardBodyReferentTest`, `VoiceContextHintsTest`.

## 12. Source references (Android)
`A/voice/DriverContext.kt:26,281`; `A/voice/ContextResolver.kt:85-160`; `A/ToolCallGuards.kt` (`ambiguousReferent`); `SPECS/SPEC-015-fuzzy-driving-requests.md` FZ table.

## 13. Implementation constraints
ASR mishearing is common (再低一点→第一点); guard must not depend on exact words alone.

## iOS notes (PROPOSED unless labelled)
Portable (A).

## Navigation ambiguity (iOS, PROPOSED 2026-10-26)
F-10 above covers vehicle referents. Ambiguous **destinations and picks** follow contracts/navigation.md
(F-15/F-16); they are listed here so both kinds of clarification behave the same way: one short question,
never a guess, never a tool call until the driver answers.

| Situation | Result | What she says |
|---|---|---|
| `navigate_to` finds more than 1 place (e.g. 珠海站 → railway station, bus station, ...) | candidate list, AWAITING_DESTINATION_SELECTION | 「找到N个地点，请说第几个」 |
| A pick by name matches 2+ candidates (「珠海站那个」 with two 珠海站…) | `AMBIGUOUS` (`NavigationController.swift:344`) | asks which number; does not pick |
| A pick by name matches none | `NO_MATCH` | says the name is not in the list, asks for the number |
| Ordinal out of range (「第七个」 of 5) | `OUT_OF_RANGE` | says there are only N |
| 「就那个」/「第一个」 with no list on screen, or a list older than 120 s | `NO_OPTIONS_ON_SCREEN` / `OPTIONS_STALE` | says there is no list, asks where to go |
| 「去那里」/「刚才那个地方」 with no earlier place in this session | no `navigate_to` | asks where |
| Vague exit while navigating (「好了」「不用了」) | `VAGUE_EXIT_WHILE_NAVIGATING` | asks whether to end navigation |
| Nearby *question* while navigating (「附近有加油站吗」) | `NEARBY_QUESTION_WHILE_NAVIGATING`, route kept | answers or offers a list; route unchanged |

**Acceptance (iOS, added):**
- Two candidates both containing the spoken name → `AMBIGUOUS`, phase unchanged, no route calculated (unit).
- ASR variants of ordinals (第一个/第1个/一号) resolve the same index (unit, table-driven).
- 「去那里」 with no earlier place → no `navigate_to` call, one question (unit).
