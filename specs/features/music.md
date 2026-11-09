# F-13 Music

**Android status:** IMPLEMENTED: bundled track play/stop; media-session search + read-back (SPEC-017, play_music path not exercised in demo run 315).
**Depends on:** F-09

## 1. Purpose
Play or stop music by voice, and only claim it plays when it really does.

## 2. User-facing behaviour
放首歌 → bundled track; 放周杰伦的歌 → handed to the active music app, confirmed by now-playing.

## 3. Preconditions
For play_music: notification-listener access to other apps' sessions.

## 4. Inputs and outputs
`control_music{play, stop}`; `play_music{free-text fields}` → playFromSearch → poll now-playing every 250 ms up to 6 s.

## 5. State transitions
Sent / NoApp / Rejected; then Playing(matches) / NotPlaying / Unverified.

## 6. Events and triggers
Tool call.

## 7. Dependencies and external services
Other apps' media sessions (Android-only mechanism).

## 8. Error handling and recovery
`MUSIC_NOT_CONFIRMED` correction when unverified.

## 9. Concurrency, cancellation, timeouts
Poll 250 ms, timeout 6 s.

## 10. Acceptance criteria (iOS)
- Bundled play/stop works offline.
- No success claim without verified now-playing.

## 11. Existing Android tests
`T/media/*Test`, `MediaServerPlayMusicTest`, `tools/MediaDomainPlayMusicTest`, `voice/DriverTurnMusicTest`.

## 12. Source references (Android)
`A/BundledMusicPlayer.kt:37,74,78,86`; `A/media/AndroidMediaHandoff.kt:20`; `A/media/NowPlayingVerifier.kt:15`; `A/tools/MediaServer.kt:22`.

## 13. Implementation constraints
Controlling other apps' playback is class C.

## iOS notes (PROPOSED unless labelled)
Bundled track: `AVAudioPlayer` (A/B). Third-party app control: iOS cannot drive other apps' sessions; Netease/QQ Music: no iOS API to control them (VERIFIED by absence). Named music: none (owner 2026-10-27, OQ-IOS-7); `play_music` answers MUSIC_HANDOFF_UNAVAILABLE.

## Contract for the truthfulness gate (2026-10-23, T-019 review 7)
The media lane reports now-playing to `DriverTurnPipeline` as `musicPlaying(Bool)` transitions: `false`
when a new play request starts, then `true` only once that request is verified playing. A repeated
`true` for the track that was already playing is not evidence for a new 「正在播放」 claim.

## 14. Named music as 30-second iTunes previews, inside the app (iOS, APPROVED 2026-11-09)

**Why.** Owner 2026-11-09: 「我想听梶浦那首空之境界的歌」 should play smoothly, without another app opening in front. OQ-IOS-7 (2026-10-27, no named music) is reopened for this. `play_music` already takes the description, and Gemini works out the song (`title`/`artist`/`album_or_work`, `exclude_title` for 「不是这首」), but no `NamedMusicPort` is wired, so it answers `MUSIC_HANDOFF_UNAVAILABLE`. iOS gives no API to QQ音乐/网易云 playback. Apple Music in the app (MusicKit, `MusicKitPlayer`) needs a subscription and the paid developer account. The free choice that plays in the app is Apple's iTunes Search API, which returns a 30-second `previewUrl` per song with no key.

**Copied practice.** Apple iTunes Search API (performance-partners.apple.com/search-api): `GET https://itunes.apple.com/search?term=<words>&country=<ISO 2>&media=music&entity=song&limit=<1–200>`; no authentication; song results carry `trackName`, `artistName`, `collectionName`, `previewUrl`, `trackViewUrl`, `artworkUrl100`, `trackTimeMillis`; "approximately 20 calls per minute". Its legal terms for song previews: streamed only, never saved or cached; shown with the attribution "provided courtesy of iTunes" near a link to the store; used to promote the content, "not for entertainment purposes". **Owner risk, recorded:** listening to previews in the car is personal testing use; this build is not distributed. Full songs stay MusicKit (T-072) if the owner later gets Apple Music and the paid account.

1. **Port.** A new `ITunesPreviewMusic` (search in `NovaServices`, playback in `NovaAudio`; vendor imports only there) implements `NamedMusicPort`, and `AgentRuntime` passes it to `MusicToolHandler(named:)`. `MusicKitPlayer` stays unwired.
2. **Search.** One request per `play_music` call. `term` is the call's `title` and `artist` joined by a space; without `title`, the present ones of `album_or_work`, `artist`, `query`, `mood`, in that order. `country` from 设置 → 音乐 → 「曲库地区」: 中国大陆 CN (default), 日本 JP, 香港 HK, 台湾 TW, 美国 US. `limit=10`, 5 s timeout, no HTTP cache (`reloadIgnoringLocalCacheData`, no `URLCache`).
3. **Pick.** Only results with a `previewUrl` and whose `trackName` is not `exclude_title`. First the first result whose `trackName` contains `title` and whose `artistName` contains `artist` (compared after lower-casing and full-width to half-width; a missing field matches anything); otherwise the first remaining result. None left: `MUSIC_NOT_FOUND`.
4. **Play.** The preview is streamed with `AVPlayer` from `previewUrl` (an `http://` URL is requested as `https://`), on the media lane, so `control_music stop`, barge-in, ducking under her voice and the self-echo rules work as for the bundled track. Starting a preview stops the bundled track and any earlier preview. Nothing is written to disk.
5. **Proof.** `nowPlaying()` returns the picked `trackName`/`artistName` only while `AVPlayer.timeControlStatus == .playing` for that item; the handler's existing 250 ms / 6 s poll is the proof (I-1, the music contract above). The success result also carries `album`, `preview_seconds: 30` and `source: itunes_preview`.
6. **End.** When the preview ends, playback stops, the lane reports not playing, and nothing plays next. 「再放一遍」 is a new `play_music` call.
7. **Screen.** While a preview plays, the overlay shows a card: artwork, title, artist, 「30 秒试听 · provided courtesy of iTunes」, and a 「在 Apple Music 中打开」 button that opens `trackViewUrl`. The card goes when playback stops.
8. **Failures.** No network, HTTP error, timeout or bad JSON: `MUSIC_SEARCH_FAILED`. Empty pick: `MUSIC_NOT_FOUND`. Not playing within 6 s: the existing `notPlaying` path. Each has failure-catalog advice to say plainly it did not play, with no claim that it plays. This port never returns `requested_unverified`.
9. **Tool text.** In the `play_music` description 「（用手机音乐 app）」 becomes 「（播放 iTunes 30 秒试听）」 and the `requested_unverified` sentence is removed; the rest stays. The success `next` becomes 「只按 now_playing 说正在放哪首，并说是 30 秒试听。」
10. **Log.** `music search ms=<n> results=<n> picked=<index|none> country=<CC>`; `music preview playing ms=<call to playing>`; `music preview ended`. Song names go in the record, not in `RuntimeLog`.
11. **Not changed:** `control_music` and the bundled track; the claim gate; MusicKit (T-072) stays unwired; CarPlay (OQ-IOS-8).

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `play_music{title:"oblivious", artist:"Kalafina"}`, country CN | Request `term=oblivious Kalafina`, `country=CN`, `media=music`, `entity=song`, `limit=10`, no cache | unit |
| 2 | Fixture: first result without `previewUrl`; second 「oblivious (TV size)」 by another artist; third 「oblivious」 by Kalafina | Third picked; with `exclude_title:"oblivious"` the second is picked | unit |
| 3 | Only `album_or_work:"空の境界"` and `artist:"梶浦由記"`; only `query`; title 「ｏｂｌｉｖｉｏｕｓ」 | Terms as item 2; the full-width title matches | unit |
| 4 | Fake player reports playing after 400 ms | ok, `now_playing` title and artist, `preview_seconds` 30, `source` itunes_preview; bundled track stopped | unit |
| 5 | HTTP 500; timeout; empty results; player never plays | `MUSIC_SEARCH_FAILED`; `MUSIC_SEARCH_FAILED`; `MUSIC_NOT_FOUND`; `notPlaying`; no claim | unit |
| 6 | Preview playing, then `control_music stop`; separately, the preview ends by itself | Stopped and read back; lane not playing, card gone, nothing next | unit |
| 7 | `http://` preview URL | Played from `https://` | unit |
| 8 | Device, network on: 「我想听梶浦那首空之境界的歌」 | She names the song (for example Kalafina 「oblivious」); 30 s plays inside the app; no other app opens; the card shows the iTunes line and button; she says it is a 30-second preview | D |
| 9 | Device: 「不是这首」 | Another 空之境界 song plays | D |
| 10 | Device: while it plays 「你好小诺，别放了」; then 「放周杰伦的晴天」; then a made-up song name | Stops at once; 晴天 plays; for the made-up one she says nothing was found and nothing plays | D |
| 11 | Device: tap 「在 Apple Music 中打开」 | Apple Music or the store opens on that song | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-032b | Items 1–11; rows 1–11 | unit, build, D |

## 15. Named music finds the song: Hong Kong catalogue, a real title, one retry (iOS, APPROVED 2026-11-09)

**Why.** Device 2026-11-09, 2a35f02, record 20261109-145607: 「帮我播那个…空之境界的那个什么歌」 gave `play_music{"album_or_work":"空之境界","artist":"梶浦由记","query":"帮我播那个…什么歌"}` → `MUSIC_NOT_FOUND`, twice. Two causes, both checked against the live API on 2026-11-09:
- **Catalogue.** `country=CN` returns 0 results for every term tried (「oblivious Kalafina」, 「Kalafina」, 「晴天 周杰伦」, 「空之境界 梶浦由记」). With `country=HK` the same terms find the songs: oblivious and sprinter by Kalafina, 晴天 by 周杰倫, 十年 by 陳奕迅, Lemon by 米津玄師, with a `previewUrl`, including simplified-character terms (「晴天 周杰伦」, 「十年 陈奕迅」). TW and JP also find them.
- **Term.** No `title` was given, so the term was the work, the composer and the driver's whole sentence. In HK, 「空之境界 梶浦由记」 returns soundtrack pieces (「Ⅱ quiet romance」), not a song; 「oblivious」 alone returns Kalafina's oblivious first.

1. **Catalogue.** 「曲库地区」 options become 香港 HK (default), 台湾 TW, 日本 JP, 美国 US. 中国大陆 is removed. A saved CN becomes HK on first launch of this build.
2. **Tool text.** In the `play_music` description, 「确定不了只填 query 和 mood」 becomes: 「先用你的知识确定一首具体的歌：title 填发行时的歌名原文（如 oblivious），artist 填演唱者（如 Kalafina）；不要把用户的原话填进 query。实在确定不了才只填 query 或 mood。」. The rest of the description stays.
3. **Retry in the app.** When a search with both `title` and `artist` has no usable result, one more request is made with `title` alone, then the item 3 pick rule of §14 applies. At most two requests per call.
4. **Retry by Gemini.** `MUSIC_NOT_FOUND` advice becomes: 「曲库里没找到。如果还没填 title，请先确定一首具体的歌，用歌名原文和演唱者再调用一次 play_music；已经填了 title 还是没有，就如实说没找到，不要说在放。」.
5. **Log.** `music search` gets `try=<1|2>` and the term kind `term=<title+artist|title|other>`.
6. **Not changed:** the rest of §14 (preview playback, proof, card, failures).

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | No saved region; saved CN; saved JP | HK; HK; JP. Requests use that `country` | unit |
| 2 | `title:"oblivious", artist:"梶浦由记"`, fixture: first request empty, second (`term=oblivious`) has Kalafina's oblivious | Two requests, second term `oblivious`; Kalafina's oblivious picked and played | unit |
| 3 | Only `album_or_work` and `query`; first request empty | One request only; `MUSIC_NOT_FOUND` with the item 4 advice | unit |
| 4 | Catalog `play_music` description; `MUSIC_NOT_FOUND` advice | Texts exactly as items 2 and 4 | unit |
| 5 | Device: 「我想听梶浦那首空之境界的歌」 (said loosely, as on 2026-11-09) | `play_music` has a `title` (for example oblivious) and `artist`; a 空之境界 song by Kalafina plays inside the app | D |
| 6 | Device: 「放周杰伦的晴天」; 「放陈奕迅的十年」 | Each plays | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-032c | Items 1–6; rows 1–6 | unit, build, D |

## 16. The preview plays through the app's audio engine (iOS, APPROVED 2026-11-09, owner)

**Why.** T-032b (2a35f02) streamed the preview with `AVPlayer`, outside `LiveAudio`'s voice-processing engine. Apple voice processing cancels only what its own engine plays, so the song was not in the echo reference: lyrics could reach the microphone (heard as the driver, a false barge-in, transcript words), the song was not handled like the bundled track under her voice, and a stop of the media lane did not stop it. §14 item 4 was therefore not met.

**Copied practice.** Developers of iOS voice apps route every playback through the same engine as the voice-processed microphone, because "voice processing only works correctly when input and output are being routed via the same engine" (Apple Developer Forums thread 97679; field report barock.dev 2026-04-22 "Why your iOS voice agent still hears itself"). Streaming players built on `AVAudioEngine` (AudioStreaming, audiostreamer) download the bytes, decode them to PCM in memory and schedule them on an `AVAudioPlayerNode`.

1. **Path.** The preview is played by `EnginePreviewPlayer` (NovaAudio) on a preview node (44.1 kHz stereo) of `LiveAudio`'s engine, connected to the same mixer as her voice, guidance, the bundled track and the cue. It is the media lane: `mediaPlaying` events, `stopMedia()`, session end and the engine-restart replay treat it like the bundled track. `AVPlayer` is no longer used; `AVFoundation` is not imported by NovaAudio (`AudioToolbox` is, for decoding).
2. **Download.** The whole preview file is fetched into memory (no `URLCache`, `reloadIgnoringLocalCacheData`, 5 s timeout, at most 8 MB, status 200), then played. Nothing is written to disk. Holding the decoded preview in memory while it plays is treated as streaming (owner risk, as in §14).
3. **Decode.** `AudioFileOpenWithCallbacks` over the bytes plus `ExtAudioFile` decode the `.m4a` (AAC) to the node's PCM format in memory, whatever the file layout.
4. **Timing.** `play` returns at once; download and decode run in the background, and §14's 6 s now-playing poll covers them. A failed or slow download is `NOT_PLAYING` (the preview is stopped first, §14 item 8).
5. **One at a time.** A new preview, the bundled track, `control_music stop` and session end each stop the one on the lane; a stale download or a stopped preview's completion never starts or ends the next one. The end of the preview (played to the end) is §14 item 6.
6. **Not changed:** search, pick, proof, card, failures, logs (§14, §15).

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Source tree | No `AVPlayer` in NovaAudio; `AudioToolbox` only in NovaAudio; gates green | unit (gate) |
| 2 | App build | Builds with the preview node attached before voice processing is enabled | build |
| 3 | Device: a preview plays at normal volume; the driver says nothing for 30 s | No barge-in, no `heard-gemini` lyrics, no wake | D |
| 4 | Device: while a preview plays, ask 「现在几点」 | She answers; her voice is clear over the song; the answer is not about the lyrics | D |
| 5 | Device: while a preview plays, 「你好小诺，别放了」; then end the session during another preview | Stops at once each time; card gone | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-032d | Items 1–6; rows 1–5 (completes T-032b item 4) | unit, build, D |
