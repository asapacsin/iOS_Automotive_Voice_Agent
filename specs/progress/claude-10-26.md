# Progress — Claude session, 2026-10-26

Branch `feat/live-agent-nav`, PR https://github.com/asapacsin/iOS_Automotive_Voice_Agent/pull/7 (open, not merged).

## Done
| Item | Where | Evidence |
|---|---|---|
| T-030 F-10 ambiguity: 「再低一点」 after seat + temperature → 「是座椅还是温度？」 | `NovaTools/Context/ContextResolver.swift`, wired in `AgentState` | unit tests green (CI core-linux, core-macos) |
| T-040/T-041 F-15 navigation flow (search → pick → routes → start → exit, generation-tagged, 120 s expiry, one start) | `NovaNav/Flow/NavigationController.swift` | unit tests green |
| F-18 live info: route_traffic (engine numbers), weather (Amap) | `NovaNav/LiveInfo/LiveInfoExecutor.swift` | build green |
| Amap Web client (place text/around, regeo, weather) | `NovaServices/AmapWeb/AmapWebClient.swift` | build green |
| Route engine on Amap Web driving directions + **simulated movement** (no Amap Navi SDK) | `NovaServices/AmapWeb/AmapRouteEngine.swift` | build green |
| Live audio: Apple voice processing capture, reply + guidance lanes, epoch flush | `NovaAudio/LiveAudio.swift` | build green |
| App 驾驶 tab: composition root, status chip, map, choice list, HUD, simulated car card, Azure region auto-detect | `App/NovaDrive/AgentRuntime.swift`, `DriveView.swift` | IPA built, installed on iPhone 17 |
| Camera button + preview + vision questions — **spec only** | `specs/features/camera-view.md` (PROPOSED) | — |

## Device findings (iPhone 17, iOS 26.6.1)
- 驾驶 → 开始对话 showed **出错 MALFORMED**: Gemini closed 1007 on setup because the live model rejects any
  `thinkingLevel` (fixture close1007: "Thinking level is not supported for this model."). Fixed in commit
  "fix(app): no thinkingLevel in the live setup"; the build with the fix was **not yet installed/verified**.
- Gemini key works on device (录制 tab: plain/tool/interrupted/resumption/close1008 recorded).
- Azure and 高德 keys are saved in 设置; not yet exercised on device.

## Not done
- On-device run of the full flow (talk, 座椅/温度 question, 导航去珠海站 → route → simulated drive).
- 5-minute demo recording + evidence sheet (specs/demo-recording.md). Open question: who speaks the driver
  lines — the owner, or synthetic speech from the PC (no Chinese voice installed on this PC).
- Merge of PR #7; camera feature implementation (T-071a–d); OQ-CAM-1/2 owner decisions.

## How to resume
1. Elevated `pymobiledevice3 remote tunneld` (UAC), then WebDriverAgent xcuitest + `usbmux forward 8100 8100`.
2. Install the latest `ipa` artifact with xtool from an ASCII path (`D:\ndipa\<sha>\NovaDrive.ipa`), run from
   PowerShell (Git Bash rewrites `/mnt/d/...`).
3. 驾驶 → 开始对话; the chip shows the error code if the session fails.
