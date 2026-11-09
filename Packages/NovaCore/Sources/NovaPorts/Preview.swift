import Foundation

/// F-13 §17 item 5 (T-032e): why the current preview did not play (or stopped playing). Pure.
public enum PreviewFailure: Sendable, Hashable {
    /// No byte for 5 s (the idle request timeout).
    case downloadTimeout
    case downloadNetwork
    case downloadHTTP(Int)
    /// More than the 8 MB cap (§16 item 2).
    case tooLarge
    /// F-13 §18 item 2 (T-032f): more than the 40 s preview buffer; the preview ends at 40 s.
    case tooLong
    /// Neither streaming nor the whole-file decoder could read it.
    case parse
    /// The engine was not running, or the schedule was refused.
    case engine
    /// A newer preview, a stop or session end; never reported as a failure to the driver.
    case stopped

    /// The `stage=` code of the §17 item 6 lines.
    public var code: String {
        switch self {
        case .downloadTimeout: "download_timeout"
        case .downloadNetwork: "download_network"
        case .downloadHTTP(let status): "download_http_\(status)"
        case .tooLarge: "too_large"
        case .tooLong: "too_long"
        case .parse: "parse"
        case .engine: "engine"
        case .stopped: "stopped"
        }
    }
}

/// F-13 §17 item 2: whether a preview can be parsed as it arrives, from its top-level MP4 boxes. Pure.
public enum PreviewLayout: Sendable, Hashable {
    /// `moov` before `mdat`: AudioFileStream can parse it while it downloads.
    case streamable
    /// `mdat` before `moov` (or not an MP4 box sequence): kept in memory and decoded at the end.
    case wholeFile
    /// The prefix ends before the order is known.
    case needMore

    /// The `layout=` value of the start line.
    public var logName: String { self == .streamable ? "stream" : "whole" }

    public static func scan(_ prefix: Data) -> PreviewLayout {
        let bytes = [UInt8](prefix)
        var at = 0
        while true {
            guard at + 8 <= bytes.count else { return .needMore }
            let size32 = bytes[at..<at + 4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: bytes[at + 4..<at + 8], as: UTF8.self)
            // An M4A starts with `ftyp`; anything else is left to the whole-file decoder.
            if at == 0, type != "ftyp" { return .wholeFile }
            if type == "moov" { return .streamable }
            if type == "mdat" { return .wholeFile }
            // Box types are four printable ASCII characters; anything else is not an MP4 we can stream.
            guard bytes[at + 4..<at + 8].allSatisfy({ (0x20...0x7E).contains($0) }) else { return .wholeFile }
            let size: UInt64
            switch size32 {
            case 0: return .wholeFile   // the box runs to the end of the file: no moov ahead of the media.
            case 1:
                guard at + 16 <= bytes.count else { return .needMore }
                size = bytes[at + 8..<at + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard size >= 16 else { return .wholeFile }
            default:
                guard size32 >= 8 else { return .wholeFile }
                size = size32
            }
            guard size <= UInt64(Int.max - at) else { return .wholeFile }
            at += Int(size)
        }
    }
}

/// F-13 §17 item 1: when the preview node starts. Pure.
public enum PreviewStartRule {
    /// Seconds of audio scheduled before the node starts while the download continues.
    public static let startSeconds = 1.0
    /// Size of each scheduled piece.
    public static let pieceSeconds = 0.5

    public static func shouldStart(scheduledSeconds: Double, downloadEnded: Bool) -> Bool {
        downloadEnded || scheduledSeconds >= startSeconds - 1e-9
    }
}

/// F-13 §17 items 4, 6: what the player knows about the current preview, for the start and failed lines.
public struct PreviewProgress: Sendable, Hashable {
    /// From `play` to the first response byte.
    public var firstByteMs: Int?
    /// From `play` to the node start.
    public var startMs: Int?
    public var layout: PreviewLayout?
    public var bytes: Int
    public init(firstByteMs: Int? = nil, startMs: Int? = nil, layout: PreviewLayout? = nil, bytes: Int = 0) {
        self.firstByteMs = firstByteMs
        self.startMs = startMs
        self.layout = layout
        self.bytes = bytes
    }
}

/// F-13 §17 item 6: the preview lines for `RuntimeLog` and the record; numbers and codes only. Pure.
public enum PreviewLine {
    public static func start(firstByteMs: Int, startMs: Int, layout: PreviewLayout) -> String {
        "music preview start first_byte_ms=\(firstByteMs) start_ms=\(startMs) layout=\(layout.logName)"
    }

    public static func failed(_ failure: PreviewFailure, ms: Int, bytes: Int) -> String {
        "music preview failed stage=\(failure.code) ms=\(ms) bytes=\(bytes)"
    }

    public static func cut(_ failure: PreviewFailure, playedMs: Int) -> String {
        "music preview cut stage=\(failure.code) played_ms=\(playedMs)"
    }
}
