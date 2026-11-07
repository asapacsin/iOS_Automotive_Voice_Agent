# iOS_Automotive_Voice_Agent
iOS version of Nova Drive — AI voice assistant with navigation, speech interaction, and deterministic command execution.

## Device notes
- **Her voice (F-07 §15).** 设置 → 她的声音 defaults to 「Gemini 原声（最快）」: her voice is the live session's own
  voice and needs no other key. 千问 and Azure stay as options and need their key (and 千问 its API Host).
- **Her voice (千问, F-07 §14 item 9).** The owner's Qwen-Audio TTS host is in Singapore
  (`*.ap-southeast-1.maas.aliyuncs.com`). With a VPN or Clash on, route `maas.aliyuncs.com` DIRECT
  (`DOMAIN-SUFFIX,maas.aliyuncs.com,DIRECT`): Clash's TUN mode catches the name lookup even when no proxy is set.
