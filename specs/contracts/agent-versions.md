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
| 7.1.0 | 3035998f8bb2 | 2026-11-23 | (T-031zd) | minor: tool `show_on_map` added; `navigate_to` adds 「司机只是想看在哪里，用 show_on_map。」; `exit_navigation_mode` panel enum and the 屏幕 line gain `mapPin` | F-09b §19 items 1, 5 |
| 7.0.0 | 1142703f8837 | 2026-11-23 | 3caebbb | major: tool parameter added (`show_place.city`, required, empty for near the car); `show_place` description adds 「city 填这个地方所在的城市；不确定在哪个城市时先用 web_search 查。」 | F-09b §18 item 1 |
| 6.4.0 | fbd9b3bed999 | 2026-11-23 | f2e344c | minor: the 屏幕 line gains `backgroundWork` after `working` | F-04 §15 item 4 |
| 6.3.0 | 4f2a41928ff2 | 2026-11-23 | 1b20209 | minor: corrections `CLAIM_AFTER_FAILURE tool=set_trip_plan` (「[系统] 行程没有改成，原因在上一个工具结果的 problems 里。…」) and `UNVERIFIED_CLAIM tool=set_trip_plan` added; `set_trip_plan` text ends 「结果稍后回来。新行程：…改行程：先只说一句：好，我在改行程，好了告诉你。然后不要说话，等结果。」 | F-15b §58 items 2–4 |
| 6.2.0 | 327fab322a68 | 2026-11-23 | 7da5691 | minor: `set_trip_plan` 改行程 sentence becomes 「改行程：把结果里的行程照着改，已有的地点保留 id（其他字段可以照抄），新地点写 name。」, stop schema `minutes` 0–720 and other stop keys no longer refused (T-040zi, first written as 6.1.0 in 19d8874 before the F-18 6.1.0 merge); the 屏幕 line gains `tripNextButton` and `stopNavigationButton` after `navigation`; notes 「[系统] 司机点了「去下一站」。这句不用回答。」 and 「[系统] 司机点了「结束导航」。这句不用回答。」 added, the 去下一站 screen-edit note removed (T-040zj) | F-15b §56 items 1, 5; §57 items 4–5 |
| 6.1.0 | cbe8c8a2337c | 2026-11-23 | 8f7cee0 | minor: note template: correction `NETWORK_BLAMED` (网络没有问题，只是现在查不了网上的信息) | F-18 §33 item 7 |
| 6.0.0 | ecb264516eb6 | 2026-11-22 | 4fb5041 | major: tools removed (`make_trip_list`, `edit_trip_list`); `set_trip_plan` parameters added (`city`, stop `near`) and its description replaced by §55 item 12 (makes and changes every plan); correction `TRIP_NEEDS_FIX` added | F-15b §55 items 11–13 |
| 5.3.0 | 1a35a7e234a1 | 2026-11-21 | 3568631 | minor: `make_trip_list` adds 「司机说去一个新地方、规划新的行程…就用这个，不要用 set_trip_plan 改旧行程。」; `set_trip_plan` adds 「只用来改屏幕上这份行程…用 make_trip_list。」 | F-15b §54 items 1-2 |
| 5.2.0 | a0b02067b451 | 2026-11-21 | 05d63c4 | minor: `make_trip_list` description: a multi-day plan is a pool (`places` + `day_count`, 8-place 广州 example with minutes and importance); `days` only when the driver said which day | F-15b §53 item 2 |
| 5.1.0 | 06e741b9b470 | 2026-11-21 | b2af6eb | minor: note template: correction `TRIP_RESULT_PENDING` (结果还没回来，不要说已经做好) | F-15b §52 item 12 |
| 5.0.0 | 4ff565488e05 | 2026-11-21 | b4588d5 | major: tool added (`set_trip_plan`), tool removed (`revise_trip_list`), `edit_trip_list` parameters removed (`to_index`, `start`, `days`, `to_day`; actions add/remove/move/reorganize gone); edit and make descriptions point to set_trip_plan; edit adds CONFIRM_CLEAR | F-15b §52 items 3, 13, 14 |
| 4.0.0 | e06a5c030dab | 2026-11-20 | 14fa121 | major: tool parameter added (`exit_navigation_mode.panel`, optional enum); exit description adds the named-panel sentence | F-09b §17 item 4 |
| 3.1.0 | 0ceb4606f71a | 2026-11-20 | ee866b2 | minor: note template: the `屏幕` line gains `；top <panel\|none>` at the end | F-09b §17 item 5 |
| 3.0.0 | 9e127cecdf02 | 2026-11-20 | ba58dac | major: tool added (`show_places`, with search on); base web_search sentence adds 司机想找能做什么、去哪玩的地方：先 web_search 找，再 show_places 给他看，他说要去才导航。 (maxBaseCharacters 1022 → 1079) | F-16 §15 items 2, 5 |
| 2.2.0 | 35529b4982fe | 2026-11-20 | c0957a1 | minor: base 【你有什么】 adds 屏幕状态就是司机眼前看到的；"这个"指屏幕上开着的东西。 (maxBaseCharacters 994 → 1022) | F-09b §16 item 5 |
| 2.1.0 | 634b5f633ac5 | 2026-11-20 | bff0cfb | minor: note templates: the `屏幕` line added; 现在 drops 正在导航/屏幕上显示着行程, the car note drops 音乐 (now screen keys) | F-09b §16 item 4 |
| 2.0.0 | dae929dc9ff0 | 2026-11-20 | bf39cfb | major: tool added (`show_place`); base 【你有什么】 打开地图或设置 → 打开地图、设置或地方卡片, 【怎么决定】 drops 地方介绍 from the no-tool rule | F-09b §16 item 8 |
| 1.0.0 | 6dbbd9c5d47e | 2026-11-20 | 2034d5d | first version: the setup after F-09b §14 stage B (four-part base instruction) | F-09b §14, §15 |
