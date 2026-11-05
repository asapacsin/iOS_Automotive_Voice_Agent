/// F-04b §12 (T-013f): where the speaker model comes from — the bundle (Debug builds) or the Apple-hosted asset
/// pack downloaded at install (App Store / TestFlight). Pure: the app passes in what it found.
public enum SpeakerModelPin {
    /// §12 item 2: the asset pack id; a new model gets a new id.
    public static let assetPackID = "speaker-campplus-v1"
    public static let modelFile = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    /// Same value as `scripts/sherpa/models.sha256`.
    public static let sha256 = "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2"

    public static func matches(sha256 hex: String) -> Bool { hex.lowercased() == sha256 }
}

/// §12 item 4: what the system says about the downloaded pack.
public enum SpeakerPackState: Sendable, Hashable {
    /// Downloaded; `sha256` is the model file's hash, nil when the file is missing from the pack.
    case downloaded(sha256: String?)
    case downloading
    case failed
    /// iOS older than 26: no Apple-hosted asset packs.
    case unsupportedSystem
}

/// §12 items 3–4.
public enum SpeakerModelAvailability: Sendable, Hashable {
    case bundle
    case pack
    case downloading
    case failed
    case unsupportedSystem

    /// §12 item 3: the bundle first, then a pack whose checksum matches.
    public static func resolve(bundlePresent: Bool, pack: SpeakerPackState) -> SpeakerModelAvailability {
        if bundlePresent { return .bundle }
        switch pack {
        case .downloaded(let hash):
            guard let hash, SpeakerModelPin.matches(sha256: hash) else { return .failed }
            return .pack
        case .downloading: return .downloading
        case .failed: return .failed
        case .unsupportedSystem: return .unsupportedSystem
        }
    }

    public var usable: Bool { self == .bundle || self == .pack }

    /// §12 item 4: the line under 声纹锁定; nil when usable.
    public var note: String? {
        switch self {
        case .bundle, .pack: nil
        case .downloading: "声纹模型下载中"
        case .failed: "声纹模型下载失败"
        case .unsupportedSystem: "声纹锁定需要 iOS 26 或更新版本"
        }
    }

    /// §12 item 4: 重试 is offered only after a failure.
    public var canRetry: Bool { self == .failed }
}
