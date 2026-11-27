# NovaDrive (小诺) for iPhone

A Mandarin voice assistant for the car. The phone sits on the dashboard; the driver talks, keeps both hands on the
wheel, and 小诺 navigates, answers live questions, plans trips and controls the cabin (simulated). This repository is
the iOS app, ported from an Android version, and the AI engineering system that builds and tests it.

## What it does for the driver

| Say | What happens |
|---|---|
| 「你好小诺」 | Wakes her up offline, no account needed |
| 「导航去珠海站」 | Finds the place on 高德 (Amap), offers routes, starts real turn-by-turn guidance |
| 「还要多久？」「附近有加油站吗？」 | Answers during navigation without losing the route |
| 「帮我规划一天澳门行程」 | Builds a multi-stop trip (mainland, Macau, Hong Kong), times each leg, then navigates stop by stop |
| 「现在天气怎么样？」 | Looks it up from a real source, or says it cannot; never invents |
| 「有点热」「再凉一点」 | Changes the (simulated) air-con and says what it actually did |
| 「放周杰伦的歌」 | Plays music, and only says so if it really plays |
| 「前面那是什么车？」 | Looks through the camera and answers |
| 「别说了」 | Stops her at once; other noise never does |

## Why it is different

- **Honest by construction.** She only says 「空调开了」 after the action really happened. Claims are checked in code
  against tool results before you hear them; a false claim is cut (product rules I-1 to I-14 in
  `specs/product-spec.md`, all enforced in code, never by prompt alone).
- **Only your voice.** A voiceprint lock (声纹锁定) means passengers or the radio cannot drive her.
- **Mandarin only, short answers.** She always replies in Mandarin and keeps it short: the driver's eyes are on the road.
- **Private.** Wake word, voiceprint, stop phrase and a local transcript run on the phone. Logs carry no addresses,
  coordinates or transcripts.
- **Choice of brain.** The voice model is Gemini Live, with Qwen-Audio realtime (Alibaba, Beijing, no VPN) being added
  as a switch in 设置 so the two can be compared on speed.

## How 小诺 works (the in-car agent)

```
 microphone ─▶ on-phone gate ─────────▶ voice model ─────────▶ checks ─────────▶ speaker + screen
               speech? (Apple            Gemini Live or         Mandarin?         her own voice,
               SoundAnalysis)            Qwen-Audio realtime    claim proven       map, cards
               your voice? (CAM++)       understands, talks,    by a tool result?
               finished? (1.2 s quiet)   calls tools
                                              │
                                              ▼
                                  tools: navigation, places, trip plan,
                                  weather / traffic, web search, music,
                                  volume, climate, camera, phone call
```

- **The model understands; code checks.** The model decides what you meant and which tool to call. Narrow, fixed
  tools exist only for car functions; for information she searches herself.
- **On-phone models** (sherpa-onnx, offline): CAM++ voiceprint, a streaming Zipformer Mandarin recognizer, a stop-phrase
  spotter and the wake word. Apple's SoundAnalysis tells a human voice from noise.
- **Code layout.** Pure logic lives in `Packages/NovaCore` (no UIKit or AVFoundation, fully unit-tested). Each vendor
  SDK sits in its own adapter package: `NovaRealtime` (Gemini, Qwen), `NovaNavAmap` (高德), `NovaAsrSherpa`,
  `NovaWakeIflytek`, `NovaAudio`, `NovaServices`, `NovaPlatform`. The app shell is `App/NovaDrive`. A gate script
  enforces the boundaries.

## How it is built (the engineering agent system)

The owner writes what the product should do; AI agents do the rest, and nothing counts as done without evidence.

```
 owner request ─▶ spec ─▶ work registry ─▶ build agent ─▶ gates ─▶ independent ─▶ cloud ─▶ phone test ─▶ records
                  specs/   specs/work.json  (Claude,       green?   reviewer      build    on the       and speed
                  features                  cloud or PC)            (read-only)   (Code-   owner's      sheet
                                                                                  magic)   iPhone
```

1. **Specs first.** Every feature has a file in `specs/features/` (about 40 features, F-01 to F-25 with sub-features):
   the owner's request, the evidence behind it, numbered rules and an acceptance table. Agents read only the section a
   task names (`scripts/spec_section.py`), which keeps cost down.
2. **A work registry.** `specs/work.json` lists every authorised task (258 so far, 210 passed). Only recorded work may
   be done. A stop hook keeps an agent going through the next ready task.
3. **Gates.** `scripts/gates/run_all.sh` runs the unit tests and static checks: import boundaries, no secrets, record
   format, agent-version hash, spec-to-test tracing, CI runner rules.
4. **Independent review.** A separate read-only reviewer agent (`.claude/agents/spec-reviewer.md`) checks the change
   against the spec at high effort. A task passes only with green gates and a PASS review; a review never overrides a
   failed gate.
5. **Build and install.** No Mac is needed: Codemagic builds the app in the cloud, and the IPA installs on the owner's
   iPhone from a Windows PC as an update that keeps data and keys (`.claude/skills/phone-test`).
6. **Proof on the phone.** Each conversation leaves a local record (with build sha and agent version). Records are
   pulled after a test, failures are traced to a cause, and reply speed (time to first sound) is tracked per build.
   Rows that need a real device stay NOT_VERIFIED until a phone run.

The workflow tooling comes from [ai-native-engineering](tools/ai-native/README.md) (executor plus end-state
reviewer). Results are logged in `specs/STATUS.md`.

## Getting the API keys (the main setup step)

小诺 talks to several online services, and each needs your own key. No key is built into the app. Open
设置 on the phone, paste each key into its row, and it is stored in the iPhone Keychain (write-only: the app never
shows it again, and keys never appear in logs). Start with the two **required** rows; add the others for the features
you want.

| Row in 设置 | Needed for | Where to get it | Notes |
|---|---|---|---|
| **Gemini API key** | **Required.** The voice conversation (Gemini Live) | [Google AI Studio](https://aistudio.google.com/apikey) → Create API key | Free tier available. Google blocks mainland China: the phone needs a VPN for Gemini |
| **高德 iOS SDK key** | **Required for the map and navigation** | [高德开放平台 console](https://console.amap.com/dev/key/app) → 应用管理 → 创建应用 → 添加 Key, platform **iOS SDK** | The Bundle ID you enter must match the installed app's bundle id exactly, or the map stays blank |
| 高德 Web 服务 key | Place search, routes and live info | Same console, add a second key with platform **Web服务** | Free daily quota for personal developers |
| 阿里云百炼 key | Web search, the Qwen voice model, trip planning | [阿里云百炼 console](https://bailian.console.aliyun.com/) → API-KEY | Use the **Beijing (华北2)** region. A key from the Singapore (international) site does not work with the Beijing services, and the reverse; this mismatch caused 出错 in testing |
| 和风天气 API Host + API KEY | Weather | [和风天气 console](https://console.qweather.com/) → 项目管理 → create a project and a credential | The API Host is personal to your account (设置 → 开发者信息); enter it without `https://` |
| 智谱 key（视觉，推荐） | Camera questions (「前面那是什么车？」) | [智谱开放平台](https://open.bigmodel.cn/usercenter/apikeys) → API keys | GLM-4.6V-Flash is free |
| Tavily key | Event and news search (`find_events`) | [Tavily](https://app.tavily.com/) → API keys | Optional; free monthly credits |
| 千帆 key（可选，视觉备用） | Backup for camera questions | [百度千帆 console](https://console.bce.baidu.com/qianfan/) | Optional |
| 讯飞 APPID + APIKey + APISecret | Wake word 「你好小诺」 | [讯飞开放平台](https://console.xfyun.cn/) → 创建应用 → AIKit 离线唤醒 | All three come from the same app page. Without them, tap the screen to talk |

Tips:
- Free quotas run out. When a feature suddenly says it cannot answer, check that service's console for quota or
  billing first.
- Keep each provider's keys in one region (all Beijing for 阿里云).
- Building the app yourself also needs a [Codemagic](https://codemagic.io/) account (cloud Mac build) and a free Apple
  ID to sign and install it on your iPhone; see `.claude/skills/phone-test/SKILL.md`.

## Setting up the features

On first launch, allow the microphone, location, camera and speech recognition when iOS asks; each feature needs its
permission. Everything else is in 设置.

| Feature | What to do | Good to know |
|---|---|---|
| **Music** | Nothing to sign up for. 设置 → 「音乐」 → 「曲库地区」 picks the catalogue: 香港 (default), 台湾, 日本, 美国 | 「放周杰伦的晴天」 plays a **30-second iTunes preview** inside the app, with a card and a 「在 Apple Music 中打开」 button for the full song. 「放首歌」 with no name plays a built-in track. The mainland China catalogue returns no results, so it is not offered |
| **Voiceprint lock (声纹锁定)** | 设置 → turn on 「声纹锁定」 and record your voice: park, close the windows, turn the music off, be the only one talking, and read the sentences shown in a normal voice | Only your voice can then talk to her or stop her. It is a convenience, not a security feature: it can be fooled |
| **Wake word 「你好小诺」** | Save the three 讯飞 rows (see the keys table), then 设置 → 「唤醒词」 on | Without it, tap the screen to talk |
| **Navigation mode** | 设置 → 「导航方式」: 「真实导航」 follows the car; 「模拟导航」 drives the route by itself | Use 模拟导航 to try guidance at a desk |
| **Location** | 设置 → 「位置来源」: the phone's real GPS, or 「演示位置」 for testing away from the car | 「我现在在哪？」 tells you which one is in use |
| **Noise filter and interrupting her** | Two switches in 设置: only a human voice opens the mic; and whether talking over her makes her stop and listen (otherwise only 「别说了」 stops her) | Navigation prompts are never cut off |
| **Air-con, seats, windows** | Nothing: these are simulated (「模拟车辆」 in 设置 shows their state) | No real car connection yet |

## Where to start

| You want to | Read |
|---|---|
| Understand the product | `specs/product-spec.md` |
| See every feature | `specs/features/README.md` |
| See the architecture | `specs/ios-architecture.md` |
| Know how agents must work here | `AGENTS.md`, `specs/ai-agent-workflow.md` |
| See what is done and what is next | `specs/STATUS.md`, `specs/work.json`, `specs/implementation-plan.md` |

## Device notes

- **Her voice.** Her voice is the voice model's own (设置 → 「她的声音」 → 「Gemini 原声（最快）」). The separate
  千问 TTS option is being removed (F-07 §18): its host is a Singapore workspace and does not work with a Beijing key.
- **VPN.** Gemini needs a VPN from mainland China; Qwen (Beijing) does not. With Clash in TUN mode, route
  `maas.aliyuncs.com` DIRECT (`DOMAIN-SUFFIX,maas.aliyuncs.com,DIRECT`): TUN mode catches the name lookup even when
  no proxy is set.

## License

Released under the [MIT License](LICENSE). You may use, copy, modify and publish this software, provided the
copyright notice and the license text are kept in every copy, so the source is always named.

本项目采用 [MIT 许可证](LICENSE)：可自由使用、复制、修改和发布，但所有副本须保留版权声明与许可证全文，以注明出处。
