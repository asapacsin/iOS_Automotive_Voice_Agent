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
