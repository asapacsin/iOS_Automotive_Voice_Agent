# F-04b Speaker Lock: only the enrolled voice can use her (声纹锁定)

**Status:** APPROVED (owner request 2026-11-05). iOS only. Default OFF.
**Depends on:** F-03 (capture), F-04 and F-04a (uplink gate, speech confirmation), F-01 §14 (wake word, T-060a), F-08 (stop phrases, interruption), F-22 (settings), contracts/audio.md, contracts/voice-agent.md

## 1. Purpose

With the lock on, only the enrolled speaker's voice reaches Gemini, wakes her or interrupts her. With the lock off, anyone can use her, as today.

**Limit, stated in the app and docs.** This is basic speaker verification. It does not separate overlapping voices and it can be wrong in both directions. It is a convenience, not a security feature, and a recording of the driver's voice can pass it.

## 2. Sources and model choice (2026-11-05)

- The bundled sherpa-onnx library already has `SherpaOnnxCreateSpeakerEmbeddingExtractor` in its C API at the pinned release, so no new library is needed.
- **Model: `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced`** (CAM++, zh and en, about 28 MB, from the [sherpa-onnx speaker models](https://huggingface.co/csukuangfj/speaker-embedding-models/tree/main)). The Apache-2.0 licence comes from a [secondary source](https://huggingface.co/openEuler/campplus-speaker). T-013e checks the primary 3D-Speaker model card before pinning; if the licence does not allow this use, stop and report it. **Checked 2026-11-05 (T-013e):** the primary ModelScope card `iic/speech_campplus_sv_zh_en_16k-common_advanced` (3D-Speaker team) states `license: Apache License 2.0`; pinned at `csukuangfj/speaker-embedding-models` revision `0743f301`, sha256 `aa3cfc16…ceba2`.
- Rejected: [Picovoice Eagle](https://picovoice.ai/docs/api/eagle-nodejs/) (needs a vendor key and account); WeSpeaker VoxCeleb models (listed as cc-by-4.0 by a third party, and English-trained).
- Pattern: [Picovoice's secure wake word recipe](https://picovoice.ai/cookbook/personalized-wake-word/) checks the voice on the audio around the wake word, and triggers only on a match. Enrollment [works best](https://picovoice.ai/docs/api/eagle-nodejs/) with one speaker in a normal voice, with no background sound.
- No source gives a threshold or short-utterance accuracy for this model in a car, or iPhone latency. These are measured here (§8).

## 3. Settings (`Section("声音")`)

1. **声纹锁定** switch, default off, read without restarting. Text: 「开：只有录入的声音能唤醒和使用小诺。说话重叠时可能听不准。」
2. Status 「未录入」, 「已录入，未校准」 or 「已录入」.
3. Buttons: **录入声纹** (not enrolled), **重新录入** and **校准** (enrolled), **删除声纹** with a confirmation.
4. **The lock cannot be on when it would not work.** Turning it on with no calibrated profile opens the next step (录入 or 校准) and the switch stays off until that succeeds. If the model cannot load, the switch stays off and shows 「声纹模型不可用」.
5. 危险操作's wipe-all also deletes the profile.

## 4. Enrollment

1. **Guided:** the driver reads 3 short Chinese sentences on screen, in a quiet parked car, for about 15 s in total. It runs only with no session running, and the wake listener lets go of the microphone (one capture only, ADR-006).
2. **Same audio path:** it uses the same voice-processing capture as a live session, so enrollment audio matches live audio.
3. **Checks before saving:** at least 8 s of confirmed speech (F-04a), no clipping, and a noise level below a constant. The embeddings of the 3 sentences must agree with each other, which catches a second voice or a bad take. A failed check names the problem and asks for a retry. Nothing is saved.
4. **Stored:** the averaged embedding, model name, dimension, threshold and date, in one file under Application Support, with `completeUntilFirstUserAuthentication` protection, excluded from backup. Raw audio stays in memory only and is dropped when enrollment ends.
5. **Replace and delete:** re-enrolling replaces the file only after the new one passes. Deleting removes the file and turns the lock off.
6. **Model change:** a profile whose model name or dimension differs is invalid; the lock turns off and the status says to re-enroll.
7. **Nothing leaves the phone.** No embedding, score or audio goes to any cloud service for this feature.

## 5. Threshold: calibrated, never assumed

1. There is no built-in threshold. It is `nil` until 校准 sets it, and the lock cannot turn on while it is `nil`.
2. **校准** asks for 20 short everyday lines from the enrolled driver and 20 from another person, with the option of more people. Those lines are not the enrollment sentences. Scores are kept, audio is not. Progress is saved after every line (§13).
3. It shows the false reject and false accept counts at each candidate threshold, and suggests the lowest threshold with no false accepts. The owner confirms it, and it is saved in the profile. It also says plainly that 0 of 20 false accepts is weak evidence: the true rate could still be about 14%.
4. Scores go to a local file in the Documents folder and can be pulled over USB, so the result can be checked.
5. `scripts/speaker_eval.py` computes false accept and false reject rates and score spread on a folder of labelled clips, using the same model through the sherpa-onnx Python package, so it runs on a PC or in the cloud. It does not need the phone, and no audio is added to the repo unless its licence allows it.

## 6. Live pipeline

Microphone → voice processing → speech confirmation → `SpeechUplinkGate` → local words → **`SpeakerHold`** → `PostStopHold` → Gemini.

1. **Ports.** `SpeakerVerifier` port in `NovaPorts`: frames in, embedding score out. The adapter is in `NovaAsrSherpa`, and no Gemini code knows about it. Inserting a target-speaker extractor later means adding a stage before this port; no extractor is built now.
2. **Pure `SpeakerHold` in `NovaVoice`.** With the lock on, it takes `speechStarted`, its pre-roll, the audio and the end marks, and holds them in order. Nothing goes to Gemini until the utterance is accepted.
3. **Off the audio thread.** Scoring runs on one background serial queue. The capture callback only copies frames. It runs once when the utterance reaches `minVerifySpeech`, or at its end if sooner; it does not rescore continuously. `minVerifySpeech` starts at 1.0 s and changes only from the measurements.
4. **Results.**
   - **Accepted:** all held output is released in original order, with the pre-roll, so no first word is lost; the rest of the utterance passes straight through.
   - **Rejected:** everything for that utterance is dropped. It counts as not sent: no activity marks, no driver turn, no tool call, no reply clock, and no driver line on screen.
   - **Unknown** (under `minScoreSpeech`, starting at 0.5 s, a scoring failure, or a held buffer past 3 s): treated as rejected. Unknown never counts as accepted, and no made-up confidence is reported.
5. **Stale results.** Each check carries the utterance id and session generation. A result for anything else is dropped, and pending state resets on every utterance end, session stop and lock change.
6. **Overlap.** No overlap detector is added. A mixed voice gets whatever score it gets, and normally goes through the same reject path. It is measured and reported, not claimed as handled.
7. **Wake word.** The wake listener keeps the last 2 s of frames. On a detection with the lock on, the phrase's audio is scored before `start()`. Not accepted means she stays asleep, the listener stays armed, and `wake-rejected` is recorded. Needs T-060a.
8. **Stop phrases.** With the lock on, a spotted stop phrase is scored on its own recent audio before it stops her. Not accepted means she continues. 「停」 is too short to verify reliably, so row 12 measures it, and the owner decides from that whether it stays.
9. **Interruption.** With the lock on, `BargeInLive` acts only on an accepted utterance: no dip or stop before acceptance.
10. **Switching during a session.** Turning it off releases any held utterance and stops scoring. Turning it on applies from the next utterance. Neither restarts the session.
11. **If scoring breaks while locked.** It fails closed: speech is not sent, and the chip says 「声纹不可用，可在设置关闭」. The talk button and the settings still work.
12. **Lock off.** `SpeakerHold` is bypassed completely, no model is loaded and no scoring runs. Outputs are byte-for-byte what they are today.

## 7. Seeing what happened

Record lines, numbers only: `speaker-check utterance=<id> kind=<speech|wake|stop> score=<n> threshold=<n> result=<accepted|rejected|unknown> speechMs=<n> scoreMs=<n> waitMs=<n>`. The utterance line's `muteReason` gains `speaker`. `RuntimeLog` gets the same numbers with no words or audio (I-8).

## 8. Acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Lock off, a scripted utterance | Outputs equal today's; no verifier call and no model load | unit |
| 2 | Lock on: accepted at 1.0 s | Nothing is forwarded before the result; then the pre-roll and frames in original order, with no gap or duplicate | unit |
| 3 | Lock on: rejected; unknown; scoring failure; buffer past 3 s | Nothing is forwarded; no driver turn, tool call or driver line; `muteReason=speaker` | unit |
| 4 | A late result for an old utterance or old session | Dropped; it cannot authorize the new one | unit |
| 5 | Lock on to off with an utterance held; off to on mid-utterance | Released in order; the open utterance continues, and the next one is verified | unit |
| 6 | Enrollment: too short, clipped, sentences that disagree | Not saved, with the reason shown | unit |
| 7 | Profile: save and reload; re-enroll fails; delete; model name changes; wipe-all | Survives reload; the old one is kept; removed and lock off; invalid and lock off; removed | unit |
| 8 | Switch on with no profile, or no threshold | Enrollment or calibration opens; the switch stays off until it succeeds | unit |
| 9 | Wake and stop phrase with the verifier rejecting, then accepting | No start and no stop, then start and stop | unit |
| 10 | `scripts/speaker_eval.py` on real, labelled clips | Reports false accept and reject rates; the labels and source are written down; not mocked scores | script |
| 11 | Device: enroll, close and reopen the app | Status and lock preference survive; no second enrollment | D |
| 12 | Device, lock on, parked: driver 30 lines, including short ones (「第一个」, 「打开空调」, 「停」) | Note false rejects by length, and whether first words are kept | D |
| 13 | Device, lock on: passenger 30 lines, with commands, 「你好小诺」 and 「别说了」 | Note false accepts; no tool action from any rejected line | D |
| 14 | Device, lock off: driver and passenger | Both work as before | D |
| 15 | Device: turn the lock on and off during a session | Takes effect with no restart | D |
| 16 | Device: driver and passenger talk at once, 10 times | Note what happens; no claim of separation | D |
| 17 | Device, lock on and off: 20 turns each | Note added delay (`waitMs`, `scoreMs`), CPU, memory, and the 响应速度 sheet | D |
| 18 | Device: repeat rows 12–13 while driving with road noise | Note the rates; calibration in a parked car may not hold here | D |

## 9. Not changed

Echo cancellation, noise suppression, VAD rules, the wake word engine, the Gemini setup, and everything with the lock off. No new subagents, no new cloud service.

## 10. Implementation notes

- **Delay.** Holding until 1 s of speech adds about that much before audio starts going up, on top of the times in the 响应速度 sheet. Row 17 measures it.
- **App size.** Development builds carry the model in the bundle (about 28 MB). App Store and TestFlight builds do not; it is downloaded at install (§12). `scripts/fetch_sherpa_models.sh` and `scripts/sherpa/models.sha256` pin the model, as for ASR and KWS.
- **Docs.** Update `specs/ios-architecture.md` (§3.2 and the ports table), `specs/features/README.md` and `specs/STATUS.md`.
- **Trace gate.** Add `T-013e: F-04b` to `specs/trace-ids.txt` together with the first `@Test` that names F-04b; the gate fails before a test exists.
- **Decision.** No pass bars are set here. The owner reads rows 12–18 and decides whether the lock stays, what threshold to use, and whether 「停」 needs its own rule.

## 11. Tasks

| Task | Scope | Verify |
|---|---|---|
| T-013e | §3–§10; rows 1–18 | unit, script, build, D |
| T-013f | §12; rows 19–26 | unit, script, build, D |
| T-013g | §13; rows 27–36 | unit, build, D |
| T-013h | §14; rows 37–46 | unit, build, D |
| T-013i | §15; rows 47–50 | unit, build, D |
| T-013j | §16; rows 51–61 | unit, build, D |

## 12. Model delivered at install, not in the app (owner request 2026-11-05)

**Goal.** The App Store download does not carry the speaker model. iOS fetches it by itself when the app is installed or updated, so the lock works offline from then on, with no step for the driver.

1. **Mechanism: Apple-hosted Background Assets** (iOS 26+). The model is an *asset pack* uploaded to App Store Connect with each build that changes it. Its download policy is **essential** for first installation and for updates, so iOS downloads it with the app. No server of ours and no key.
2. **Pack contents.** The pack is `speaker/` exactly as `fetch_sherpa_models.sh` writes it: `speaker.json` and the `.onnx` file. Pack id `speaker-campplus-v1`; a new model gets a new id.
3. **Where the app loads the model from**, first match wins:
   1. `SherpaModels/speaker` in the bundle (Debug builds from Xcode, which keep the fetch-script model);
   2. the downloaded pack, after its sha256 matches the pinned value (`SpeakerModelPin`); a mismatch is treated as not downloaded.
   Release **archives** (App Store / TestFlight) strip `SherpaModels/speaker` from the bundle (`NOVA_BUNDLE_SPEAKER_MODEL = NO` and `ACTION=install`). Every `build` keeps it, including the unsigned Codemagic IPA the owner sideloads: Apple-hosted packs reach only TestFlight and App Store installs. ASR and KWS models stay in the bundle. Builds without the BA Info.plist keys (the xtool build) never touch `AssetPackManager`.
4. **States shown under 声纹锁定**, from a pure `SpeakerModelAvailability`:
   - ready → the normal rows (§3);
   - downloading → 「声纹模型下载中」, switch stays off;
   - failed / not on the phone → 「声纹模型下载失败」 and a **重试** button that asks the system again;
   - iOS older than 26 with no bundled model → 「声纹锁定需要 iOS 26 或更新版本」.
   In every state except ready the lock cannot turn on (§3 item 4). A lock that was on stays on and fails closed (§6 item 11): the stored switch is kept, speech is held and rejected, and the chip shows; it applies again when the pack becomes ready, mid-session included.
5. **No loading before use.** The model is still loaded only when needed (§6 item 12). A verifier is never cached while the model is missing, so a download that finishes later is used without restarting the app.
6. **Packaging.** `scripts/speaker_pack/Manifest.json` (template) and `scripts/make_speaker_pack.sh`: copies the checked `speaker/` folder and runs `xcrun ba-package` on a Mac to make the `.aar`. It refuses to run if the sha256 does not match.
7. **Xcode project.** A downloader ExtensionKit target `NovaDriveAssets` (iOS 26, StoreKit `StoreDownloaderExtension`, no own logic, `EXExtensionPointIdentifier = com.apple.background-asset-downloader-extension`); App Group `group.com.asapacsin.novadrive` on the app and the extension; app-only Info.plist keys `BAAppGroupID`, `BAHasManagedAssetPacks`, `BAUsesAppleHosting`.
8. **Owner steps (once per model, on a Mac):** set the Team for the App Group; run `make_speaker_pack.sh`; upload the `.aar` with Transporter (or `altool` / the App Store Connect API); external TestFlight needs the pack reviewed; install from TestFlight to check.
9. **Not changed.** The model, its checksum, scoring, thresholds and everything in §3–§10. Minimum iOS stays 18 (OQ-IOS-12); only the lock needs 26 when the model is not bundled.
10. **Unverified here.** The BackgroundAssets API names come from Apple's iOS 26 documentation and are compiled only by the Xcode build; this Linux container cannot build the app. Rows 23–26 are device rows.

| # | Given / when | Then | Test |
|---|---|---|---|
| 19 | Bundle model present | Used; no download asked | unit |
| 20 | No bundle model; pack ready and checksum matches | Pack directory used | unit |
| 21 | Pack ready but checksum differs; pack downloading; pack failed; iOS < 26 | Not used; the matching text; lock cannot turn on | unit |
| 22 | `make_speaker_pack.sh` with a wrong or missing model | Refuses, nothing written | script |
| 23 | Device: TestFlight install, first open | Model already present or 下载中 then ready; no bundled model in the `.ipa` | D |
| 24 | Device: airplane mode after the download | Lock works | D |
| 25 | Device: 重试 after a failed download | Downloads, then ready, no restart | D |
| 26 | Device: `.ipa` size before and after | About 28 MB smaller | D |

## 13. Keep calibration progress (owner request 2026-11-05)

**Why.** The owner keeps being asked to set the lock up again. On the phone after the 2026-11-05 21:17 install, the app's data and the 18:12 `profile.json` were still there, so an install does not delete the voiceprint. The profile has no threshold and no calibration scores file exists, so calibration has never finished on this phone. In the code, the scores are `@State` in `SpeakerCalibrationView` until 「使用这个阈值」, so closing the screen or the app loses every line said. 重新录入 also clears the threshold with no warning. The loss on closing is from reading the code; rows 34–36 test it on the phone.

**Sources.** Saving at each step change is the [usual default for multi-step forms](https://www.reform.app/blog/multi-step-form-state-persistence-guide); saving only on submit helps only at the end. Nothing specific to voice enrollment was found. The file handling copies `FileSpeakerProfileStore` (§4 item 4).

1. **Save after every accepted line.** Each score goes straight into a draft file, `Application Support/SpeakerLock/calibration.json`, written atomically with the same protection as the profile and excluded from backup. It holds `driver` and `others` scores, plus the profile's `enrolledAt`, `modelName` and `dimension`. Numbers only, no audio and no embedding. A line rejected as 「没听到说话」 is not saved.
2. **The draft belongs to one voiceprint.** It is used only when those three fields match the loaded profile. A draft that does not match, or cannot be read, is treated as empty and removed.
3. **Coming back.** 校准 opens with the saved counts. The picker starts on 录入的人 if that person has under 20 lines, otherwise on 其他人. The line shown is `lines[count % lines.count]` for the selected person, so each person carries on with their next line. This also replaces the `index` reset when the picker changes.
4. **Progress in 设置.** With a matching draft that has any lines, a row under 「声纹」 says 「校准进度：录入的人 N / 20，其他人 M / 20」, with the real counts. The status texts in §3 item 2 do not change.
5. **Start over.** With any saved lines, 校准 shows 「重新校准」. After a confirmation, 「清除已说的句子并重新开始？」, it empties the draft. The saved threshold is not touched.
6. **Finishing.** 「使用这个阈值」 saves the threshold, writes the §5 item 4 scores file, then removes the draft. If saving the profile fails, the draft stays. Until then, a threshold saved earlier stays in use (§5 item 3).
7. **If a draft write fails.** The score stays on screen for this visit and the screen says 「进度保存失败，关闭后这句会丢失」. Nothing else changes.
8. **Warning before 重新录入.** With a saved threshold or any draft lines, 重新录入 first asks 「重新录入后要重新校准（两人各 20 句）。继续吗？」 with 继续 and 取消. Neither answer changes anything by itself.
9. **Re-recording.** §4 item 5 still applies: a failed enrollment keeps the old profile, threshold and draft. A successful one removes the draft, because its scores were measured against the old voiceprint.
10. **Deleting.** 删除声纹 and the wipe-all (§3 item 5) also remove the draft.
11. **Not changed.** The 20 + 20 lines, the second person, the suggested threshold, the switch rule (§3 item 4), enrollment checks and the live pipeline. Nothing leaves the phone (§4 item 7).
12. **Where the code goes.** The draft type, its match rule and its file store go in `Packages/NovaCore/Sources/NovaVoice/Speaker/`, behind a small store protocol like `SpeakerProfileStore`, so rows 27–32 run as unit tests. The screen changes go in `App/NovaDrive/SpeakerLock.swift`.

| # | Given / when | Then | Test |
|---|---|---|---|
| 27 | Draft: save and reload; write twice | Same scores and fields; the last write wins | unit |
| 28 | Draft with a different `enrolledAt`, `modelName` or `dimension`; unreadable file | Treated as empty and removed | unit |
| 29 | Reload with 12 driver and 3 other lines | Counts 12 and 3; picker on 录入的人; the next line is `lines[12]`, and `lines[3]` after switching; with 20 driver lines the picker starts on 其他人 | unit |
| 30 | Finish with a working store; profile save fails | Threshold saved and draft removed; draft kept | unit |
| 31 | Enrollment fails; enrollment succeeds | Profile, threshold and draft all kept; new profile with no threshold, draft removed | unit |
| 32 | 删除声纹; wipe-all; 重新校准 | Draft removed; removed; emptied with the threshold kept | unit |
| 33 | Device: 校准 with a saved threshold or draft lines, press 重新录入, then 取消 | The warning appears; after 取消, voiceprint, threshold and draft are unchanged | D |
| 34 | Device: say 5 lines, press 关闭, reopen 校准 | Count is still 5, next line is the sixth | D |
| 35 | Device: say 5 lines, force-quit the app, install a new build over it, reopen 校准 | Count is still 5; 设置 shows the progress row | D |
| 36 | Device: finish calibration, turn the lock on, install a new build over it, reopen 设置 | Status 已录入, switch still on, no calibration asked; `speaker-check` lines show the same threshold | D |

**Trace gate.** Add `T-013g: F-04b` to `specs/trace-ids.txt` together with the first `@Test` that names T-013g.

## 14. Calibrate on the clip the live check scores, and show what the lock did (owner request 2026-11-06)

**Why.** Device 2026-11-06, 339f513, installed over 289ecc2 at 10:19. The voiceprint (enrolled 11-05) and the calibration finished at 09:02 (threshold 0.46) both survived the install, and the lock was on. From 10:20 to 10:22 every sentence the owner said was rejected: `speaker-check` scores 0.25, 0.09, 0.03, 0.39, 0.43, 0.44, all `kind=speech speechMs≈1000–1200 result=rejected`, each `sentToModel=false muteReason=speaker`. Only 「你好小诺」 passed (`kind=wake speechMs=2000 score=0.492`). Nothing on screen said a sentence had been dropped, so the app looked dead, and the owner turned the lock off at 10:22. In the 09:02 calibration file the same driver's lines scored 0.37–0.71 (19 of 21 at 0.46 or above) and the other person's 0.19–0.45. Three causes, from the code:
1. **Different clips.** 校准 scores each line's whole take (`SpeakerCalibrationView` sends `take.frames`). The live check scores only the first `minVerifySpeech` (1.0 s) of an utterance (§6 item 3, `SpeakerHold`). The threshold is set on whole lines and applied to 1-second clips.
2. **Nothing shown after calibration.** 「使用这个阈值」 saves the threshold and `calibratedAt` in the profile, then deletes the draft (§13 item 6). The 设置 row exists only while a draft exists (§13 item 4), so after finishing, 设置 shows no calibration, and 校准 reopens at 0 / 20.
3. **Nothing shown on a rejection.** A rejected utterance leaves no driver line and no message (§6 item 4).

Cause 1 is the most likely reason for the low live scores, but it is not proved: the calibration file holds no 1-second scores. Row 45 checks it.

**Sources.**
- Thresholds set on long test audio do not hold for short test audio; scores and the best threshold move with test duration, so calibration data should match the test duration, or calibration should depend on it: [Intelligent Voice 2016 system](https://arxiv.org/pdf/1611.00514) (threshold moves with enrollment and test duration), [Cumani et al.](https://iris.polito.it/retrieve/handle/11583/2979926/656155) (global calibration fitted on long segments fails on short ones), [duration-aware calibration](https://iris.polito.it/retrieve/handle/11583/2968877/594269), [Duke short-utterance paper](https://sites.duke.edu/dkusmiip/files/2022/11/663_Paper.pdf).
- No vendor publishes a fixed threshold for this model. sherpa-onnx's [speaker identification example](https://k2-fsa.github.io/sherpa/onnx/javascript-api/examples/speaker_identification.html) uses 0.5 and [speakeronnx](https://pypi.org/project/speakeronnx/0.0.2a1/) 0.45; [Picovoice](https://picovoice.ai/cookbook/ai-voice-assistant-speaker-recognition/) leaves the cutoff to the app. So the threshold stays measured on the phone (§5).
- Saying so when a voice is not verified: Google Nest speakers answer 「I can't verify your voice」 ([Nest community](https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Error-msg-I-can-t-verify-your-voice/m-p/277322)). That is from user reports, not a design guide. Here it is text only, so a passenger's speech does not make her talk.

**Rule in plain words.** 校准 scores exactly the audio the live check will score. A threshold measured the old way is not used. 设置 always shows the saved calibration. When the lock drops a sentence, the screen says so.

1. **One clip rule for both.** A pure `SpeakerVerifyClip.frames(_ frames: [PCMFrame16k], tuning: SpeakerTuning) -> [PCMFrame16k]?` in `NovaVoice` returns the first `minVerifySpeech` of the frames, in order; all of them when there is less, if that is at least `minScoreSpeech`; nil below that. `SpeakerHold` uses the same `SpeakerTuning` values, so a change to `minVerifySpeech` changes both. A unit test feeds one frame sequence to `SpeakerHold` and to `SpeakerVerifyClip` and checks that the scorer receives the same frames.
2. **校准 scores the clip.** Each accepted line is scored on `SpeakerVerifyClip.frames(take.frames)`, not the whole take. nil keeps today's 「没听到说话，请再说一次。」 and saves nothing. The whole take is also scored, for the file only: it is not used for counts, the table or the suggested threshold.
3. **Scores file.** Each line becomes `driver <clip score> whole=<whole score>` or `other <clip score> whole=<whole score>`, plus a first line `clipMs=<minVerifySpeech in ms>`. Numbers only, as §5 item 4.
4. **The threshold records its clip.** `SpeakerProfile` gains `calibrationClipMs: Int?`, `calibrationDriverLines: Int?` and `calibrationOtherLines: Int?`, all optional so old files still load. 「使用这个阈值」 sets them with the threshold and `calibratedAt`. The draft gains `clipMs`; a draft without it, or with another value, does not match (§13 item 2) and is removed.
5. **An old threshold is not used.** A profile with a threshold but `calibrationClipMs` missing or not equal to the current `minVerifySpeech` in ms is a new status, `recalibrate`:
   - status text 「已录入，需要重新校准」, and under it 「校准方法已更新：请重新校准一次（两人各 20 句），声纹不用重新录入。」;
   - `liveThreshold()` is nil, so the lock cannot turn on (§3 item 4), and a switch that is on is turned off the way `dropInvalidLock` does for `invalidModel`;
   - the voiceprint, `enrolledAt` and the old threshold stay in the file; 重新录入 is not needed or asked for.
6. **设置 shows the saved calibration.** With status `ready`, a row under 「声纹」 says 「已校准：{M月D日}，阈值 {0.00}（录入的人 {N} 句，其他人 {M} 句）」 from the profile, in the phone's time zone. With status `recalibrate` it says 「上次校准：{M月D日}，阈值 {0.00}（旧方法，已停用）」. The §13 item 4 progress row still shows, below it, while a draft exists.
7. **校准 shows it too.** With a saved threshold, the top of 校准 shows the same text as item 6. Saying new lines does not change the saved threshold until 「使用这个阈值」 (§13 item 6).
8. **Dropped sentence shown on screen.** With the lock on and a session running, each utterance the lock rejects or marks unknown (§6 item 4, `kind=speech`) shows 「没听出是录入的声音，这句没有发送」 for 3 s in the place where the §6 item 11 chip appears. Text only: no sound, no driver line, no turn. A new rejection restarts the 3 s; it never stacks. While the §6 item 11 chip is showing, that chip wins. A rejected wake word (§6 item 7) shows 「没听出是录入的声音，没有唤醒」 for 3 s on the idle screen. Rejected stop phrases show nothing. Accepted utterances and lock off show nothing.
9. **Not changed.** `minVerifySpeech` (1.0 s), `minScoreSpeech`, the 20 + 20 lines, the suggested-threshold rule, enrollment, the wake check's 2 s of audio and its use of the same threshold, and §13's draft saving. Known effect, not fixed here: the wake check scores 2 s against a threshold now set on 1 s clips, so it may accept others a little more easily. Row 46 notes it.
10. **Where the code goes.** `SpeakerVerifyClip`, the profile and draft fields, the `recalibrate` status and the item 6 texts go in `Packages/NovaCore/Sources/NovaVoice/Speaker/`, so rows 37–42 are unit tests. The rejection notice is a published event from the gate to `AgentModel`, like `speakerUnavailable`; the screens are in `App/NovaDrive/SpeakerLock.swift`, `DriveView.swift` and the wake idle view.

| # | Given / when | Then | Test |
|---|---|---|---|
| 37 | `SpeakerVerifyClip` with 2.5 s, 0.8 s and 0.4 s of frames | First 1.0 s; all 0.8 s; nil. The same frame sequence through `SpeakerHold` sends the scorer the same frames | unit |
| 38 | 校准 adds a line from a 2.5 s take | The clip score goes into the draft and counts; the scores file line has both numbers, and the file starts with `clipMs=1000` | unit |
| 39 | 「使用这个阈值」 with 21 and 20 lines | Profile has the threshold, `calibratedAt`, `calibrationClipMs` 1000, lines 21 and 20; draft removed | unit |
| 40 | Profile with threshold 0.46 and no `calibrationClipMs` (today's file); with 500; with 1000 | `recalibrate`, `liveThreshold` nil, switch turned off, file unchanged; `recalibrate`; `ready`. A draft without `clipMs` is removed | unit |
| 41 | Item 6 and 7 texts from a profile calibrated 2026-11-06T01:02:37Z, 0.46, 21 and 20, zone Asia/Macau | 「已校准：11月6日，阈值 0.46（录入的人 21 句，其他人 20 句）」; the old-method text for `recalibrate` | unit |
| 42 | Lock on: speech rejected; unknown; accepted; wake rejected; stop phrase rejected; lock off | One notice each for the first two, with the item 8 text; none; the wake text; none; none | unit |
| 43 | Device: install over 339f513, open 设置 | 「已录入，需要重新校准」 with the item 5 text and the old-method row; the switch cannot turn on; no 录入 asked | D |
| 44 | Device: 校准 20 + 20, 「使用这个阈值」, close and reopen 设置 and 校准, then install a new build over it | The item 6 row with the real date, threshold and counts, before and after the install; 校准 shows it at the top | D |
| 45 | Device, lock on, parked: the driver says 20 everyday commands | Note accepted out of 20, and compare the live `speaker-check` scores with the driver's clip scores in the scores file | D |
| 46 | Device, lock on: the other person says 10 commands and 「你好小诺」 3 times | Each command shows the item 8 notice and gets no reply; note how many wake words pass | D |

**Trace gate.** Add `T-013h: F-04b` to `specs/trace-ids.txt` together with the first `@Test` that names T-013h.

## 15. Keep the threshold calibrated before §14 (owner decision 2026-11-06)

**Why.** After 281b72d the owner's profile (calibrated 2026-11-06 09:02, threshold 0.46, whole-line scores) shows 「已录入，需要重新校准」 and the lock cannot turn on (§14 item 5). The owner does not want to record 20 + 20 lines again: the lock did work for them with that threshold, and they think the unreliable moments came from other causes, such as app stability or the network. §14's claim that whole-line thresholds are too high for the 1 s live clip is not proved (§14 "Why"). On 2026-11-06 10:20–10:22 six speech checks were rejected at 0.46, which is the only data either way. Owner's decision: keep using the old threshold; do not force recalibration.

This section replaces §14 item 5 and row 43. §14 items 1–4 and 6–10 stay: a new calibration still scores the 1 s clip and records `calibrationClipMs`.

1. **An old threshold is used as it is.** A profile with a threshold and **no** `calibrationClipMs` is `ready`. `liveThreshold()` returns its threshold, the switch can turn on, and a switch that is on stays on. Nothing in the file changes.
2. **`recalibrate` only for a recorded, different clip.** `recalibrate` (§14 item 5 texts and behaviour) applies only when `calibrationClipMs` is present and differs from the current `minVerifySpeech` in ms. Today no profile has that, so it is only for a future change of `minVerifySpeech`.
3. **What 设置 and 校准 show for an old threshold.** 「已校准：{M月D日}，阈值 {0.00}（整句校准）」, from `calibratedAt` and the threshold. No line counts, because the old file has none. The §14 item 6 text with counts stays for profiles calibrated after §14.
4. **Calibrating again is optional.** 校准 stays available. Saying new lines does not change the old threshold until 「使用这个阈值」 (§13 item 6); after that the profile has `calibrationClipMs` and the §14 item 6 text.
5. **Not changed.** §14 items 1–4 and 6–10, the rejection notice (§14 item 8), the draft rules (§13), enrollment, the live pipeline, and `minVerifySpeech` (1.0 s).

| # | Given / when | Then | Test |
|---|---|---|---|
| 47 | Profile with threshold 0.46, `calibratedAt` 2026-11-06T01:02:37Z, no `calibrationClipMs`; switch on | `ready`; `liveThreshold` 0.46; switch stays on; file unchanged; 设置 text 「已校准：11月6日，阈值 0.46（整句校准）」 (Asia/Macau) | unit |
| 48 | Same profile with `calibrationClipMs` 1000; with 500 | `ready` with the §14 item 6 text; `recalibrate` | unit |
| 49 | Device: install over 281b72d, open 设置 | 「已录入」, the item 3 row, the switch turns on; no calibration asked | D |
| 50 | Device: lock on, the driver says 20 everyday commands; then the other person says 10 | Note accepted out of 20, rejected out of 10, and that each rejection shows the §14 item 8 notice | D |

**Trace gate.** Add `T-013i: F-04b` to `specs/trace-ids.txt` together with the first `@Test` that names T-013i.

## 16. Threshold slider in 设置 (owner request 2026-11-06; moved here from local commit 9ed69d8, where it was numbered §14 / T-013h)

**Why.** On 2026-11-06 the lock dropped the owner's voice. Calibration that morning saved 0.46, just above the other person's highest score (0.454). The owner's own calibration lines scored 0.366–0.707. In use that day, the owner's accepted scores were mostly 0.48–0.65, and 8 of the 26 loud (84–92 dB) utterances it scored were rejected at 0.37–0.455. Three of them came right after an accepted 你好小诺 (0.492). The owner asked for a slider to raise and lower the threshold by hand, to match what they see. §5 item 1 still holds: there is no built-in threshold, and the slider only moves one that 校准 has set.

**Source.** A verification threshold trades false rejects against false accepts. It is chosen from those two measured rates, as on the DET curve (Martin et al., *The DET curve in assessment of detection task performance*, Eurospeech 1997). So at every value, the slider shows those two counts from the owner's own calibration.

**Fits §14 and §15 (built in 281b72d and 50a55a4).**
- "Status 「已录入」" in item 1 means `ready`, which since §15 includes a threshold calibrated before §14. The slider is hidden for `recalibrate` and for every status without a threshold.
- The §14 item 6 and §15 item 3 rows show the saved threshold, so after a slider save they show the slider's value. `calibratedAt`, `calibrationClipMs` and the line counts are not changed by the slider.
- Item 4's Documents fallback reads both scores file formats: the §14 format (first line `clipMs=<ms>`, lines `driver <clip score> whole=<whole score>`) uses the clip score; the older format (lines `driver <score>`) uses that score. Row 55 covers both.

1. **Where.** In `Section("声音")`, under the 声纹 row. It is shown only when the status is 「已录入」, meaning a threshold is saved. The title is 「声纹阈值 0.46」 with the current value, followed by a `Slider` with step 0.01 (`SpeakerCalibration.step`). The range is 0.30–0.70, widened to include the saved value when it lies outside.
2. **Words.** Under the slider: 「调低：你更少被拒，别人更容易通过。调高：别人更难通过，你更容易被拒。」
3. **Counts at the value under the finger.** One line from `SpeakerCalibration.row(at:)` on the saved calibration scores: 「校准时：你的 21 句里被拒 2 句，别人的 20 句里通过 0 句」, with the real counts. Below it, 「校准建议 0.46」 (`suggested`) and a 「恢复建议值」 button, which moves the slider to that value and saves it (item 6).
4. **Where the scores come from.** 「使用这个阈值」 in 校准 also writes the scores to `Application Support/SpeakerLock/calibration-result.json`. The file also holds the profile's `enrolledAt`, `modelName` and `dimension`, uses the same protection, and is excluded from backup, like the §13 draft. It is used only when those three fields match the loaded profile. A file that does not match, or cannot be read, is removed. A calibration finished before this change has no result file. In that case the newest `Documents/speaker-calibration-<stamp>.txt` (§5 item 4) whose stamp is later than `enrolledAt` is read once and written as the result file. With no usable scores, the slider still works. The count line then says 「没有校准分数，无法显示误拒和误通过」, and 恢复建议值 is hidden.
5. **Recent live scores.** `SpeakerLockService` keeps the last 20 `kind=speech` scores of this app run in memory: score and result, numbers only (I-8), never saved. Under the counts, 「最近 20 次（任何说话的人）：」 lists them newest first, with rejected ones marked, for example 「0.45✗ 0.52 0.40✗」. With none yet it says 「还没有分数」. The list refreshes when the section appears and after each save.
6. **Saving.** The value is saved when the finger lifts (`onEditingChanged` false), not at every step. It is snapped to the 0.01 grid and written as the profile's threshold only, atomically, through `SpeakerProfileStore`. A failed save puts the slider back to the saved value and shows 「阈值保存失败」.
7. **Applies with no restart.** After a save, `SpeakerLockService` posts a notification. The session runtime and the wake listener observe it and call `setSpeakerLock(liveThreshold())` / `setLock(threshold:)`, as they do for the switch (§6 item 10). The next utterance, wake word and stop phrase use the new value. An utterance that is being checked at that moment follows the existing generation rule: its result is dropped and it ends as unknown. This is stated here, not changed.
8. **Record line.** `speaker-threshold old=<n> new=<n> source=slider|suggested` goes to the record and to `RuntimeLog`, numbers only. `speaker-check` lines already carry the threshold in use.
9. **Calibrating and re-recording.** 「使用这个阈值」 in 校准 still sets the threshold, and the slider then shows the new value. A successful 重新录入 still leaves a profile with no threshold, so the slider is hidden until 校准 (§13 item 9). The result file is removed on a successful enrollment, on 删除声纹 and on wipe-all, like the draft.
10. **Not changed.** These stay as they are:
    - the suggestion rule (§5 item 3);
    - `minVerifySpeech` and scoring;
    - the switch rule: the lock still needs a calibrated threshold before it can turn on (§3 item 4);
    - the live pipeline.

    Nothing leaves the phone (§4 item 7).
11. **Where the code goes.** These go in `Packages/NovaCore/Sources/NovaVoice/Speaker/`, pure, so rows 51–57 run as unit tests:
    - the result type and its file store, behind a small store protocol like `SpeakerCalibrationDraftStore`;
    - the Documents fallback reader;
    - the range rule and the count line;
    - the recent-score ring.

    The view goes in `App/NovaDrive/SpeakerLock.swift`. The notification goes in `SpeakerLockService`, and its observers in `App/NovaDrive/AgentRuntime.swift` and `App/NovaDrive/Wake/WakeListener.swift`.

| # | Given / when | Then | Test |
|---|---|---|---|
| 51 | Status 已录入; 已录入，未校准; 未录入; 声纹模型不可用 | Slider shown at the saved value; hidden; hidden; hidden | unit |
| 52 | Saved threshold 0.46; saved 0.75; saved 0.25 | Range 0.30–0.70; 0.30–0.75; 0.25–0.70 | unit |
| 53 | The 2026-11-06 scores (21 driver, 20 other) at 0.46 and at 0.40 | 被拒 2 / 21, 通过 0 / 20; 被拒 2 / 21, 通过 3 / 20; suggestion 0.46 | unit |
| 54 | Result file: save and reload; a different `enrolledAt`, `modelName` or `dimension`; unreadable file | Same scores; treated as empty and removed; removed | unit |
| 55 | No result file; Documents holds one scores file older and one newer than `enrolledAt`, the newer in the §14 format; again with the newer in the older format | The newer one is read and written as the result file; with neither, the 没有校准分数 line and no 恢复建议值 | unit |
| 56 | Finger lifts at 0.403; 恢复建议值; the profile save fails | Threshold 0.4 saved and `speaker-threshold old=0.46 new=0.4 source=slider`; 0.46 saved with `source=suggested`; slider back to the saved value and 「阈值保存失败」 | unit |
| 57 | Ring after 25 speech checks and 3 wake checks | The last 20 speech scores, newest first, rejected ones marked; no wake scores | unit |
| 58 | Device: during a session, move the slider from 0.46 to 0.40, then talk | The next `speaker-check` lines show `threshold=0.4`; no restart; a `speaker-threshold` line in the record | D |
| 59 | Device: say 10 lines with the lock on, then open 设置 | 最近 20 次 shows those scores; the count line matches the pulled scores file | D |
| 60 | Device: on this phone, calibrated before this change, open 设置 after the install | Counts shown from the 2026-11-06 scores file, with no new calibration | D |
| 61 | Device: set 0.42, install a new build over it, reopen 设置 | Slider at 0.42; switch still on | D |

**Trace gate.** Add `T-013j: F-04b` to `specs/trace-ids.txt` together with the first `@Test` that names T-013j.
