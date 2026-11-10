import NovaKit
import NovaPorts

/// Why the guard nudges the model (contracts/voice-agent.md §6, `A/voice/ActionClaimGuard.kt`).
public enum CorrectionReason: String, Sendable, Hashable, CaseIterable {
    case actionAskedNoToolCall = "ACTION_ASKED_NO_TOOL_CALL"
    case claimAfterFailure = "CLAIM_AFTER_FAILURE"
    case partialScenario = "PARTIAL_SCENARIO"
    case navigationNotStarted = "NAVIGATION_NOT_STARTED"
    case musicNotConfirmed = "MUSIC_NOT_CONFIRMED"
    case clarifyReferent = "CLARIFY_REFERENT"
    case unverifiedClaim = "UNVERIFIED_CLAIM"
    case wrongLanguage = "WRONG_LANGUAGE"

    /// Sent to the model as a text turn. Code decides when; the sentence only explains (I-11).
    public var instruction: String {
        switch self {
        case .actionAskedNoToolCall: "[系统] 司机要求执行操作，但你没有调用工具。请调用对应工具，或如实说明无法执行。"
        case .claimAfterFailure: "[系统] 工具返回失败，操作没有完成。请如实告诉司机失败原因，不要说已完成。"
        case .partialScenario: "[系统] 场景只完成了一部分。请只说已完成的部分，并说明未完成的部分。"
        case .navigationNotStarted: "[系统] NAVIGATION_NOT_STARTED：导航还没有开始，不要说导航已开始。"
        case .musicNotConfirmed: "[系统] MUSIC_NOT_CONFIRMED：没有确认音乐正在播放，不要说正在播放。"
        case .clarifyReferent: "[系统] 指代不明确。请用一句简短的话问司机具体指哪一项。"
        case .unverifiedClaim: "[系统] 你声称已完成操作，但没有成功的工具结果。请先调用工具，或如实说明。"
        // F-05a §15 item 4 as changed by §16 item 5 (T-016n): never with the driver's words.
        case .wrongLanguage: "[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。请用中文简短地请司机再说一遍。"
        }
    }
}

public enum PipelineInput: Sendable, Hashable {
    /// A final driver transcript: a new utterance (resets the one-nudge and one-re-ask budgets).
    case driverUtterance(String)
    case turnOpened(TurnID)
    case replyText(TurnID, String)
    case replyAudio(TurnID, PCMBuffer)
    case toolCalls(TurnID, [ToolCall])
    case toolResult(TurnID, ToolResponse)
    /// `generationComplete`.
    case audioDone(TurnID)
    case turnClosed(TurnID, TurnOutcome)
    case navigationPhase(NavigationPhase)
    /// Verified now-playing state from the media lane (F-13).
    case musicPlaying(Bool)
    case timerFired(PipelineTimer)
    /// F-08 §15 item 3: a stop phrase ended her reply; the no-answer clock of that utterance stops.
    case stopped
}

public struct PipelineTimer: Sendable, Hashable {
    /// `language`: the 800 ms hold on her first audio (F-05a §15 item 3); `fallback`: 6 s after the
    /// WRONG_LANGUAGE re-ask with no reply (item 5).
    public enum Kind: Sendable, Hashable { case correction, reask, giveUp, language, fallback }
    public let kind: Kind
    public let epoch: Epoch
}

public enum PipelineOutput: Sendable, Hashable {
    /// Judged reply text: subtitle and the source of revoiced clauses.
    case speechText(TurnID, String)
    /// Judged provider audio (only without revoicing).
    case speechAudio(TurnID, PCMBuffer)
    /// Everything held for this turn was dropped; the shell flushes playback to a new epoch.
    case voided(TurnID)
    case sendCorrection(CorrectionReason)
    /// 「请回应我刚才说的话。」
    case reask(String)
    /// Nothing came back within 5 s even after the re-ask.
    case gaveUp
    case schedule(PipelineTimer, at: NovaInstant)
    case cancelTimer(PipelineTimer.Kind)
    /// F-05a §15 item 4: the one WRONG_LANGUAGE text turn of an utterance, sent at once.
    case languageReask
    /// F-05a §15 item 5: the app itself says 「没听清，请再说一遍」 with the system voice, as her line.
    case fallbackLine
    /// F-05a §15 item 7: a record and log line, codes and numbers only.
    case languageLine(ReplyLanguageLine)
    case diagnostic(DiagnosticEvent)
}

/// `DriverTurnPipeline` + claim gate, `ActionClaimGuard`, correction grace, empty-response re-ask and
/// phantom-turn gate (F-06). Invariants I-1, I-5: claim text and audio are held together until an
/// `ok=true` result proves them, and dropped otherwise. I-11: all of it is code, not prompt.
public struct DriverTurnPipeline: Sendable {
    public static let reaskText = "请回应我刚才说的话。"
    /// F-05a §15 item 5: said by the app with the system voice when the re-ask fails.
    public static let fallbackLineText = "没听清，请再说一遍"
    /// F-05a §15 item 3: her first audio waits at most this long for the language verdict.
    public static let languageHold = NovaDuration.milliseconds(800)
    /// F-05a §15 item 5: no reply this long after the WRONG_LANGUAGE re-ask says the fallback line.
    public static let fallbackAfter = NovaDuration.seconds(6)
    /// F-08 §15 item 3: the re-ask names the driver's newest words, so the model never returns to an old topic.
    public static func reaskText(newest: String) -> String {
        newest.allSatisfy(\.isWhitespace) ? reaskText : "请回答我最新的这句话：「\(newest)」"
    }

    private struct Turn {
        let id: TurnID
        var text = ""
        var held: [PipelineOutput] = []
        var heldEvents = 0
        /// Every kind of claim made so far; each needs its own proof.
        var claims: Set<ClaimKind> = []
        var claim: ClaimKind? { claims.reduce(nil) { ClaimKind.strongest($0, $1) } }
        var pendingCalls: Set<CallID> = []
        /// F-18 §27 item 5 (T-020c): NON_BLOCKING calls; the turn is not held for them.
        var backgroundCalls: Set<CallID> = []
        var hadBlockingCall = false
        var results: [ToolResponse] = []
        var hadToolCall = false
        var audioSeen = false
        var voided = false
        var closed = false
        /// No real driver utterance led to this turn: hold it until it proves to be more than a blip.
        var phantomSuspect: Bool
        /// F-05a §15 items 2-3: the language verdict, sticky once reached, and whether 800 ms released the hold.
        var language = ReplyLanguageCheck.Verdict.undecided
        var languageReleased = false
        var languageLogged = false
        var firstAudioAt: NovaInstant?
        var languageOpen: Bool { language == .allowed || languageReleased }
    }

    private let tuning: TruthfulnessTuning
    /// F-07 §15 item 7 (T-020b, Gemini 原声 only): a clean chat turn releases its audio as it comes, like its text.
    /// Proven and pending turns keep their holds; a claim found later is cut by the void (item 8).
    private let streamsCleanAudio: Bool
    private var turn: Turn?
    private var navigation = NavigationPhase.idle
    private var musicPlaying = false
    /// Evidence must postdate the request it proves: a new play / navigate call makes the current
    /// playback or NAVIGATING state stale until a fresh report arrives after it (review 6).
    private var musicFresh = true
    private var navigationFresh = true
    private var musicConfirmed: Bool { musicPlaying && musicFresh }
    private var navigationConfirmed: Bool { navigation == .navigating && navigationFresh }
    private var lastUtterance = ""
    /// Tool evidence of the current utterance. Gemini puts the call in one turn and the spoken result
    /// in the next (recorded, T-003 tool.jsonl), so proof is scoped to the utterance, not the turn.
    private var utteranceCalls: Set<CallID> = []
    private var utterancePending: Set<CallID> = []
    /// F-18 §27 item 5: the utterance's NON_BLOCKING calls (a subset of the calls it made).
    private var utteranceBackground: Set<CallID> = []
    private var utteranceResults: [ToolResponse] = []
    private var utteranceAsksAction = false
    /// A real utterance arrived since the last turn opened.
    private var freshUtterance = false
    private var nudgedThisUtterance = false
    private var reaskedThisUtterance = false
    private var pendingCorrection: CorrectionReason?
    /// F-05a §15: the detector, and the one re-ask and one fallback line of an utterance.
    private let detector: any LanguageIdentifier
    private var wrongLanguageAsked = false
    private var awaitingReaskReply = false
    private var fallbackSaid = false
    private var lastBlockedTurn = 0
    /// §15 item 6: the open (or last) reply's verdict is `allowed`, so Latin-only text counts as English on screen.
    public private(set) var replyLanguageAllowed = false
    private var timerEpoch = Epoch.initial
    private var timers: [PipelineTimer.Kind: Epoch] = [:]

    public init(tuning: TruthfulnessTuning = TruthfulnessTuning(), streamsCleanAudio: Bool = false,
                detector: any LanguageIdentifier = NoLanguageIdentifier()) {
        self.tuning = tuning
        self.streamsCleanAudio = streamsCleanAudio
        self.detector = detector
    }

    public mutating func handle(_ input: PipelineInput, at now: NovaInstant) -> [PipelineOutput] {
        switch input {
        case .driverUtterance(let text):
            lastUtterance = text
            // F-05a §15 items 4-5: a new utterance has its own re-ask, and cancels a fallback line not yet said.
            wrongLanguageAsked = false
            awaitingReaskReply = false
            fallbackSaid = false
            utteranceAsksAction = ClaimLexicon.asksForAction(text)
            // A request for music or navigation makes the current state stale even if no tool is called.
            // Scoped to this utterance, and a question (「导航还要多久到」) is not a request.
            musicFresh = true
            navigationFresh = true
            let question = Self.questionWords.contains(where: text.contains)
            if !question, Self.musicRequest.contains(where: text.contains) { musicFresh = false }
            if !question, Self.navigationRequest.contains(where: text.contains) { navigationFresh = false }
            freshUtterance = Self.length(text) >= tuning.phantomMinTranscript
            nudgedThisUtterance = false
            reaskedThisUtterance = false
            pendingCorrection = nil
            utteranceCalls = []
            utterancePending = []
            utteranceBackground = []
            utteranceResults = []
            // A new driver turn cancels a pending correction and starts the no-answer clock.
            return cancel(.correction) + cancel(.giveUp) + cancel(.fallback)
                + schedule(.reask, at: now + tuning.emptyResponseReask)
        case .turnOpened(let id):
            var opened = Turn(id: id, phantomSuspect: !freshUtterance)
            // A later turn of the same utterance inherits its calls and results.
            opened.results = utteranceResults
            opened.pendingCalls = utterancePending
            opened.backgroundCalls = utterancePending.intersection(utteranceBackground)
            opened.hadToolCall = !utteranceCalls.isEmpty
            opened.hadBlockingCall = !utteranceCalls.subtracting(utteranceBackground).isEmpty
            turn = opened
            freshUtterance = false
            replyLanguageAllowed = false
            return modelResponded() + cancel(.language)
        case .replyText(let id, let text):
            guard var t = current(id) else { return [] }
            t.text += text
            // Re-judged on the whole text each time: a later sentence may make a stronger claim.
            t.claims.formUnion(ClaimLexicon.claims(in: t.text))
            turn = t
            var out = modelResponded() + (t.voided ? [] : replyArrived())
            // F-05a §15 item 2: Chinese, English or Japanese only, checked in code before she says it.
            out += updateLanguage(final: false, at: now)
            if turn?.voided == true { return out }
            return out + route(.speechText(id, text), at: now)
        case .replyAudio(let id, let pcm):
            guard var t = current(id) else { return [] }
            var out = modelResponded() + (t.voided ? [] : replyArrived())
            if t.firstAudioAt == nil {
                t.firstAudioAt = now
                turn = t
                // §15 item 3: the first audio waits for the verdict, at most 800 ms.
                if !t.voided, !t.languageOpen { out += schedule(.language, at: now + Self.languageHold) }
            }
            return out + route(.speechAudio(id, pcm), at: now)
        case .toolCalls(let id, let calls):
            for call in calls {
                switch call.name {
                case "navigate_to", "choose_navigation_option": navigationFresh = false
                case "play_music": musicFresh = false
                case "control_music" where call.arguments["action"]?.stringValue == "play": musicFresh = false
                default: break
                }
            }
            utteranceCalls.formUnion(calls.map(\.id))
            utterancePending.formUnion(calls.map(\.id))
            utteranceBackground.formUnion(calls.filter { AsyncTool(name: $0.name) != nil }.map(\.id))
            guard var t = current(id) else { return [] }
            t.pendingCalls.formUnion(calls.map(\.id))
            t.backgroundCalls.formUnion(calls.filter { AsyncTool(name: $0.name) != nil }.map(\.id))
            t.hadToolCall = true
            if calls.contains(where: { AsyncTool(name: $0.name) == nil }) { t.hadBlockingCall = true }
            turn = t
            // The model did act after all: the nudge waiting in its grace period is not needed.
            pendingCorrection = nil
            return modelResponded() + cancel(.correction)
        case .toolResult(let id, let response):
            let ofUtterance = utterancePending.remove(response.id) != nil
            if ofUtterance { utteranceResults.append(response) }
            // The result may arrive after its own turn closed; it then proves the utterance's open turn.
            guard var t = turn, t.id == id || ofUtterance else { return [] }
            t.pendingCalls.remove(response.id)
            if !t.results.contains(response) { t.results.append(response) }
            turn = t
            return judge(at: now)
        case .audioDone(let id), .turnClosed(let id, _):
            guard var t = current(id) else { return [] }
            if case .turnClosed = input { t.closed = true }
            turn = t
            return settle(at: now)
        case .navigationPhase(let phase):
            // Only a transition into NAVIGATING is fresh evidence, not a republished snapshot.
            if phase == .navigating && navigation != .navigating { navigationFresh = true }
            navigation = phase
            return judge(at: now)
        case .musicPlaying(let playing):
            // Only a transition into playing is fresh evidence. Contract for the media lane (F-13, T-032 /
            // T-072): report `false` when a new request starts and `true` once that request is verified.
            if playing && !musicPlaying { musicFresh = true }
            musicPlaying = playing
            return judge(at: now)
        case .timerFired(let timer):
            guard timers[timer.kind] == timer.epoch else { return [] }
            timers[timer.kind] = nil
            return fire(timer.kind, at: now)
        case .stopped:
            pendingCorrection = nil
            let cancelled = cancel(.reask) + cancel(.giveUp) + cancel(.correction)
            return cancelled.isEmpty ? [] : cancelled + [.diagnostic(.reaskSuppressed)]
        }
    }

    // MARK: Claim gate

    private enum Verdict { case clean, proven, pending, disproven(CorrectionReason) }

    /// Tools that only read: their ok result proves no action.
    static let readOnlyTools: Set<String> = ["query_live_info", "web_search", "describe_camera_view", "get_vehicle_state"]

    /// Tools whose ok result changes nothing in the car: a tone change, muting or ending the
    /// conversation, or a call not yet dialled (`place_call` proves a call only with status `dialing`, F-19 §8).
    static let nonActingTools: Set<String> = ["set_speaking_style", "set_speech_output", "end_conversation"]

    private func acts(_ r: ToolResponse) -> Bool {
        if Self.readOnlyTools.contains(r.name) || Self.nonActingTools.contains(r.name) { return false }
        // A failed call still disproves a call claim at once.
        if r.name == "place_call" { return r.result.data["status"] == .string("dialing") || !r.result.ok }
        return r.result.data["action"] != .string("get_state")
    }

    /// Whether the turn must be held whole: audio can run ahead of its transcript, so in a turn that
    /// may claim an action nothing is released until the claim is proven or the turn is over (I-1, I-5).
    private func holdsWhole(_ t: Turn) -> Bool {
        // F-18 §27 item 5: a turn whose only calls run in the background is a chat turn.
        utteranceAsksAction || t.hadBlockingCall || !t.claims.isEmpty
    }

    /// Tools whose ok result is not yet evidence: navigation is proven by the phase, music by playback.
    static let evidenceTools: Set<String> = ["navigate_to", "choose_navigation_option", "control_music", "play_music"]

    static let questionWords = ["吗", "多久", "多远", "什么", "哪", "几", "?", "？", "怎么样"]
    static let navigationRequest = ["导航", "带我去", "带我到", "回家", "去公司", "开过去"]
    static let musicRequest = ["放首", "放歌", "播放", "音乐", "听歌", "来首", "放一首"]

    /// A navigation or music outcome that the reply may claim is not yet evidenced.
    private func evidenceOutstanding(_ t: Turn) -> Bool {
        let okNames = Set(t.results.filter(\.result.ok).map(\.name))
        let navAwaited = !okNames.isDisjoint(with: ["navigate_to", "choose_navigation_option"])
            || Self.navigationRequest.contains(where: lastUtterance.contains)
        let musicAwaited = !okNames.isDisjoint(with: ["control_music", "play_music"])
            || Self.musicRequest.contains(where: lastUtterance.contains)
        return navAwaited && !navigationConfirmed || musicAwaited && !musicConfirmed
    }

    /// An ok navigation or music result whose own evidence holds: NAVIGATING, or playback verified
    /// (or verified stopped for `control_music{stop}`).
    private func evidenced(_ r: ToolResponse) -> Bool {
        switch r.name {
        case "navigate_to", "choose_navigation_option": navigationConfirmed
        case "control_music" where r.result.data["action"] == .string("stop") || r.result.data["status"] == .string("stopped"):
            !musicPlaying
        default: musicConfirmed
        }
    }

    private func verdict(_ t: Turn, final: Bool) -> Verdict {
        let acting = t.results.filter(acts)
        let failed = acting.filter { !$0.result.ok }
        if t.results.contains(where: { !$0.result.ok && $0.result.code == .ambiguousReferent }) {
            // An honest clarification question is heard; a claim on top of the ambiguity is not.
            if t.claims.isEmpty { return final ? .clean : .pending }
            return .disproven(.clarifyReferent)
        }
        if !t.claims.isEmpty, acting.contains(where: { $0.result.ok && $0.result.data["partial"] == .bool(true) }) {
            return .disproven(.partialScenario)
        }
        // A call still open when the turn closes will never prove anything said in it.
        if !t.pendingCalls.subtracting(t.backgroundCalls).isEmpty { return final && t.closed && !t.claims.isEmpty ? .disproven(.unverifiedClaim) : .pending }
        if t.claims.isEmpty {
            // An ok result of a direct-acting tool with nothing failed proves the turn's action: release it
            // (Android `DriverTurn.kt:270`). Navigation and music results wait for their own evidence.
            let awaitsEvidence = acting.contains { Self.evidenceTools.contains($0.name) }
            if failed.isEmpty, !awaitsEvidence, acting.contains(where: \.result.ok) { return .proven }
            return !holdsWhole(t) || final ? .clean : .pending
        }
        // Every claim needs its own proof; the most specific disproof wins, then any pending one holds.
        var pending = false
        for claim in [ClaimKind.navigationStarted, .musicPlaying, .action] where t.claims.contains(claim) {
            switch verdict(of: claim, t, acting: acting, failed: failed, final: final) {
            case .disproven(let reason): return .disproven(reason)
            case .pending: pending = true
            case .proven, .clean: break
            }
        }
        return pending ? .pending : .proven
    }

    private func verdict(of claim: ClaimKind, _ t: Turn, acting: [ToolResponse], failed: [ToolResponse],
                         final: Bool) -> Verdict {
        switch claim {
        case .navigationStarted:
            if navigationConfirmed { return .proven }
            if !final || navigation.isSessionActive && !t.closed { return .pending }
            return .disproven(.navigationNotStarted)
        case .musicPlaying:
            let musicFailed = failed.contains { $0.name == "control_music" || $0.name == "play_music" }
            if musicConfirmed && !musicFailed { return .proven }
            // Verified playback may report after generationComplete: wait for the turn to close.
            if !final || !t.closed && !musicFailed { return .pending }
            return .disproven(.musicNotConfirmed)
        case .action:
            if !failed.isEmpty { return .disproven(.claimAfterFailure) }
            // An ok navigation or music result proves nothing by itself (「已为您开启导航」 before NAVIGATING).
            let proofs = acting.filter { $0.result.ok && (!Self.evidenceTools.contains($0.name) || evidenced($0)) }
            if !proofs.isEmpty {
                // F-12 §14 item 12: a claim naming windows, climate, fan or music needs that tool's own ok result;
                // an ok fan call does not prove 「车窗开了」.
                if ClaimLexicon.unbackedTopics(in: t.text, proofs: proofs.map { ($0.name, $0.result.data) }).isEmpty {
                    return .proven
                }
                return final ? .disproven(.unverifiedClaim) : .pending
            }
            if !final { return .pending }
            return .disproven(t.hadToolCall ? .unverifiedClaim
                                : utteranceAsksAction ? .actionAskedNoToolCall : .unverifiedClaim)
        }
    }

    private func isProven(_ t: Turn) -> Bool {
        if case .proven = verdict(t, final: false) { return true }
        return false
    }

    /// Sends an output through the gate: emitted at once only if nothing in the turn needs proof.
    private mutating func route(_ output: PipelineOutput, at now: NovaInstant) -> [PipelineOutput] {
        guard var t = turn, !t.voided else { return [] }
        // Audio runs ahead of its transcript, so outside a proven turn it waits for the turn's end.
        if case .speechAudio = output { t.audioSeen = true }
        t.held.append(output)
        t.heldEvents += 1
        turn = t
        // F-05a §15 item 3: nothing of a turn goes out before its language is allowed or the 800 ms ran out.
        guard t.languageOpen else { return [] }
        if t.heldEvents > tuning.holdBudgetEvents {
            // Hold budget spent: an unproven claim is dropped. In a turn held whole with nothing to
            // judge yet the held audio is dropped (never released unjudged); a chat turn goes through.
            if !t.claims.isEmpty, !isProven(t) { return void(.unverifiedClaim, at: now) }
            if holdsWhole(t), !isProven(t) || evidenceOutstanding(t) { return dropHeldAudio() }
            turn?.phantomSuspect = false
            return release()
        }
        return judge(at: now)
    }

    /// Re-evaluates the open turn: release, keep holding, or void.
    private mutating func judge(at now: NovaInstant, final: Bool = false) -> [PipelineOutput] {
        guard let t = turn, !t.voided, t.languageOpen else { return [] }
        if t.phantomSuspect {
            if !Self.isShort(t.text, tuning) || t.hadToolCall || !t.claims.isEmpty {
                turn?.phantomSuspect = false  // more than a blip: judge it like any turn
            } else if final {
                return dropPhantom()          // a short reply to nothing: dropped silently
            } else {
                return []
            }
        }
        switch verdict(turn!, final: final) {
        case .proven:
            // Audio runs ahead of its transcript: while navigation or music evidence is outstanding an
            // unread claim may be on it, so only judged text goes out (L1, L3).
            return evidenceOutstanding(turn!) && !final ? releaseText() : release()
        case .clean:
            // A clean chat turn releases judged text as it comes; its audio waits for the end, except with
            // Gemini 原声, where it streams too (F-07 §15 item 7).
            return final || streamsCleanAudio ? release() : releaseText()
        case .pending:
            return []
        case .disproven(let reason):
            return void(reason, at: now)
        }
    }

    /// generationComplete / turnComplete: nothing more will come, so a pending claim is decided now.
    private mutating func settle(at now: NovaInstant) -> [PipelineOutput] {
        // §15 item 2: at the end of the reply an undecided verdict is decided.
        var out = updateLanguage(final: true, at: now)
        out += judge(at: now, final: true)
        // The driver asked for an action, the turn ended, and no tool was called (no claim either).
        if let t = turn, t.closed, !t.voided, !t.hadToolCall, t.claims.isEmpty, utteranceAsksAction,
           !t.text.isEmpty {
            out += nudge(.actionAskedNoToolCall, at: now)
        }
        if turn?.closed == true { turn = nil }
        return out
    }

    private mutating func release() -> [PipelineOutput] {
        guard var t = turn else { return [] }
        let held = t.held
        let events = t.heldEvents
        t.held.removeAll()
        t.heldEvents = 0
        turn = t
        // Only report a hold that waited on something (more than the single event passing through).
        return (events > 1 ? [.diagnostic(.claimHeld(events: events))] : []) + held
    }

    private mutating func void(_ reason: CorrectionReason, at now: NovaInstant) -> [PipelineOutput] {
        guard var t = turn, !t.voided else { return [] }
        t.voided = true
        t.held.removeAll()
        turn = t
        return [.voided(t.id)] + nudge(reason, at: now)
    }

    private mutating func releaseText() -> [PipelineOutput] {
        guard var t = turn else { return [] }
        let text = t.held.filter { if case .speechText = $0 { true } else { false } }
        t.held.removeAll { if case .speechText = $0 { true } else { false } }
        t.heldEvents = t.held.count
        turn = t
        return text
    }

    private mutating func dropHeldAudio() -> [PipelineOutput] {
        guard var t = turn else { return [] }
        let before = t.held.count
        t.held.removeAll { if case .speechAudio = $0 { true } else { false } }
        t.heldEvents = t.held.count
        turn = t
        return [.diagnostic(.claimHeld(events: before - t.held.count))]
    }

    private mutating func dropPhantom() -> [PipelineOutput] {
        guard var t = turn else { return [] }
        t.voided = true
        t.held.removeAll()
        turn = t
        return [.voided(t.id)]
    }

    // MARK: Corrections and re-ask

    /// One corrective nudge per utterance, sent after the grace period unless a tool call or a new
    /// driver turn cancels it.
    private mutating func nudge(_ reason: CorrectionReason, at now: NovaInstant) -> [PipelineOutput] {
        guard !nudgedThisUtterance else { return [] }
        nudgedThisUtterance = true
        pendingCorrection = reason
        let toolMayFollow = reason == .actionAskedNoToolCall || reason == .unverifiedClaim && utteranceAsksAction
        let grace = toolMayFollow ? tuning.correctionGraceToolMayFollow : tuning.correctionGraceChat
        return schedule(.correction, at: now + grace)
    }

    private mutating func modelResponded() -> [PipelineOutput] {
        cancel(.reask) + cancel(.giveUp)
    }

    private mutating func fire(_ kind: PipelineTimer.Kind, at now: NovaInstant) -> [PipelineOutput] {
        switch kind {
        case .correction:
            guard let reason = pendingCorrection else { return [] }
            pendingCorrection = nil
            freshUtterance = true  // the model's next turn answers this, not a phantom
            return [.sendCorrection(reason), .diagnostic(.correctionSent)]
        case .reask:
            guard !reaskedThisUtterance else { return [] }
            reaskedThisUtterance = true
            freshUtterance = true
            let giveUpAfter = tuning.emptyResponseGiveUp - tuning.emptyResponseReask
            return [.reask(Self.reaskText(newest: lastUtterance)), .diagnostic(.emptyResponseReask)] + schedule(.giveUp, at: now + giveUpAfter)
        case .giveUp:
            return [.gaveUp]
        case .language:
            // §15 item 3: no verdict in 800 ms: the audio goes out and the check goes on.
            guard var t = turn, !t.voided, t.language == .undecided, !t.languageReleased else { return [] }
            t.languageReleased = true
            t.languageLogged = true
            turn = t
            return [.languageLine(checkLine(t, .released, at: now))] + judge(at: now)
        case .fallback:
            guard awaitingReaskReply, !fallbackSaid else { return [] }
            return fallback(.noReply, turn: lastBlockedTurn)
        }
    }

    // MARK: F-05a §15 (T-016m): the reply's language

    /// Re-judges the open turn's language on its whole text. Sticky: `blocked` stays; `allowed` turns `blocked`
    /// only for a letter of another script. Reaching a verdict writes the turn's one `lang-check` line.
    private mutating func updateLanguage(final: Bool, at now: NovaInstant) -> [PipelineOutput] {
        guard var t = turn, !t.voided else { return [] }
        switch t.language {
        case .blocked:
            return []
        case .allowed:
            guard ReplyLanguage.isNotAllowed(t.text) else { return [] }
            t.language = .blocked
        case .undecided:
            if final, t.text.isEmpty, t.firstAudioAt == nil {
                // A turn with no words or audio (a tool call only) has nothing to judge.
                t.language = .allowed
                turn = t
                replyLanguageAllowed = true
                return cancel(.language)
            }
            t.language = ReplyLanguageCheck.verdict(t.text, final: final, detector: detector)
            guard t.language != .undecided else { return [] }
        }
        var out = cancel(.language)
        if !t.languageLogged {
            t.languageLogged = true
            out.append(.languageLine(checkLine(t, t.language == .allowed ? .allowed : .blocked, at: now)))
        }
        turn = t
        replyLanguageAllowed = t.language == .allowed
        return t.language == .blocked ? out + blockedLanguage(at: now) : out
    }

    private func checkLine(_ t: Turn, _ verdict: ReplyLanguageLine.Reached, at now: NovaInstant) -> ReplyLanguageLine {
        let top = t.text.isEmpty ? nil : detector.hypotheses(t.text).first
        let held = t.firstAudioAt.map { max(0, Int((now - $0).milliseconds)) } ?? 0
        return .check(turn: Int(t.id.value), verdict: verdict, language: top?.language,
                      probability: top?.probability ?? 0, heldMs: held)
    }

    /// §15 items 3-5: a blocked reply is voided whole (nothing of it shown or spoken); the first of an utterance gets
    /// the one WRONG_LANGUAGE re-ask at once, a second one the fallback line.
    private mutating func blockedLanguage(at now: NovaInstant) -> [PipelineOutput] {
        guard var t = turn else { return [] }
        t.voided = true
        t.held.removeAll()
        turn = t
        lastBlockedTurn = Int(t.id.value)
        var out: [PipelineOutput] = [.voided(t.id)]
        if !wrongLanguageAsked {
            wrongLanguageAsked = true
            awaitingReaskReply = true
            freshUtterance = true  // the model's next turn answers the re-ask, not a phantom
            // One text turn only: a correction still in its grace period is dropped for the re-ask.
            pendingCorrection = nil
            out += cancel(.correction)
            out += [.languageReask, .languageLine(.correction)]
            out += schedule(.fallback, at: now + Self.fallbackAfter)
        } else if !fallbackSaid {
            out += fallback(.blockedAgain, turn: lastBlockedTurn)
        }
        return out
    }

    /// Reply audio or text came: the re-ask was answered (its verdict still decides).
    private mutating func replyArrived() -> [PipelineOutput] {
        guard awaitingReaskReply else { return [] }
        awaitingReaskReply = false
        return cancel(.fallback)
    }

    private mutating func fallback(_ reason: ReplyLanguageLine.FallbackReason, turn number: Int) -> [PipelineOutput] {
        fallbackSaid = true
        awaitingReaskReply = false
        return cancel(.fallback) + [.fallbackLine, .languageLine(.fallback(turn: number, reason: reason))]
    }

    // MARK: Helpers

    private func current(_ id: TurnID) -> Turn? {
        guard let t = turn, t.id == id else { return nil }
        return t
    }

    private mutating func schedule(_ kind: PipelineTimer.Kind, at deadline: NovaInstant) -> [PipelineOutput] {
        timerEpoch = timerEpoch.next()
        timers[kind] = timerEpoch
        return [.schedule(PipelineTimer(kind: kind, epoch: timerEpoch), at: deadline)]
    }

    private mutating func cancel(_ kind: PipelineTimer.Kind) -> [PipelineOutput] {
        timers.removeValue(forKey: kind) == nil ? [] : [.cancelTimer(kind)]
    }

    /// Characters that count, ignoring whitespace and punctuation.
    static func length(_ text: String) -> Int {
        text.unicodeScalars.filter { !$0.properties.isWhitespace && !isPunctuation($0) }.count
    }

    /// ≤12 CJK characters, or ≤40 Latin characters when there is no CJK.
    static func isShort(_ text: String, _ tuning: TruthfulnessTuning) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace && !isPunctuation($0) }
        let cjk = scalars.filter { $0.properties.isIdeographic }.count
        return cjk > 0 ? cjk <= tuning.phantomMaxCJK && scalars.count - cjk <= tuning.phantomMaxLatin
                       : scalars.count <= tuning.phantomMaxLatin
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
