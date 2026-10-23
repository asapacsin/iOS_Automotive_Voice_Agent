# iOS port specification (Nova Drive → iOS)

Evidence-based specification for a separate AI agent to build a native iOS version of the Android
automotive voice agent ("小诺"). **Specification only; no iOS code.** Written 2026-10-22 from
branch `claude/10-22` (commit after `bf81876`).

## How to use this folder

| Need | Read |
|---|---|
| What the product does, in one page | [product-spec.md](product-spec.md) |
| Components, data flow, state machines | [architecture.md](architecture.md) |
| Every feature and its status | [feature-inventory.md](feature-inventory.md) |
| What iOS can and cannot do | [ios-feasibility.md](ios-feasibility.md) |
| Feature-by-feature parity, tests, priority | [parity-matrix.md](parity-matrix.md) |
| Order of work, first vertical slice | [migration-plan.md](migration-plan.md) |
| Executor / verifier / reviewer process | [ai-agent-workflow.md](ai-agent-workflow.md) |
| Unresolved questions | [open-questions.md](open-questions.md) |
| Cross-feature contracts | [contracts/](contracts/) |
| One feature at a time | [features/](features/) |

An implementing agent should load **one feature file plus the contracts it lists under
"Depends on"**, never this whole folder and never the Android repository by default.

## Evidence conventions

- `A/` = `app/src/main/kotlin/com/novadrive/app/`; `I/` = `ingress/src/main/kotlin/com/novadrive/ingress/realtime/`;
  `T/` = `app/src/test/kotlin/com/novadrive/app/`. Line numbers are as of this commit and drift; the
  symbol name is authoritative.
- Status words: **IMPLEMENTED** (in code and wired), **ACTIVE** (implemented and selected at runtime
  today), **DORMANT** (implemented, not selected), **EXPERIMENTAL**, **DEPRECATED**, **DEAD** (no
  callers), **UNVERIFIED** (could not be confirmed in code).
- Proof levels for Android behaviour: **JVM** (unit test), **EMU** (GitHub emulator, software
  rendering, Gemini free tier), **DEVICE** (Xiaomi phone, no SIM), **LIVE** (real cloud API),
  **HUMAN** (owner by ear/eye). Most voice and navigation behaviour is JVM + EMU only.
- iOS claims are labelled **VERIFIED** (confirmed in vendor documentation read on 2026-10-23, source
  cited in open-questions.md), **PROPOSED** (design judgement), **DEVICE_SPIKE** (only an iPhone run
  can answer) or **OWNER** (a product or account decision). No iOS SDK, device or simulator has been
  run yet, so VERIFIED never means "ran on an iPhone". `python3 scripts/ios_spec_check.py` checks
  that no question is left OPEN and every VERIFIED claim has a source.

## Important facts an iOS agent must not miss

1. **The active voice provider is Gemini Live** (`VoiceProviderChoice.QWEN_FROZEN = true`,
   `A/GeminiSettings.kt`). Qwen-Omni is frozen by the owner (2026-10-22) and Baidu is dormant. Build
   iOS for Gemini Live first; keep the provider seam so others can return.
2. **Vehicle controls are simulated.** No real car API is used on Android (`SimulatedVehicleControl`).
   The iOS port must also simulate them; CarPlay does not give access to climate, seats or windows.
3. **Replies are spoken by Azure TTS, not by Gemini's own audio**, when an assistant voice is
   configured (ADR-016, `AssistantVoiceRevoicer`). Gemini audio is dropped in that mode.
4. **Truthfulness invariants (I-1, I-5, I-14)**: the assistant may only claim an action after an
   `ok=true` tool result; false claims are held before they are heard. These are product behaviour,
   not Android detail, and must be ported.
5. **Navigation uses the embedded Amap Navi SDK plus the Amap Web REST API** (two keys).
