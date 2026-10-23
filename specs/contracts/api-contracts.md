# Contract: external APIs (v1, 2026-10-22)

Only the fields the app actually uses, read from Android code. The Gemini Live part was checked against
Google's docs on 2026-10-23 and is current (OQ-IOS-5); production should use ephemeral tokens.

## Gemini Live (ACTIVE) — `A/voice/GeminiLiveProtocol.kt`, `GeminiLiveClient.kt`

- Transport: WebSocket `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`
  (`GeminiAppSettings.DEFAULT_ENDPOINT`), header `x-goog-api-key`. Connect timeout 10 s, ping 20 s,
  `setupComplete` within 10 s.
- Setup: `responseModalities=[AUDIO]`, speech `languageCode=zh-CN`, prebuilt voice (default "Leda"),
  optional `thinkingLevel` (LOW default; MINIMAL rejected), `systemInstruction` (persona + call-first
  hint), `tools.functionDeclarations` with `parametersJsonSchema`, `realtimeInputConfig.
  automaticActivityDetection` (start sensitivity LOW, end HIGH, optional `silenceDurationMs` 100–3000),
  input and output transcription on, `contextWindowCompression.slidingWindow`, `sessionResumption{handle}`.
- Models: default `gemini-3.8-live`; alternatives `gemini-3.8-live-extended-thinking`,
  `gemini-3.1-flash-live-preview` (`I/VoiceCatalog.kt:127-141`).
- Client → server: `realtimeInput.audio` (16 kHz PCM base64), `realtimeInput.audioStreamEnd`,
  `clientContent{turns, turnComplete}`, `toolResponse.functionResponses`.
- Server → client: `setupComplete`, `goAway`, `sessionResumptionUpdate`, `serverContent{
  inputTranscription, outputTranscription, modelTurn audio, interrupted, generationComplete,
  turnComplete}`, `toolCall.functionCalls`, `toolCallCancellation.ids`.
- Close codes: 1007 on a resumed setup → clear handle, `RESUME_UNAVAILABLE` (retryable); 1008 not about
  auth/quota → `CONNECTION_CLOSED` (retryable).

## Azure Speech TTS (ACTIVE when configured) — `A/voice/AzureSpeechVoice.kt`

REST SSML, output `raw-24khz-16bit-mono-pcm`; connect timeout 5 s; clause deadline 4 000 + 400 ms ×
chars; warm-up request ("嗯") every 15 s; at most 2 clause requests in flight, played in order.

## Amap

- **Navi SDK** (Android `com.amap.api:navi-3dmap-location-search:11.2.100…`): drive route calculation
  with multiple routes, route selection, GPS or emulator navigation, guidance text and speaking
  callbacks, camera/limit info. Key `AMAP_API_KEY` in app metadata.
- **Web REST** (`restapi.amap.com`, key `AMAP_WEB_KEY` entered in settings):
  `/v3/place/text`, `/v3/place/around` (radius 50 000 m, ≤5 results, sort `distance` for nearby else
  `weight`), `/v3/place/polygon` (along-route corridor: half width 500 m, simplify 50 m, ≤64 vertices,
  offset 25), `/v3/weather/weatherInfo`, `/v3/geocode/regeo`, place detail, `/v3/staticmap`.
  Live info timeout 4 000 ms; weather TTL 10 min; adcode TTL 30 min. Coordinates are GCJ-02.

## Qianfan vision (IMPLEMENTED) — `A/vision/QianfanVisionClient.kt`

POST `https://qianfan.baidubce.com/v2/chat/completions`, bearer token, image as JPEG. Results: Answer,
NotConfigured, AuthFailed, Failed.

## iFlytek MSC wake word (IMPLEMENTED, Android SDK) — `A/wake/IflytekWakeWordDetector.kt`

Offline model `ivw/wakeword.jet`, threshold `0:1450`, app-fed audio. App id stored as a secret. iOS SDK
exists (`iflyMSC.framework`), app-id bound, in-app wake only (OQ-IOS-1, VERIFIED 2026-10-23).

## Dormant providers (do not port now)

Qwen-Omni Realtime (DashScope, frozen 2026-10-22), Baidu Realtime Flex / Lite (dormant), OpenAI-style
`GPT_LIVE` (catalog id only, no factory branch — not runnable).
