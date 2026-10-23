import NovaKit
import NovaPorts

/// Per-frame automatic gain after echo cancellation (contracts/audio.md, `A/voice/MicInputGain.kt:23`):
/// up to ×3.0 towards a 12 000 peak, rising at most ×1.15 per frame, falling at once, never amplifying
/// frames whose peak is under the 250 noise floor, hard-limited to the PCM16 range.
public struct MicInputGain: Sendable {
    public private(set) var gain: Double = 1.0
    private let tuning: MicGainTuning

    public init(tuning: MicGainTuning = MicGainTuning()) {
        self.tuning = tuning
    }

    public mutating func process(_ frame: PCMFrame16k) -> PCMFrame16k {
        let peak = frame.samples.reduce(0) { max($0, abs(Int($1))) }
        if peak >= Int(tuning.noiseFloor) {
            let desired = min(tuning.maxGain, tuning.targetPeak / Double(peak))
            gain = desired < gain ? desired : min(desired, gain * tuning.riseFactor)
        }
        if gain == 1.0 { return frame }
        let scaled = frame.samples.map { sample -> Int16 in
            let value = (Double(sample) * gain).rounded()
            return Int16(clamping: Int(max(-32_768, min(32_767, value))))
        }
        return PCMFrame16k(samples: scaled)!
    }
}
