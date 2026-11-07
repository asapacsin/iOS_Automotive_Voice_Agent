import Foundation
import NovaKit
import NovaPorts

/// F-07 §16 item 1 (T-020c): each reply's audio exactly as received from Gemini, before any playback processing,
/// as `<record>-turn<n>.wav` (24 kHz, 16-bit mono). Off by default (设置 → 开发 「保存她的原声」).
public struct ReplyAudioKeeper: Sendable {
    public static let settingKey = "keep_reply_audio"

    /// The record's base name (`yyyyMMdd-HHmmss`, no extension).
    public let record: String
    private var open: [TurnID: [Int16]] = [:]
    private var rate: [TurnID: Int] = [:]
    private var kept = 0

    public init(record: String) {
        self.record = record.hasSuffix(".txt") ? String(record.dropLast(4)) : record
    }

    /// Received audio of `turn`, in order.
    public mutating func add(_ turn: TurnID, _ pcm: PCMBuffer) {
        open[turn, default: []] += pcm.samples
        rate[turn] = pcm.sampleRate
    }

    /// The turn ended (generation complete, turn complete or interrupted): its file, once; nil when it had no audio.
    public mutating func finish(_ turn: TurnID) -> (name: String, wav: Data)? {
        guard let samples = open.removeValue(forKey: turn), !samples.isEmpty else { return nil }
        kept += 1
        let wav = WAVFile.encode(samples, sampleRate: rate.removeValue(forKey: turn) ?? PCMBuffer.replySampleRate)
        return ("\(record)-turn\(kept).wav", wav)
    }
}

/// A canonical 44-byte-header PCM WAV, 16-bit mono little-endian.
public enum WAVFile {
    public static let headerBytes = 44

    public static func encode(_ samples: [Int16], sampleRate: Int) -> Data {
        var d = Data(capacity: headerBytes + samples.count * 2)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
}
