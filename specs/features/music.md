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
Bundled track: `AVAudioPlayer` (A/B). Third-party app control: iOS cannot drive other apps' sessions; Apple Music via MusicKit `ApplicationMusicPlayer` plays Apple Music in-app and in background (VERIFIED; needs the user's subscription; OQ-IOS-7). Netease/QQ Music: no iOS API to control them (VERIFIED by absence; OWNER decides whether Apple Music only is acceptable).
