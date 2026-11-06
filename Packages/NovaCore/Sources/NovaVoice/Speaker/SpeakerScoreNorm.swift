import Foundation
import NovaPorts

/// F-04b §16 item 1.3 (T-013j): `speaker_cohort.json`, as `scripts/speaker_cohort.py` writes it. Extra keys are ignored.
public struct SpeakerCohortMeta: Codable, Sendable, Hashable {
    public var source: String
    public var license: String
    public var model: String
    public var modelSha256: String
    public var speakers: Int
    public var dimension: Int
    public var topN: Int
    /// The EER threshold on the CN-Celeb1 test trials (§16 item 3). Nothing on the phone changes it.
    public var threshold: Double
    public var eer: Double
    public var trials: Int

    public init(source: String, license: String, model: String, modelSha256: String, speakers: Int, dimension: Int,
                topN: Int, threshold: Double, eer: Double, trials: Int) {
        self.source = source
        self.license = license
        self.model = model
        self.modelSha256 = modelSha256
        self.speakers = speakers
        self.dimension = dimension
        self.topN = topN
        self.threshold = threshold
        self.eer = eer
        self.trials = trials
    }

    /// §16 item 6: the cohort was made with the loaded model.
    public func matches(modelSha256 sha: String) -> Bool { modelSha256.lowercased() == sha.lowercased() }
}

/// §16 items 1.1, 1.3: one averaged, L2-normalized embedding per CN-Celeb1 dev speaker, and its metadata.
public struct SpeakerCohort: Sendable, Hashable {
    public static let vectorsFile = "speaker_cohort.f32"
    public static let metaFile = "speaker_cohort.json"

    public let meta: SpeakerCohortMeta
    /// speakers × dimension.
    public let vectors: [[Float]]

    public init?(meta: SpeakerCohortMeta, vectors: [[Float]]) {
        guard meta.speakers > 0, meta.dimension > 0, meta.topN > 0, meta.threshold.isFinite,
              vectors.count == meta.speakers, vectors.allSatisfy({ $0.count == meta.dimension }) else { return nil }
        self.meta = meta
        self.vectors = vectors
    }

    /// Reads both files through the port; nil when either is missing, unreadable or inconsistent
    /// (「声纹对比数据缺失」, the lock fails closed).
    public static func load(from files: any SpeakerCohortFiles) -> SpeakerCohort? {
        guard let json = files.read(metaFile), let raw = files.read(vectorsFile),
              let meta = try? JSONDecoder().decode(SpeakerCohortMeta.self, from: json),
              meta.speakers > 0, meta.dimension > 0,
              raw.count == meta.speakers * meta.dimension * 4 else { return nil }
        // float32 little-endian, row-major.
        let bytes = [UInt8](raw)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(meta.speakers)
        for s in 0..<meta.speakers {
            var row = [Float](repeating: 0, count: meta.dimension)
            for d in 0..<meta.dimension {
                let o = (s * meta.dimension + d) * 4
                let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16
                    | UInt32(bytes[o + 3]) << 24
                row[d] = Float(bitPattern: bits)
            }
            vectors.append(row)
        }
        return SpeakerCohort(meta: meta, vectors: vectors)
    }
}

/// The cohort files in one directory (the app passes the bundle path).
public struct DirectorySpeakerCohortFiles: SpeakerCohortFiles {
    public let directory: URL?

    public init(directory: URL?) { self.directory = directory }

    public func read(_ name: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }
}

/// F-04b §16 item 2 (T-013j): AS-norm. With e, t and the cohort C all L2-normalized, s = cos(e, t); the `topN` largest
/// cos(e, c) over C give μe and σe, the same for t gives μt and σt; score = ½·((s − μe)/σe + (s − μt)/σt). The
/// standard deviation divides by n. Same math as `scripts/speaker_cohort.py` `as_norm` (row 52). Pure.
public struct SpeakerScoreNorm: Sendable, Hashable {
    /// One side's cohort statistics; the enrollment side is computed once per profile load and cached.
    public struct Side: Sendable, Hashable {
        public let unit: [Double]
        public let mean: Double
        public let std: Double
    }

    public let topN: Int
    private let cohort: [[Double]]

    /// nil for an empty cohort, rows of different lengths, a zero row or `topN` < 1.
    public init?(cohort: [[Float]], topN: Int) {
        guard topN > 0, let n = cohort.first?.count, n > 0 else { return nil }
        var rows: [[Double]] = []
        for c in cohort {
            guard c.count == n, let u = Self.unit(c) else { return nil }
            rows.append(u)
        }
        self.topN = topN
        self.cohort = rows
    }

    public var size: Int { cohort.count }

    static func unit(_ v: [Float]) -> [Double]? {
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { Double($0) / norm }
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }

    /// nil when the length differs from the cohort's, the vector is zero, or the top cosines have no spread.
    public func side(_ v: [Float]) -> Side? {
        guard v.count == cohort.first?.count, let u = Self.unit(v) else { return nil }
        let k = min(topN, cohort.count)
        let top = cohort.map { Self.dot(u, $0) }.sorted(by: >).prefix(k)
        let mean = top.reduce(0, +) / Double(k)
        let std = (top.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(k)).squareRoot()
        guard std > 0, std.isFinite else { return nil }
        return Side(unit: u, mean: mean, std: std)
    }

    /// `raw` is s = cos(e, t); `norm` the AS-norm score. nil when the test side cannot be computed.
    public func score(enrolled e: Side, test: [Float]) -> (raw: Double, norm: Double)? {
        guard let t = side(test), t.unit.count == e.unit.count else { return nil }
        let s = Self.dot(e.unit, t.unit)
        return (s, 0.5 * ((s - e.mean) / e.std + (s - t.mean) / t.std))
    }
}

/// §16 items 2–3, 5: one profile load scored against the cohort, for speech, the wake word and stop phrases alike.
/// The enrollment side is computed here once and reused for every check until the profile is loaded again. Pure.
public struct SpeakerCohortScorer: Sendable, Hashable {
    public let norm: SpeakerScoreNorm
    public let enrolled: SpeakerScoreNorm.Side
    /// §16 item 3: the cohort file's threshold.
    public let threshold: Double
    public let cohortSize: Int

    public init?(embedding: [Float], cohort: SpeakerCohort) {
        guard let norm = SpeakerScoreNorm(cohort: cohort.vectors, topN: cohort.meta.topN),
              let enrolled = norm.side(embedding) else { return nil }
        self.norm = norm
        self.enrolled = enrolled
        threshold = cohort.meta.threshold
        cohortSize = cohort.vectors.count
    }

    /// The outcome the holds take: the normalized score, with the raw cosine and cohort size for the record line.
    public func outcome(_ test: [Float], scoreMs: Int) -> SpeakerScoreOutcome {
        guard let s = norm.score(enrolled: enrolled, test: test) else { return .failed(scoreMs: scoreMs) }
        return .score(s.norm, scoreMs: scoreMs, raw: s.raw, cohort: cohortSize)
    }
}
