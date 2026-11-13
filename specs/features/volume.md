# F-13a Volume: the music and her voice (音量)

**Status:** APPROVED (owner 2026-11-10, "just write the spec"). iOS only.
**Depends on:** F-13 §16–§18 (media lane, preview node), F-08 §17 (reply dip for barge-in), F-09 (dispatch,
validator), F-09a §3 item 2 (non-comfort tools keep their behaviour), F-07 (her playback), contracts/voice-agent.md

## 1. Why

Owner 2026-11-10: "currently the agent unable to change the sound level", and asked how others handle two sounds at
once, her voice and the music. Today:
- **No tool.** The catalog has no volume tool, so 「音量调大」「你说话小声点」 cannot do anything. She can only say so.
- **No ducking.** `LiveAudio` plays her voice (`reply` node) and the music (`media` node and the preview source node) on
  one mixer, both at volume 1. The only volume change in code is the barge-in dip of her own reply
  (`LiveAudio.setReplyDipped`, F-08 §17 item 11). The music is **not** lowered while she speaks. `music.md` §14 item 4
  ("ducking under her voice … work as for the bundled track") describes something the code does not do;
  `voiceProcessingOtherAudioDuckingConfiguration(.min)` only concerns other apps' audio.

**Sources (community review 2026-11-10).**
- **iOS cannot set the phone's volume.** Apple: there is no programmatic way to control the system volume; use
  `MPVolumeView` for a user control ([AVPlayer.volume](https://developer.apple.com/documentation/avfoundation/avplayer/volume.md));
  `AVAudioSession.outputVolume` is read-only
  ([outputVolume](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume.md)). Setting the
  slider inside `MPVolumeView` from code is reported unreliable
  ([Apple forums 51980](https://developer.apple.com/forums/thread/51980)). Apps set the gain of their own players.
- **Cars keep one volume per sound group.** Android Automotive controls each volume group independently, and media is
  ducked while a voice prompt plays ([AOSP volume management](https://source.android.com/docs/automotive/audio/volume-management)).
  The duck is relative to the media level the driver chose
  ([Sparrowcar](https://sparrowcar.com/blog/what-is-audio-ducking-in-car-navigation/)).
- **A plain 「把音量调大一点」 means the media volume**; the assistant's own volume is changed by naming it
  (「语音音量」) ([智己 L7, 汽车之家](https://club.autohome.com.cn/bbs/thread/e43bc6d81db95b4f/105895302-1.html)).

## 2. Rule in plain words

The app has two volumes of its own: **media** (the song) and **voice** (her voice, plus navigation guidance and the
cue). Each goes from 0 to 10 and is applied as the gain of its lane in `LiveAudio`. The phone's volume buttons set the
ceiling; the app never changes it. The driver changes either one by voice or in 设置. While she speaks, the song is
lowered and comes back after her reply.

## 3. The two levels

1. **Levels.** `media` 0–10 and `voice` 2–10, integers, saved in UserDefaults (`volumeMedia`, `volumeVoice`). The
   default is 10 for both, which is today's sound. The gain of a level `n` is `n / 10` (10 → 1.0).
2. **Voice never goes silent.** `voice` cannot go below 2. She must stay audible for confirmations and safety lines.
   Asking for less returns `limit_reached`.
3. **Where each applies (NovaAudio).**
   - `media`: the bundled loop node and the preview source node (`AVAudioMixing.volume`).
   - `voice`: the reply node, the guidance node and the cue node.
   - The barge-in dip of F-08 §17 item 11 multiplies the voice gain instead of replacing it: dipped =
     `voiceGain × 10^(−dipDb/20)`, restored = `voiceGain`. `flush` restores `voiceGain`, not 1.
4. **The phone's volume is a ceiling.** Level 10 is the loudest the app can be at the current phone volume. The app
   reads `AVAudioSession.outputVolume` only to word the answer (§4 item 5); it never tries to set it.

## 4. The tool `set_volume`

1. **Declaration.** `set_volume{target, action, value?}`:
   - `target`: `media` | `voice`;
   - `action`: `up` | `down` | `set` | `mute` | `max`;
   - `value`: integer 0–10, required only for `set`.
2. **Steps.** `up` / `down` change the level by 2 (1 when it is within 1 of the end). `mute` is 0 for `media`; for
   `voice` it is refused as `limit_reached` at 2 (§3 item 2). `max` is 10.
3. **Which target (the description tells Gemini; the validator checks only the fields).**
   - 「音乐/歌声音大一点」, or a plain 「音量调大」「小声点」「静音」 while the media lane is playing → `media`.
   - 「你说话大声点」「语音音量调小」「你声音太大了」 → `voice`.
   - A plain 「音量调大」 while nothing plays on the media lane → `voice`.
4. **Validation.** Unknown keys, a wrong type, `value` outside 0–10, or `set` without `value` →
   `invalidFields` / `invalidFieldType` / `invalidFieldValue` / `missingValue`, as other tools.
5. **Result (I-1, I-14).** `ok=true` with `target`, `level` (new), `previous`, `limit_reached`, and an `announce`
   line built in code: 「音乐音量调到 6 了」, 「我说话的声音调到 8 了」.
   - Already at the end in that direction: `ok=true`, `limit_reached=true`, level unchanged, announce
     「已经是最大了」 / 「已经是最小了」.
   - `limit_reached` at 10 and `outputVolume` < 0.5: the announce adds 「可以按手机侧面的音量键再调大」.
   - The new gain is applied before the result is sent, so her confirmation is already at the new voice level.
6. **Area.** `set_volume` is not a comfort tool; F-09a §3 item 2 applies (it runs in every area). A tap never calls
   it (§6).
7. **Not repeat-sensitive.** Two 「再大一点」 in a row are two steps.

## 5. Ducking: the song is lowered while she speaks

1. **When.** From the first buffer of her reply on the reply node until that reply's playback finished (or its
   flush), the media gain is `mediaGain × duckFactor`. Guidance playback ducks the same way.
2. **How much.** `duckFactor` = 0.3 (about −10 dB). It is a tuning value, checked on the device (§8 row 9); the owner
   may change it.
3. **Ramp.** Down in 150 ms, back up in 400 ms, in steps of 25 ms on `mediaQueue`. Never from the render thread.
4. **Relative.** The duck multiplies the driver's media level (§1 sources). `media` 0 stays 0.
5. **Barge-in unchanged.** The microphone path, echo cancelling and the F-08 dip are not changed by ducking.

## 6. Settings screen

设置 → 声音 gets two sliders, 音乐音量 and 小诺说话音量 (0–10 and 2–10). A slider change calls the same executor as
the tool (I-6) and applies at once, while a session runs or not.

## 7. Record and log

- `volume set target=<media|voice> from=<n> to=<n> by=tool|settings limit=<bool>`.
- `duck on` / `duck off` with `ms=<n>` time since the reply started. Codes and numbers only; RuntimeLog the same
  (I-8).

## 8. Acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Validator: every bad shape of §4 item 4; every good shape | The error code; accepted | unit |
| 2 | `up` from 10, `down` from 0 (media), `down` from 2 (voice), `mute` on voice | `limit_reached=true`, level unchanged | unit |
| 3 | `up` from 5, `down` from 9, `set 7`, `max`, `mute` on media | 7, 7, 7, 10, 0; `previous` right; announce from code | unit |
| 4 | Level saved, app restarted | Same level applied at start | unit |
| 5 | Voice level 6, barge-in dip, then flush | Reply gain 0.6 × dip, then 0.6 (not 1) | unit |
| 6 | Media playing at level 8; her reply starts, then finishes | Media gain ramps to 0.24, then back to 0.8; `duck on`/`duck off` lines | unit |
| 7 | Media level 0 during a reply | Stays 0 | unit |
| 8 | Slider change in 设置 | Same executor and record line `by=settings` | unit |
| 9 | Device: a preview plays; 「现在几点」 | The song is lower while she answers and comes back; her answer is clear; owner judges `duckFactor` | D |
| 10 | Device: 「音量调小一点」 while a preview plays, twice; then 「你说话大声点」 | The song gets quieter twice; her voice gets louder; three `volume set` lines | D |
| 11 | Device: 「音量调到最大」 at phone volume 30 % | Media 10, `limit_reached`; she mentions the side buttons | D |
| 12 | Device: barge-in during a reply, voice level 6 | Barge-in works as before (F-08 rows) | D |

## 9. Tasks

| Task | Scope | Verify |
|---|---|---|
| T-032g | §3, §4, §6, §7 (volume lines): the two levels, `set_volume` (catalog, validator, executor, announce), lane gains in `LiveAudio`, dip × voice gain, 设置 sliders; rows 1–5, 8, 10–12 | unit, build, D |
| T-032h | §5 and §7 (duck lines): ducking under her voice and guidance; rows 6, 7, 9. Corrects music.md §14 item 4 | unit, build, D |

## 10. Volume on the phone: which build, and making her call the tool (T-032i)

**Status:** APPROVED (owner 2026-11-13, "just write the spec"). iOS only.

**Why.** Owner 2026-11-13: on the installed build she says 「無法調節音樂的音量」. Findings:
- 设置 →「声音」 on that phone has **no volume sliders**, which every build since T-032g (merged 2026-11-10) shows
  unconditionally. So the installed build predates T-032g, and `set_volume` is not declared to Gemini there. Her
  refusal was true.
- Nobody could tell this from the phone: every build reads `0.1.0(1)` (`App/project.yml` `MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`), and the record header line `app 0.1.0(1)` is the same for every build.
- T-032g rows 10–12 were never run on a device. Unit tests fake Gemini's tool call, so they do not show that Gemini
  calls `set_volume`. The base prompt's strict tool list names 音乐 and 静音 but not 音量, and the claim checker's
  request words lack 音量/大声/小声/调大/调小, so a refusal without a tool call gets no correction.
- Google's Live API guidance: be specific in tool definitions and say under what conditions a call should be made
  ([Live API best practices](https://ai.google.dev/gemini-api/docs/live-api/best-practices)). No local command path is
  added: the community intercept pattern (Pipecat processors, LiveKit `llm_node`) needs a text step that a native-audio
  session does not have.

**Items.**
1. **Build stamp.** The Codemagic build writes the short commit (`CM_COMMIT`, first 7 characters; `git rev-parse
   --short HEAD` when unset) into Info.plist key `NovaGitCommit`. 设置 shows 「版本 0.1.0 · <commit>」 as the last row of
   「状态」. The record header line becomes `app 0.1.0(1) <commit>` (`unknown` when the key is missing). `ComfortSummaryStore.build`
   uses the same commit instead of the binary's modification time.
2. **Declared tools in the record.** The record header (once per session; the list does not change on reconnect) writes `tools declared=<n> set_volume=<yes|no>` (names
   and counts only, I-8), so a record shows whether the tool was offered.
3. **Base prompt.** The strict list in the 【车辆与出行（严格）】 sentence gets 「音量」 right after 「音乐」. If the base goes
   over `maxBaseCharacters`, the cap rises by exactly the added characters and the cap test is updated with it.
4. **Tool description.** `set_volume`'s description starts with the trigger, not with what it is not:
   「司机说音量、声音大小、大声、小声、静音、最大声时一定调用。」 followed by the current target and action text, with
   「（0–10，不是手机音量）」 replaced by 「（app 里的 0–10 档）」. Validator, schema and announce are unchanged.
5. **Claim checker.** `ClaimLexicon.request` gains 音量, 大声, 小声, 调大, 调小. A volume request answered with no tool
   call then gets the existing `actionAskedNoToolCall` correction (one per utterance, as today).
6. **Device check closes T-032g.** T-032i's device run is rows 10–11 plus row 17 on a build whose 设置 shows the stamp.

| # | Given / when | Then | Test |
|---|---|---|---|
| 13 | Header with commit `b305c60`; with no `NovaGitCommit` | `app 0.1.0(1) b305c60`; `app 0.1.0(1) unknown` | unit |
| 14 | Setup with the comfort and non-comfort catalogs | `tools declared=<n> set_volume=yes` in both | unit |
| 15 | Base prompt, both comfort modes | Contains 「音乐、音量」; length within `maxBaseCharacters` | unit |
| 16 | 「音量调小一点」「你说话大声点」, reply 「我调不了」, no tool call | One `actionAskedNoToolCall` correction each | unit |
| 17 | Device: 设置 shows 「版本 0.1.0 · <commit>」 matching the installed build; then rows 10–11 | Sliders present; the song and her voice change; `volume set … by=tool` lines; header shows the commit | D |

Task: T-032i | items 1–6; rows 13–17 | unit, build, D.
