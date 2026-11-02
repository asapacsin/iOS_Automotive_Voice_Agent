import Foundation
import NovaKit
import NovaPorts

/// F-08 §17 tuning (T-022d). Log-only for now: nothing here changes what is sent or played.
public struct BargeInCheckTuning: Sendable, Hashable {
    /// No candidate counts this soon after the audio engine started or restarted.
    public var settleWindow = NovaDuration.seconds(3)
    public var minSpeechProbability = 0.7
    public var minSpeech = NovaDuration.milliseconds(300)
    /// After `minSpeech` passed, words must show up within this (or in the final).
    public var wordDeadline = NovaDuration.seconds(1)
    public var minNewSyllables = 2
    /// The driver bar: median peak of recent sent utterances with words, minus this, clamped.
    public var levelMargin = 10
    public var barRange = 70...80
    public var defaultBar = 72
    public var barHistory = 10
    public var barMinimumSamples = 3
    /// Her words are remembered this long, and forgotten this long after her turn ends.
    public var echoWindow = NovaDuration.seconds(10)
    public init() {}
}

/// F-08 §17 item 3: why a candidate (an utterance starting while her reply plays) would not stop her.
public enum BargeInReason: String, Sendable, Hashable {
    case settling, notSpeech, lowLevel, tooShort, stopPhrase, noWords, echoWords, wouldStop
}

/// F-08 §17 item 3: the pure check. Stages in order; the first failure is the reason.
public enum BargeInCheck {
    public struct Candidate: Sendable {
        /// Time from the engine's (re)start to the candidate's start.
        public var sinceEngineStart: NovaDuration
        /// Highest classifier speech probability during the candidate; nil when there was none.
        public var classifierMax: Double?
        public var peakDb: Int
        public var barDb: Int
        public var duration: NovaDuration
        /// Local ASR partials: time since the candidate started, and the text.
        public var partials: [(at: NovaDuration, text: String)]
        public var final: String?
        /// Her recent words as toneless syllables.
        public var herSyllables: Set<String>
        /// Syllables of the newest words (final, else latest partial with words), when already computed.
        public var wordSyllables: [String]?

        public init(sinceEngineStart: NovaDuration, classifierMax: Double?, peakDb: Int, barDb: Int,
                    duration: NovaDuration, partials: [(at: NovaDuration, text: String)] = [], final: String? = nil,
                    herSyllables: Set<String> = [], wordSyllables: [String]? = nil) {
            self.sinceEngineStart = sinceEngineStart
            self.classifierMax = classifierMax
            self.peakDb = peakDb
            self.barDb = barDb
            self.duration = duration
            self.partials = partials
            self.final = final
            self.herSyllables = herSyllables
            self.wordSyllables = wordSyllables
        }
    }

    public struct Verdict: Sendable, Hashable {
        public var reason: BargeInReason
        /// From the candidate's start to its first partial with words; nil when none.
        public var firstWordMs: Int64?
        public var newSyllables: Int
        public var totalSyllables: Int
    }

    public static func judge(_ c: Candidate, tuning t: BargeInCheckTuning = BargeInCheckTuning()) -> Verdict {
        let wordPartial = c.partials.first { PostStopHold.hasWords($0.text, partial: true) }
        var v = Verdict(reason: .wouldStop, firstWordMs: wordPartial?.at.milliseconds, newSyllables: 0, totalSyllables: 0)
        func fail(_ r: BargeInReason) -> Verdict { v.reason = r; return v }
        if c.sinceEngineStart < t.settleWindow { return fail(.settling) }
        guard let p = c.classifierMax, p >= t.minSpeechProbability else { return fail(.notSpeech) }
        if c.peakDb < c.barDb { return fail(.lowLevel) }
        if c.duration < t.minSpeech { return fail(.tooShort) }
        let text = c.final ?? c.partials.last?.text ?? ""
        if ListeningIntent.classify(text) == .shutUp || c.partials.contains(where: { ListeningIntent.classify($0.text) == .shutUp }) {
            return fail(.stopPhrase)
        }
        let inTime = wordPartial.map { $0.at <= t.minSpeech + t.wordDeadline } ?? false
        let finalWords = c.final.map { PostStopHold.hasWords($0, partial: false) } ?? false
        if !inTime && !finalWords { return fail(.noWords) }
        // The words so far: the final, else the newest partial with words (partials grow), never the first one.
        let latest = c.partials.last { PostStopHold.hasWords($0.text, partial: true) }?.text
        let words = finalWords ? c.final! : (latest ?? text)
        let mine = Set(c.wordSyllables ?? syllables(words))
        let (new, total) = (mine.subtracting(c.herSyllables).count, mine.count)
        v.newSyllables = new
        v.totalSyllables = total
        if !isNew(new: new, total: total, tuning: t) { return fail(.echoWords) }
        return v
    }

    /// Item 3 `echoWords`: at least `minNewSyllables` distinct syllables not in her words, and at least half.
    public static func isNew(new: Int, total: Int, tuning t: BargeInCheckTuning = BargeInCheckTuning()) -> Bool {
        new >= t.minNewSyllables && new * 2 >= total
    }

    /// Distinct syllables of `text` not in `her`, and all distinct syllables.
    public static func newSyllables(_ text: String, her: Set<String>) -> (new: Int, total: Int) {
        let mine = Set(syllables(text))
        return (mine.subtracting(her).count, mine.count)
    }

    /// Item 5: toneless pinyin syllables (Latin words kept lowercased), so a misheard form with a similar sound matches.
    public static func syllables(_ text: String) -> [String] {
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        return latin.lowercased().split { !$0.isLetter }.map(String.init)
    }

    /// Item 4: the median of the last peaks (newest last) minus the margin, clamped; the default with too few.
    public static func driverBar(_ peaks: [Int], tuning t: BargeInCheckTuning = BargeInCheckTuning()) -> Int {
        let recent = peaks.suffix(t.barHistory).sorted()
        guard recent.count >= t.barMinimumSamples else { return t.defaultBar }
        let mid = recent.count / 2
        let median = recent.count.isMultiple(of: 2) ? (recent[mid - 1] + recent[mid]) / 2 : recent[mid]
        return min(max(median - t.levelMargin, t.barRange.lowerBound), t.barRange.upperBound)
    }
}

/// F-08 §17 items 3–6: watches the gate's raw outputs and the local words and logs what `BargeInCheck` would do.
/// Never changes an output (log-only). Time moves 10 ms per frame; utterances are numbered like the recognizer's.
/// Logs are numbers and enums only (I-8); her words stay in memory as syllables.
public struct BargeInShadow: Sendable {
    private struct Open: Sendable {
        var id: Int
        var start: NovaDuration
        var sinceEngine: NovaDuration
        var candidate: Bool
        var peakDb = 0
        var classifierMax: Double?
        var partials: [(at: NovaDuration, text: String)] = []
        var closedAt: NovaDuration?
        var final: String?
        var wordSyllables: [String]?
        var announced = false
    }

    private let tuning: BargeInCheckTuning
    private var now = NovaDuration.zero
    private var engineStart = NovaDuration.zero
    private var utterance = 0
    private var open: Open?
    /// Candidates closed by the gate whose final is still awaited.
    private var waiting: [Open] = []
    /// Sent, unmuted utterances closed but not yet known to have words: id → peak.
    private var unconfirmed: [Int: Int] = [:]
    private var peaks: [Int] = []
    private var her: [(at: NovaDuration, syllables: [String])] = []
    private var herTurnEnded: NovaDuration?
    private var logs: [String] = []

    /// How long a closed candidate waits for its final before it is judged without one.
    static let finalWait = NovaDuration.seconds(2)

    public init(tuning: BargeInCheckTuning = BargeInCheckTuning()) { self.tuning = tuning }

    public var barDb: Int { BargeInCheck.driverBar(peaks, tuning: tuning) }

    public mutating func takeLogs() -> [String] {
        defer { logs.removeAll(keepingCapacity: true) }
        return logs
    }

    /// The audio engine started or restarted (item 3 `settling`).
    public mutating func engineStarted() { engineStart = now }

    /// Her output transcription arrived, as syllables (computed by the caller outside any lock). Kept while she
    /// talks, since text can arrive well before its audio plays.
    public mutating func herWords(syllables: [String]) {
        her.append((now, syllables))
        herTurnEnded = nil
    }

    public mutating func herWords(_ text: String) { herWords(syllables: BargeInCheck.syllables(text)) }

    /// Her reply finished playing; her words are forgotten `echoWindow` later.
    public mutating func herTurnEnd() { herTurnEnded = now }

    private var herSyllables: Set<String> { Set(her.flatMap(\.syllables)) }

    /// One frame: the gate's outputs for it (raw, before the hold), the frame's level, the classifier's latest
    /// probability, and the gate's mute reason after it.
    public mutating func frame(_ outputs: [UplinkGateOutput], frame: PCMFrame16k, speechProbability: Double?,
                               muteReason: MuteReason) {
        self.frame(outputs, peakDb: SpeechUplinkGate.decibels(SpeechUplinkGate.rms(frame)), speechProbability: speechProbability,
              muteReason: muteReason)
    }

    /// The same with the frame's level given (tests).
    public mutating func frame(_ outputs: [UplinkGateOutput], peakDb: Int, speechProbability: Double?, muteReason: MuteReason) {
        now = now + .milliseconds(10)
        forget()
        observe(outputs, muteReason: muteReason)
        if var o = open, o.closedAt == nil {
            o.peakDb = max(o.peakDb, peakDb)
            if let p = speechProbability { o.classifierMax = max(o.classifierMax ?? 0, p) }
            open = o
            if o.candidate, !o.announced, o.partials.contains(where: { PostStopHold.hasWords($0.text, partial: true) }) {
                announceIfDecided()
            }
        }
        // A candidate whose final never comes is judged a final-wait after its close.
        while let first = waiting.first, let closed = first.closedAt, now - closed >= Self.finalWait {
            waiting.removeFirst()
            conclude(first)
        }
    }

    /// Outputs that come from no frame (the force-close).
    public mutating func observe(_ outputs: [UplinkGateOutput], muteReason: MuteReason) {
        for output in outputs {
            switch output {
            case .speechStarted:
                utterance += 1
                // Item 3: only while her reply plays; guidance and the echo tail never count.
                open = Open(id: utterance, start: now, sinceEngine: now - engineStart, candidate: muteReason == .reply)
            case .utterance(let record):
                guard var o = open else { break }
                o.closedAt = now
                o.peakDb = record.peakDb  // the logged peak matches the utterance line
                open = nil
                if o.candidate {
                    if o.final != nil { conclude(o) } else { waiting.append(o) }
                } else if record.muteReason == .none {
                    logs.append("levelCheck \(o.id) peakDb=\(record.peakDb) barDb=\(barDb) below=\(record.peakDb < barDb)")
                    if record.sentToModel { unconfirmed[o.id] = record.peakDb }
                    if o.final.map({ PostStopHold.hasWords($0, partial: false) }) == true
                        || o.partials.contains(where: { PostStopHold.hasWords($0.text, partial: true) }) {
                        confirmLevel(o.id)
                    }
                }
            default: break
            }
        }
    }

    /// `syllables`: of `text`, computed by the caller outside any lock (nil: computed here).
    public mutating func partial(_ text: String, syllables: [String]? = nil, utterance id: Int) {
        let words = PostStopHold.hasWords(text, partial: true)
        if var o = open, o.id == id {
            o.partials.append((now - o.start, text))
            if words { o.wordSyllables = syllables }
            open = o
            if o.candidate, !o.announced, words { announceIfDecided() }
        } else if let i = waiting.firstIndex(where: { $0.id == id }) {
            waiting[i].partials.append((now - waiting[i].start, text))
            if words, waiting[i].final == nil { waiting[i].wordSyllables = syllables }
        }
        if words { confirmLevel(id) }
    }

    public mutating func final(_ text: String, syllables: [String]? = nil, utterance id: Int) {
        let words = PostStopHold.hasWords(text, partial: false)
        if words { confirmLevel(id) }
        if var o = open, o.id == id {
            o.final = text
            if words { o.wordSyllables = syllables }
            open = o
            if o.candidate, !o.announced { announceIfDecided() }
        } else if let i = waiting.firstIndex(where: { $0.id == id }) {
            var o = waiting.remove(at: i)
            o.final = text
            if words { o.wordSyllables = syllables }
            conclude(o)
        }
    }

    /// Item 6: `wouldStopAt` once, when the open candidate first reaches `wouldStop` (on words or as time passes).
    private mutating func announceIfDecided() {
        guard var o = open, o.candidate, !o.announced, o.closedAt == nil, now - o.start >= tuning.minSpeech,
              BargeInCheck.judge(candidate(o, duration: now - o.start), tuning: tuning).reason == .wouldStop else { return }
        o.announced = true
        open = o
        logs.append("wouldStopAt \(o.id) ms=\((now - o.start).milliseconds)")
    }

    private mutating func confirmLevel(_ id: Int) {
        guard let peak = unconfirmed.removeValue(forKey: id) else { return }
        peaks.append(peak)
        if peaks.count > tuning.barHistory { peaks.removeFirst(peaks.count - tuning.barHistory) }
    }

    private func candidate(_ o: Open, duration: NovaDuration) -> BargeInCheck.Candidate {
        BargeInCheck.Candidate(sinceEngineStart: o.sinceEngine, classifierMax: o.classifierMax, peakDb: o.peakDb,
                               barDb: barDb, duration: duration, partials: o.partials, final: o.final,
                               herSyllables: herSyllables, wordSyllables: o.wordSyllables)
    }

    private mutating func conclude(_ o: Open) {
        let duration = (o.closedAt ?? now) - o.start
        let v = BargeInCheck.judge(candidate(o, duration: duration), tuning: tuning)
        let outcome = v.reason == .wouldStop ? "wouldStop" : "rejected"
        logs.append("bargeInShadow \(o.id) outcome=\(outcome) reason=\(v.reason.rawValue) peakDb=\(o.peakDb) barDb=\(barDb) "
                    + "durationMs=\(duration.milliseconds) firstWordMs=\(v.firstWordMs.map(String.init) ?? "-") "
                    + "newSyllables=\(v.newSyllables) totalSyllables=\(v.totalSyllables)")
    }

    private mutating func forget() {
        // A safety bound only: words are normally cleared `echoWindow` after her playback ends.
        her.removeAll { now - $0.at > .seconds(120) }
        if let ended = herTurnEnded, now - ended >= tuning.echoWindow {
            her.removeAll()
            herTurnEnded = nil
        }
        unconfirmed = unconfirmed.filter { utterance - $0.key < 20 }
    }
}

/// F-08 §17 item 8: reply audio of a turn starting after the mute for that turn already ended.
public struct MuteEndWatch: Sendable {
    private var endedFor: Epoch?
    public init() {}

    /// The reply mute ended for `epoch`.
    public mutating func muteEnded(_ epoch: Epoch) { endedFor = epoch }

    /// A new model turn began: reply audio from now on is a new reply, not the rest of the last one (the epoch
    /// changes only on a flush, so it does not mark turns).
    public mutating func newTurn() { endedFor = nil }

    /// Reply audio of `epoch` started; the log line when the mute had already ended for it.
    public mutating func replyStarted(_ epoch: Epoch) -> String? {
        defer { endedFor = nil }
        return endedFor == epoch ? "muteEndedMidReply epoch=\(epoch.value)" : nil
    }
}
