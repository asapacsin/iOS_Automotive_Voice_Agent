# Product specification (platform-independent)

## Purpose

A Mandarin-speaking in-car voice assistant named 小诺 that runs on a phone (Android today) mounted
in the car. The driver talks hands-free; the assistant navigates with Amap, controls (simulated)
cabin comfort, plays music, answers live questions (weather, traffic, places), describes the camera
view, places phone calls after confirmation, and handles vague or ambiguous requests by using
context or asking one short question. Navigation is the persistent context; the screen is a full map
with a small assistant overlay.

## Users and setting

- One driver, eyes on the road. Spoken output is short; the screen is secondary.
- Language: Mandarin (zh-CN). Cantonese is partially handled (ADR-002 addendum, YUE-RATE-001 low
  success) and is **not** a port requirement (owner decision "Mandarin-only", 2026-10-20).
- Network: mobile data in mainland China and abroad; Gemini may be unreachable from mainland networks
  (consent notice `GeminiAppSettings.CONSENT_NOTICE`).

## Core user journeys (each has a feature file)

| # | Journey | Feature file |
|---|---|---|
| J1 | Say the wake phrase, talk, assistant answers; stays listening, then sleeps | wake-word, listening-lifecycle |
| J2 | "导航去珠海站" → pick a place → pick a route → guidance runs | navigation-flow, destination-search |
| J3 | While navigating, ask "还要多久", "附近有加油站吗" without losing the route | live-info, navigation-guards |
| J4 | "有点热" → cooler; "再凉一点" → cooler again; "再低一点" after seat and temperature both changed → one question | vehicle-controls, ambiguity-context |
| J5 | "有蚊子" → windows half open; "蚊子出去了" → closed | comfort-scenarios |
| J6 | Interrupt her while she speaks; she stops at once | barge-in-arbitration |
| J7 | Guidance prompt and assistant reply never talk over each other | guidance-voice, barge-in-arbitration |
| J8 | "放首歌" / "放周杰伦的歌" → music plays, and she only says so if it really plays | music |
| J9 | "打电话给妈妈" → confirm → call | phone-call |
| J10 | "前面那是什么车" → camera look → answer | vision |
| J11 | "说话嗲一点" → speaking style changes, actions still done | persona-style |
| J12 | Configure keys and consent in developer settings | settings-credentials |

## Non-negotiable product rules (from `docs/INVARIANTS.md`)

| ID | Rule |
|---|---|
| I-1 | Only an `ok=true` tool result proves an action happened; claim audio and subtitle wait for it. |
| I-2 | An unsupported capability fails deterministically with one honest sentence. |
| I-3 | No source for weather/traffic/news → refuse, never invent. |
| I-4 | Noise may reach the model but never an executor. |
| I-5 | A false reply is held before it is heard; audio and subtitle are held together. |
| I-6 | UI never executes actions directly; buttons and voice share one executor path. |
| I-7 / I-8 | No secrets in source or logs; no coordinates, addresses or transcripts in logs. |
| I-11 | A prompt rule is never the enforcement mechanism; code enforces. |
| I-12 | Audio, map and lifecycle claims need device evidence. |
| I-13 | App logic depends on the provider-neutral realtime contract, not a vendor protocol. |
| I-14 | Every executed action is announced from its read-back result. |

## Out of scope for the port (today)

- Real vehicle control (Android has none either).
- Baidu and Qwen providers (dormant/frozen) — keep the seam only.
- Cantonese, OpenAI/GPT-Live (no runnable path on Android).
- The CI/emulator test rig and debug broadcast receiver (replace with iOS test hooks, see migration-plan).
