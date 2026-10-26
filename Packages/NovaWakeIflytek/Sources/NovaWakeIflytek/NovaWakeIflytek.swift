// The iFlytek wake word moved to AIKit (T-060), whose frameworks are device-only binaries and cannot be
// linked from a Swift package that also builds for the simulator. The engine is
// App/NovaDrive/Wake/AIKitWakeEngine.swift behind NovaVoice's `RetryingWakeDetector`.
import NovaPorts

public enum NovaWakeIflytekModule {}
