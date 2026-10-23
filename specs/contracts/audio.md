# Contract: audio (v1, 2026-10-22)

| Item | Value | Source |
|---|---|---|
| Capture format | 16 kHz, mono, PCM16 little-endian | `A/voice/PcmAudioCapture.kt:278` |
| Frame | 10 ms = 320 bytes | `I/AudioFrameTiming.kt:8-9` |
| Capture source | voice-communication (platform AEC + NS enabled if available) | `PcmAudioCapture.kt:71,100-110` |
| Software AEC | WebRTC AEC3 (JNI), render fed right before playback write; render 16 or 24 kHz; delay from capture timestamps | `A/voice/WebRtcAcousticEcho.kt` |
| Gain | max 3.0, target peak 12 000, noise floor 250, rise ×1.15, instant fall, hard limit | `A/voice/MicInputGain.kt:23` |
| Uplink to Gemini | `audio/pcm;rate=16000` | `GeminiLiveProtocol.kt` |
| Reply audio | 24 kHz mono PCM16 (Gemini and Azure `raw-24khz-16bit-mono-pcm`) | `RealtimeProviderFactory.kt:29`, `AzureSpeechVoice.kt:70` |
| Playback usage | assistant / speech; transient focus gain; duck/pause/stop/resume actions | `AudioFocusController.kt:24-51` |
| Playback epochs | `flush(epoch)`, `beginReply`, `complete`; stale-epoch audio discarded | `PcmAudioPlayer.kt` |
| Guidance lane | separate playout lane for relayed guidance | `PcmAudioPlayer.kt:684-767` |
| Low-latency buffer | max 5 increases, shrink after 10 ticks | `LowLatencyPlaybackBuffer` |

## Ordering rules

1. Echo reference must be the exact samples played, fed before the hardware write.
2. Capture is cleaned (AEC) **before** gain and before the uplink gate.
3. On barge-in, flush playback first, then notify the provider.
4. The microphone is shared: while idle the wake detector owns capture; when a session starts the
   session owns it (ADR-006: one capture stream shared). There must never be two concurrent captures.

## iOS mapping (PROPOSED, see ios-feasibility.md)

`AVAudioSession` category `.playAndRecord`, mode `.voiceChat` (built-in voice processing: AEC, AGC,
NS) via `AVAudioEngine` input node `setVoiceProcessingEnabled(true)`; resample hardware rate to 16 kHz
with `AVAudioConverter`; play 24 kHz PCM through `AVAudioPlayerNode` on the same engine so the
voice-processing unit sees the render reference. Whether Apple voice processing alone is good enough
(vs. porting WebRTC AEC3) is **DEVICE_SPIKE**: the API is documented, its quality is not; measure on an iPhone (OQ-IOS-3).
