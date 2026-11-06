import NovaKit

/// F-04b §6 item 1 (T-013e): speaker verification on the phone. Frames in, an embedding out; the score is the cosine
/// against the enrolled embedding (`SpeakerScore`). The adapter is `SherpaSpeakerVerifier` in NovaAsrSherpa; no
/// Gemini code knows about it. Nothing it computes leaves the phone (§4 item 7). A target-speaker extractor, if one is
/// ever added, is a stage before this port.
public protocol SpeakerVerifier: Sendable {
    /// The model's name, stored in the profile; a profile of another model is invalid (§4 item 6).
    var modelName: String { get }
    /// The embedding length; 0 when the model did not load.
    var dimension: Int { get }
    /// Runs on the caller's (background) queue, never the capture thread. Throws when the model cannot load or the
    /// audio is too short to embed.
    func embedding(of frames: [PCMFrame16k]) throws -> [Float]
}

public enum SpeakerScore {
    /// Cosine similarity, -1...1; nil when the lengths differ or a vector is zero.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Unit-length average of `vectors` (all the same length); nil when empty or mismatched.
    public static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let n = vectors.first?.count, n > 0, vectors.allSatisfy({ $0.count == n }) else { return nil }
        var sum = [Double](repeating: 0, count: n)
        for v in vectors {
            let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm > 0 else { return nil }
            for i in 0..<n { sum[i] += Double(v[i]) / norm }
        }
        let norm = sum.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return sum.map { Float($0 / norm) }
    }
}
