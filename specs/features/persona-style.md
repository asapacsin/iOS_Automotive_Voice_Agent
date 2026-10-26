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
