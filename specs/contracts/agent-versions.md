# Agent setup versions (F-09b §15)

What shapes her behaviour (`AgentSetup`, `Packages/NovaCore/Sources/NovaAgent/Persona/AgentSetup.swift`): the model
id, the base instruction as sent for each session setting, every tool's name, description and schema, the `[系统]`
note templates, and the `Tuning` values marked `// agentSetup`. `agentSetupHash` is the first 12 hex characters of
SHA-256 over all of them; each record carries its session's `agentHash` (F-09b §15 item 6).

`AgentSetup.version` equals the newest row. Each version's parts are in `agent-setup-parts/<version>.json` (written
by `AgentSetupTests` with `AGENT_SETUP_WRITE=1`); `scripts/gates/check_agent_version.py` checks each bump against the
previous version's parts.

Bump rules (§15 item 4): **major** — a tool or a tool parameter added or removed, a whole part of the base
instruction rewritten, or the model id changed; **minor** — any other text change in the base instruction, a tool
description or a note template; **patch** — a marked `Tuning` value changed. The note names the rule.

| Version | agentSetupHash | Date | First commit | Note | Spec |
|---|---|---|---|---|---|
| 2.1.0 | 634b5f633ac5 | 2026-11-20 | (next commit) | minor: note templates: the `屏幕` line added; 现在 drops 正在导航/屏幕上显示着行程, the car note drops 音乐 (now screen keys) | F-09b §16 item 4 |
| 2.0.0 | dae929dc9ff0 | 2026-11-20 | bf39cfb | major: tool added (`show_place`); base 【你有什么】 打开地图或设置 → 打开地图、设置或地方卡片, 【怎么决定】 drops 地方介绍 from the no-tool rule | F-09b §16 item 8 |
| 1.0.0 | 6dbbd9c5d47e | 2026-11-20 | 2034d5d | first version: the setup after F-09b §14 stage B (four-part base instruction) | F-09b §14, §15 |
