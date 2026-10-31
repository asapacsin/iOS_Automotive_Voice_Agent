import Foundation
import NovaVoice

/// F-08 §14 item 2: keyword-spotter constants, tuned on the device (barge-in-arbitration rows 4–6).
/// Indexed like `StopPhrases.all`. Higher threshold = fewer false hits; higher boost = easier to trigger.
public enum Tuning {
    /// Spotter-wide defaults (sherpa-onnx `keywords_threshold`, `keywords_score`).
    public static let defaultThreshold: Float = 0.25
    public static let defaultBoost: Float = 1.0
    /// Per phrase: 别说了, 不要说了, 别说啦, 停, 停一下, 闭嘴, 安静. The bare 停 is two tokens long, so it is stricter.
    public static let thresholds: [Float] = [0.25, 0.25, 0.25, 0.40, 0.30, 0.30, 0.30]
    public static let boosts: [Float] = [1.5, 1.5, 1.5, 1.0, 1.2, 1.2, 1.2]
    public static let maxActivePaths: Int32 = 4
    public static let numTrailingBlanks: Int32 = 1
    public static let numThreads: Int32 = 1

    /// Adds `:boost #threshold` to each `tokens @label` line whose label indexes the tables; other lines pass through.
    public static func tuned(_ keywords: String) -> String {
        keywords.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            guard let at = line.lastIndex(of: "@"),
                  let index = Int(line[line.index(after: at)...].trimmingCharacters(in: .whitespaces)),
                  thresholds.indices.contains(index), boosts.indices.contains(index) else { return String(line) }
            let tokens = line[..<at].trimmingCharacters(in: .whitespaces)
            return "\(tokens) :\(boosts[index]) #\(thresholds[index]) @\(index)"
        }.joined(separator: "\n") + "\n"
    }
}

enum KeywordLabel {
    /// sherpa-onnx reports a hit by the keyword's `@label`; ours is the `StopPhrases.all` index.
    static func phrase(_ keyword: String) -> Int? {
        let label = keyword.hasPrefix("@") ? String(keyword.dropFirst()) : keyword
        guard let index = Int(label.trimmingCharacters(in: .whitespaces)), StopPhrases.all.indices.contains(index) else {
            return nil
        }
        return index
    }
}
