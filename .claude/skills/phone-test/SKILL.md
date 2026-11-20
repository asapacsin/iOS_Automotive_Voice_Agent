---
name: phone-test
description: Prepare and run a NovaDrive phone test end to end - Codemagic build of a branch, get the IPA, install it on the owner's iPhone as an update (keep data), drive and monitor the phone, hand over the checklist. Use whenever a phone/device test, an IPA, Codemagic, xtool or the iPhone comes up.
---
# Phone test runbook (AGENTS.md owner rule 2026-11-13)

Claude does every step; ask the owner only for what is marked OWNER. When a step here is wrong or a value is
missing, fix this file in the same session (commit it) so the next session does not relearn it.

## 0. Where things run
- **Cloud session (here):** Linux, no phone, no Xcode. Starts the Codemagic build, downloads the IPA.
- **Owner's Windows PC:** iPhone 17 on USB; WSL `Ubuntu-22.04` with `xtool`; pymobiledevice3 at
  `C:\Users\Administrator\AppData\Local\novadrive-tools\venv312\Scripts\pymobiledevice3.exe`; IPAs in `D:\ndipa\`.
  Reach it with `list_computer_folders` then `request_computer_folder`, then run commands with `_host`.
  If no folder is listed or the PC is offline: OWNER opens the Claude desktop app there (Settings, Claude Code,
  Remote Control). Do not guess another route.

## 1. Build (Codemagic REST API, https://docs.codemagic.io/rest-api/builds)
- Auth header is **`x-auth-token`** (not `Authorization`). The value is a network secret on the environment for
  `api.codemagic.io`, injected by the proxy; send `-H "x-auth-token: proxy-injected"`. A 401 means the secret is
  missing, wrong, or saved under the wrong header: ask with `request_credential` (host api.codemagic.io,
  header_name `x-auth-token`, no prefix; an `Authorization` secret gives 401). Never put the token in a file or the chat.
- App id: `curl -s https://api.codemagic.io/apps -H "x-auth-token: proxy-injected"` -> the app whose repository is
  asapacsin/iOS_Automotive_Voice_Agent. Record it here once known: **APP_ID = `6ae16755fe16d00f4e50d187`** (verified 2026-11-20).
- Start: `POST https://api.codemagic.io/builds` with `{"appId": APP_ID, "workflowId": "novadrive-ios",
  "branch": "<branch under test>"}` -> `buildId`. Workflow id comes from `codemagic.yaml` (the API does not list it).
- Wait: `GET /builds/<buildId>` about every 2 minutes with Monitor (an until-loop), not a sleep chain. The build
  takes about 10-20 min (`max_build_duration: 20`).
- IPA: the finished build's `artefacts[]` entry ending in `.ipa` has a `url`; download it with the same header
  (unverified: if that URL refuses, read the Builds API page for the public-url call and update this file).
  Name it `NovaDrive-<short sha>.ipa` (ASCII path, xtool needs it).

## 2. Install as an update (never delete and reinstall)
- Copy the IPA to `D:\ndipa\` on the PC, then on the PC:
  `python scripts\device\phone_check.py --ipa D:\ndipa\NovaDrive-<sha>.ipa --out D:\ndipa\check-<sha>`
  It runs `xtool install` in WSL (same bundle id `XTL-Y6YT9YM42U.com.asapacsin.novadrive`, so the app's data and
  Keychain keys stay), then walks the screens and writes a PASS/FAIL report with screenshots.
- Never run an uninstall. If xtool says the bundle id or team differs, stop and tell the owner (a different
  signing team would install a second app and lose nothing, but it is not an update).
- xtool can take 20+ minutes; run it in the background and wait on its output.

## 3. Before it works (once per PC boot) - OWNER only if it fails
- Phone plugged in, unlocked, trusted.
- Elevated `pymobiledevice3 remote tunneld` running (UAC prompt once per boot): phone_check reports
  "WebDriverAgent did not answer" when it is not.
- WebDriverAgentRunner installed on the phone (`XTL-Y6YT9YM42U.com.facebook.WebDriverAgentRunner.xctrunner`).
- Taps go by screen position for iPhone 17 (WDA element lookup returns HTTP 500); positions are in phone_check.py.

## 4. Monitor during the test
- phone_check report + screenshots in `--out`.
- Device log while the owner tests (on the PC): `pymobiledevice3 syslog live` filtered to NovaDrive
  (unverified flags: check `pymobiledevice3 syslog live --help` and record the working line here).

## 5. Hand over
- The checklist for the build: the device rows still NOT_VERIFIED in specs/STATUS.md and the feature specs
  (`scripts/spec_section.py <feature> <§>`), as a short numbered list with the exact words to say.
- Afterwards record each row PASS / FAIL with the build sha in specs/STATUS.md.
