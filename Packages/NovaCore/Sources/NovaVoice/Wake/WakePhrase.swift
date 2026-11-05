import Foundation
import NovaPorts

/// F-01 §14 item 5 (T-060a): which wake engine the app uses. One constant selects it; iFlytek AIKit stays in the
/// app, unused, until the owner decides from the device rows (wake-word §14 rows 9–12).
public enum WakeEngineKind: String, Sendable, Hashable, CaseIterable {
    /// The bundled sherpa-onnx keyword spotter (`SherpaWakeEngine`): no account, no key.
    case sherpa
    /// iFlytek AIKit (`AIKitWakeEngine`): needs the three 讯飞 values in 设置.
    case iflytek

    /// The one switch (§14 item 5).
    public static let selected: WakeEngineKind = .sherpa

    public static let iflytekKeys: [CredentialKey] = [.iflytekAppID, .iflytekAPIKey, .iflytekAPISecret]

    /// Only iFlytek needs saved values before it can listen.
    public var needsKeys: Bool { self == .iflytek }

    /// 设置 does not show the fields of an engine that needs none (with sherpa: the three 讯飞 fields).
    public var hiddenKeys: Set<CredentialKey> { needsKeys ? [] : Set(Self.iflytekKeys) }
}

/// F-01 §14 item 2 (T-060a): the fixed wake phrase, as sherpa-onnx Mandarin KWS tokens. Two lines because 你好 is
/// usually said ní hǎo; both report one wake. `scripts/gates/check_kws_tokens.py` checks every token against the
/// bundled model's token list. Changing it is a spec change.
public enum WakePhrase {
    public typealias Phrase = StopPhrases.Phrase

    public static let text = "你好小诺"

    public static let forms: [Phrase] = [
        Phrase(text: "你好小诺", tokens: ["n", "ǐ", "h", "ǎo", "x", "iǎo", "n", "uò"]),
        Phrase(text: "你好小诺", tokens: ["n", "í", "h", "ǎo", "x", "iǎo", "n", "uò"]),
    ]

    /// The keyword label prefix; a hit reports `wake<form index>`.
    static let labelPrefix = "wake"

    /// The sherpa-onnx keywords file: `tokens :boost #threshold @wake<index>` per form.
    public static func keywordsFile(boost: Float, threshold: Float) -> String {
        forms.enumerated().map { "\($0.element.tokens.joined(separator: " ")) :\(boost) #\(threshold) @\(labelPrefix)\($0.offset)" }
            .joined(separator: "\n") + "\n"
    }

    /// The form a spotter hit names (`wake1` or `@wake1`), or nil for any other keyword.
    public static func form(ofKeyword keyword: String) -> Int? {
        var label = Substring(keyword.trimmingCharacters(in: .whitespaces))
        if label.hasPrefix("@") { label = label.dropFirst() }
        guard label.hasPrefix(labelPrefix), let index = Int(label.dropFirst(labelPrefix.count)),
              forms.indices.contains(index) else { return nil }
        return index
    }

    /// §14 item 8: the idle screen's line while the listener is armed.
    public static let hint = "说“你好小诺”唤醒"

    /// Shown only while armed and no session runs; not when wake is unavailable or off (never armed then).
    public static func hint(armed: Bool, sessionRunning: Bool) -> String? {
        armed && !sessionRunning ? hint : nil
    }
}

/// §14 item 2: the two forms of one spoken 你好小诺 report one wake. After a hit, further hits within
/// `refractoryFrames` of audio are dropped (the spotter can match the other tone form on the same words).
public struct WakeHitFilter: Sendable {
    /// 1.5 s of 10 ms frames.
    public static let refractoryFrames = 150

    private var frames = 0
    private var lastHit: Int?

    public init() {}

    /// One frame went to the spotter.
    public mutating func frame() { frames += 1 }

    /// A spotter hit with its keyword label: true when it counts as a wake.
    public mutating func hit(_ keyword: String) -> Bool {
        guard WakePhrase.form(ofKeyword: keyword) != nil else { return false }
        if let lastHit, frames - lastHit < Self.refractoryFrames { return false }
        lastHit = frames
        return true
    }
}

