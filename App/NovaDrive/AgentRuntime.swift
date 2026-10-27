import Foundation
import os
import NovaAgent
import NovaAudio
import NovaKit
import NovaNav
import NovaPlatform
import NovaPorts
import NovaRealtime
import NovaServices
import NovaTools
import NovaVoice
import SwiftUI

/// Everything the drive screen shows. Updated on the main actor only.
@MainActor
final class DriveModel: ObservableObject {
    @Published var view = AgentViewState()
    @Published var nav = NavigationFlowState()
    @Published var geometry = RouteGeometry()
    @Published var climate = ClimateState.default
    @Published var cabin = CabinState.default
    @Published var driverLine = ""
    @Published var toolLine = ""
    @Published var running = false
    @Published var notice: String?
    // F-20a floating camera window
    @Published var cameraOpen = false
    @Published var cameraAsking = false
    @Published var cameraAnswer: String?
    @Published var cameraDenied = false
    // F-20b 前方/后方 and the switch button (disabled without a selfie lens)
    @Published var cameraLens = CameraLens.frontView
    @Published var cameraSwitching = false
}

/// Non-secret settings of the drive screen (UserDefaults).
enum DriveSettings {
    static let azureRegion = "azure_region"
    static let azureVoice = "azure_voice"
    static let defaultVoice = "zh-CN-XiaoxiaoNeural"
    /// Qianfan model for the optional vision backend; the Android name is still an EVIDENCE_REQUEST.
    static let qianfanVisionModel = "ernie-4.5-turbo-vl"
    /// Demo start point (珠海市人民政府, GCJ-02), so no personal location is shown or used (REC-003).
    static let demoOrigin = GeoCoordinate(latitude: 22.270715, longitude: 113.576726, datum: .gcj02)
    /// F-16a 位置来源: on (default) = the phone's own fix; off = the demo start point for recordings (REC-003).
    static let useDeviceLocation = "use_device_location"

    static func usesDeviceLocation(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: useDeviceLocation) as? Bool ?? true
    }
}

/// 小诺's standing instruction for the Gemini Live session (≤ 4000 characters).
enum Persona {
    static let instruction = """
    你是小诺，车载语音助手，用户正在开车。用简短、自然的普通话口语回答，一般一两句话，不用列表、不用表情。
    规则：
    1. 调空调、温度、风量、车窗、座椅、导航、天气和路况，一定要调用工具，并且只按工具返回的结果回答。没有调用工具或者工具失败时，绝不能说已经做好了。
    2. 车辆控制是模拟车辆，结果以工具返回为准。
    3. 工具返回 next 或 instruction 时照着做，只说一句。屏幕上已经显示的列表不要念出来。
    4. 用户说「再低一点」「再高一点」这类没说明对象的话，也照常调用相应工具，系统会判断要不要反问。工具返回 AMBIGUOUS_REFERENT 时，只用一句话反问是哪一项，例如「是座椅还是温度？」，不要再调用工具。用户回答后再调用对应工具。
    5. 有点热、太热了：调低一度温度。有点冷：调高一度。座位有点高：座椅降低一级。
    6. 导航：「导航去X」用 navigate_to；用户说第几个、第几条、开始导航用 choose_navigation_option；结束或取消导航用 exit_navigation_mode。导航是模拟行驶。
    7. 问「我现在在哪」「这是哪里」：调用 query_live_info（kind=current_location），只按返回的 address 回答；没有返回 LOCATION_PERMISSION_DENIED 就不要说没有定位权限。
    8. 不知道的事情如实说不知道，不要编造。
    """
}

/// Keychain Gemini key as the realtime credential (OQ-IOS-15: ephemeral tokens later).
struct KeychainRealtimeCredentials: RealtimeCredentialSource {
    func credential() async throws -> RealtimeCredential {
        guard let key = try KeychainCredentialStore().value(for: .geminiAPIKey), !key.isEmpty else {
            throw RealtimeError(.credential)
        }
        return .apiKey(key)
    }
}

/// The demo start point stands in for the car's position.
struct DemoLocation: LocationProvider {
    /// The navigation flow's own clock: a fix is judged fresh against it (F-16 §3).
    let clock: SystemClock

    func latestFix() async -> LocationFix? {
        LocationFix(coordinate: DriveSettings.demoOrigin, horizontalAccuracyMeters: 10, timestamp: clock.now)
    }

    var source: LocationSource { .demo }
}

/// Applies AgentCore effects to the real provider, revoicer, playback and screen.
struct RuntimeSink: AgentEffectSink {
    let realtime: GeminiLiveProvider
    let config: SessionConfig
    let revoicer: Revoicer
    let audio: LiveAudio
    let model: DriveModel
    let speechOutput: SpeechOutputSwitch
    let fallbackVoice: any FallbackGuidanceVoice
    let gate: GateBox
    /// Reports `guidanceEnded` to the core for a sentence that never reached the guidance lane.
    let guidanceEnded: @Sendable (GuidanceID) async -> Void

    func provider(_ command: ProviderCommand) async {
        switch command {
        case .connect(let connection, let resume): await realtime.connect(config, resume: resume, connection: connection)
        case .close: await realtime.close()
        case .toolResponses(let responses): await realtime.sendToolResponses(responses)
        case .text(let turns, let complete): await realtime.sendText(turns, turnComplete: complete)
        }
    }

    func flushPlayback(to epoch: Epoch) { audio.flush(to: epoch) }
    func cancelRevoicing(_ epoch: Epoch) async { await revoicer.cancel(newEpoch: epoch) }
    func newReply() async { await revoicer.newReply() }
    func speak(_ clause: String) async {
        // set_speech_output silent: keep listening and acting, voice nothing.
        guard speechOutput.mode == .spoken else { return }
        await revoicer.speak(clause)
    }

    func publish(_ view: AgentViewState) async {
        await MainActor.run { model.view = view }
    }

    func diagnostic(_ event: DiagnosticEvent) {
        RuntimeLog.agent.notice("diagnostic \(String(describing: event), privacy: .public)")
    }

    /// F-14 fallback voice: rendered off the core, played on the guidance lane. A sentence that cannot
    /// be rendered still ends, so the relay moves on.
    func speakGuidance(_ text: String, id: GuidanceID) async {
        let voice = fallbackVoice
        let audio = audio
        let ended = guidanceEnded
        // A render that never finishes must not stall the relay: after 6 s the sentence ends unspoken.
        let once = OnceFlag()
        Task {
            let pcm = try? await voice.render(text)
            guard once.claim() else { return }
            if let pcm { audio.playGuidance(pcm, id: id) } else { await ended(id) }
        }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if once.claim() { await ended(id) }
        }
    }

    func uplink(open: Bool) { gate.setForcedClosed(!open) }
}

/// Vehicle tools, refreshing the car card after each call.
struct ObservedVehicleExecutor: ToolExecutor {
    let inner: any ToolExecutor
    let vehicle: SimulatedVehicle
    let model: DriveModel

    func execute(_ call: ToolCall) async -> ToolResult {
        let result = await inner.execute(call)
        let climate = await vehicle.climateState()
        let cabin = await vehicle.cabinState()
        await MainActor.run {
            model.climate = climate
            model.cabin = cabin
            model.toolLine = "\(call.name) → \(result.ok ? "ok" : (result.code?.rawValue ?? "failed"))"
        }
        return result
    }
}

/// F-19 dialler: `tel://` opens the system call sheet, which asks once more before calling.
struct SystemPhoneDialer: PhoneDialer {
    var canPlaceCalls: Bool {
        get async {
            await MainActor.run { URL(string: "tel://10086").map { UIApplication.shared.canOpenURL($0) } ?? false }
        }
    }

    func dial(_ number: String) async -> Bool {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { return false }
        return await withCheckedContinuation { done in
            Task { @MainActor in
                UIApplication.shared.open(url, options: [:]) { opened in done.resume(returning: opened) }
            }
        }
    }
}

/// `describe_camera_view` from the model: opens the window first (OQ-CAM-2), shows 看画面中… and the answer.
struct ObservedCameraExecutor: ToolExecutor {
    let runtime: AgentRuntime

    func execute(_ call: ToolCall) async -> ToolResult {
        await runtime.askCamera(call.arguments["question"]?.stringValue ?? "",
                                camera: call.arguments["camera"]?.stringValue.flatMap(CameraLens.init(rawValue:)))
    }
}

/// The composition root (ios-architecture §4): one live session with every adapter wired.
@MainActor
final class AgentRuntime {
    let model = DriveModel()
    /// T-061: 你好小诺 while idle starts a session (off in the simulator drive test).
    private lazy var wake = WakeListener { [weak self] in await self?.start() }
    private var core: AgentCore?
    /// Bumped per session so a delayed end_conversation stop never ends a newer session.
    private var session = 0
    private var audio: LiveAudio?
    private var tasks: [Task<Void, Never>] = []
    private let vehicle = SimulatedVehicle()
    let camera = CameraSession()
    private lazy var cameraQuestions: CameraQuestionHandler = {
        let geminiKey: @Sendable () -> String? = { try? KeychainCredentialStore().value(for: .geminiAPIKey) }
        let qianfanKey: @Sendable () -> String? = { try? KeychainCredentialStore().value(for: .qianfanKey) }
        let vision = PreferredVision(gemini: GeminiVisionClient(key: geminiKey),
                                     qianfan: QianfanVisionClient(key: qianfanKey, model: DriveSettings.qianfanVisionModel),
                                     hasGeminiKey: { geminiKey()?.isEmpty == false })
        // F-20b: the 前方/后方 label follows a voice-driven switch before the still is taken.
        let model = model
        return CameraQuestionHandler(camera: camera, vision: vision, clock: SystemClock(), lensChanged: { lens in
            Task { @MainActor in model.cameraLens = lens }
        })
    }()

    // MARK: Camera (F-20a)

    func toggleCamera() async {
        if model.cameraOpen {
            closeCamera()
        } else {
            await openCamera()
        }
    }

    @discardableResult
    func openCamera() async -> Bool {
        model.cameraDenied = false
        do {
            try await camera.start()
            model.cameraOpen = true
            return true
        } catch CameraError.permissionDenied {
            model.cameraDenied = true
            model.notice = "摄像头没有权限，请在 设置 > Nova Drive 里允许相机。"
        } catch {
            model.notice = "摄像头现在用不了。"
        }
        return false
    }

    /// F-20b switch button: the other lens; a tap while switching is ignored, a failure keeps the old lens.
    func switchCamera() async {
        guard model.cameraOpen, !model.cameraSwitching else { return }
        model.cameraSwitching = true
        defer { model.cameraSwitching = false }
        if await cameraQuestions.switchLens() == nil {
            RuntimeLog.agent.notice("CAMERA_SWITCH_FAILED")
        }
    }

    func closeCamera() {
        camera.stop()
        model.cameraOpen = false
        model.cameraAsking = false
        model.cameraAnswer = nil
        let questions = cameraQuestions
        Task { await questions.cancel() }
    }

    /// Voice path and 问一下 both come here; a closed window opens first (OQ-CAM-2). If it cannot open,
    /// nothing is captured and the honest code goes back (§8).
    func askCamera(_ question: String, camera named: CameraLens? = nil) async -> ToolResult {
        if !model.cameraOpen, !(await openCamera()) {
            return model.cameraDenied
                ? ToolDispatcher.failure(.cameraPermissionDenied)
                : ToolDispatcher.failure(.cameraUnavailable)
        }
        model.cameraAsking = true
        model.cameraAnswer = nil
        let result = await cameraQuestions.ask(question, camera: named)
        if result.code != .superseded {
            model.cameraAsking = false
            model.cameraAnswer = result.data["answer"]?.stringValue
        }
        return result
    }

    /// The flow of the running session (background policy reads its phase).
    private var navigation: NavigationController?

    /// F-25 §10 row 2 / I-6: a row tap enters AgentCore as `UIIntent.choose`, so it runs through the
    /// dispatcher and executor of the voice choice and she announces its read-back.
    func tapChoice(row: Int) async {
        if let core {
            await core.send(.ui(.choose(row: row)))
        } else if let navigation, UITestDrive.enabled {
            // T-048: no voice session in the simulator test; the same executor and arguments as the
            // `.choose(row:)` intent (row + 1).
            _ = await navigation.execute(ToolCall(id: CallID("ui-\(row)")!, name: "choose_navigation_option",
                                                  arguments: ["index": .int(Int64(row + 1))]))
        }
    }

    /// T-048: the simulator drive. The real `NavigationController` over a scripted search and engine;
    /// `navigate(to:)` stands in for the driver's 「导航去…」.
    func startUITestDrive() async {
        guard UITestDrive.enabled, navigation == nil else { return }
        let model = model
        let flags = AsyncStream.makeStream(of: NavigationFlowState.self, bufferingPolicy: .bufferingNewest(16))
        let clock = SystemClock()
        let navigation = NavigationController(search: ScriptedPlaceSearch(), engine: ScriptedRouteEngine(),
                                              location: DemoLocation(clock: clock), clock: clock,
                                              saved: SavedPlaces(settings: DefaultsSettingsStore())) { snapshot in
            flags.continuation.yield(snapshot)
        }
        await navigation.start()
        self.navigation = navigation
        tasks.append(Task {
            for await snapshot in flags.stream { await MainActor.run { model.nav = snapshot } }
        })
    }

    func navigate(to destination: String) async {
        _ = await navigation?.execute(ToolCall(id: CallID("ui-nav")!, name: "navigate_to",
                                               arguments: ["destination": .string(destination)]))
    }

    private var lifecycle: ConversationLifecycle?

    /// T-062 scene-phase bridge: ios-architecture §11.3. In the background only a navigating or
    /// mid-conversation session keeps the mic and socket; SLEEP and DEEP_IDLE end the session.
    func sceneChanged(_ phase: AppScenePhase) async {
        scene = phase
        if !UITestDrive.enabled { await wake.update(scene: phase) }
        await reevaluate()
    }

    private var scene = AppScenePhase.foreground
    private var stopPending = false

    /// Re-applied on every scene, lifecycle or navigation change (§11.3), not only on a scene change:
    /// a trip that ends while the lifecycle sleeps closes the session (no wake word on iOS yet), and in
    /// the background SLEEP / DEEP_IDLE without navigation close the mic and socket.
    func reevaluate() async {
        guard model.running, let lifecycle, let core else { return }
        let thisSession = session
        let state = lifecycle.state
        if state == .sleep || state == .deepIdle, await !(navigation?.current.navigating ?? false) {
            // Like the SLEEP stop: give the last sentence (arrival guidance, a goodbye) 3 s, and never
            // stop mid route swap or while the relay still holds a sentence; re-checked every second
            // until the session may stop or is needed again. One such wait at a time.
            guard !stopPending else { return }
            stopPending = true
            defer { stopPending = false }
            try? await Task.sleep(for: .seconds(3))
            while session == thisSession, let current = await navigation?.current {
                if current.navigating || !(lifecycle.state == .sleep || lifecycle.state == .deepIdle) { return }
                let busy = [.resolvingDestination, .calculatingRoute, .awaitingRouteSelection].contains(current.phase)
                if !busy, await !core.state.relay.busy {
                    stop()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return
        }
        let navigating = await navigation?.current.navigating ?? false
        if BackgroundDecision.decide(scene: scene, listening: state, navigating: navigating).keepSocket == false { stop() }
    }

    /// Speaks a line in her voice while a session runs (set in `start()`, cleared in `stop()`).
    private var speakLine: (@Sendable (String) async -> Void)?

    /// 问一下: the fixed question. The answer shows as her bubble and on the window, and is spoken in her
    /// voice while a session runs; with no session it is shown only (F-20a §7 as amended).
    func tapAsk() async {
        let result = await askCamera(CameraQuestionHandler.tapQuestion)
        // Window closed meanwhile (or a newer question): say nothing.
        guard result.code != .superseded, model.cameraOpen else { return }
        let line = result.data["answer"]?.stringValue
            ?? result.advice?.components(separatedBy: "请如实").first ?? "刚才没看清楚，再问我一次吧。"
        model.cameraAnswer = line
        model.view.subtitle = line
        await speakLine?(line)
    }

    func start() async {
        guard !model.running else { return }
        model.notice = nil
        // F-23 (T-063): the microphone is asked at the first talk; a denial is explained.
        let mic: PermissionStatus = switch MicrophonePermission.current {
        case true?: .granted
        case false?: .denied
        case nil: .notDetermined
        }
        switch PermissionCoordinator.action(for: .firstTalk, status: mic) {
        case .proceed: break
        case .request:
            guard await MicrophonePermission.request() else {
                model.notice = PermissionCoordinator.explanation(.microphone)
                return
            }
        case .explain(_, let message):
            model.notice = message
            return
        }
        let store = KeychainCredentialStore()
        switch SettingsReadiness(credentials: store, settings: DefaultsSettingsStore()).sessionBlocker {
        case .geminiConsentMissing?:
            model.notice = "请先在设置里同意 Gemini 使用条款"
            return
        case .some:
            model.notice = "请先在设置里保存 Gemini key"
            return
        case nil:
            break
        }
        guard let azureKey = try? store.value(for: .azureSpeechKey), !azureKey.isEmpty else {
            model.notice = "请先在设置里保存 Azure Speech key"
            return
        }
        let defaults = UserDefaults.standard
        var region = defaults.string(forKey: DriveSettings.azureRegion) ?? ""
        if region.isEmpty {
            model.notice = "正在识别 Azure 区域…"
            guard let found = await AzureRegionProbe.find(key: azureKey) else {
                model.notice = "Azure key 在常用区域都无效，请在设置里填写区域"
                return
            }
            region = found
            defaults.set(found, forKey: DriveSettings.azureRegion)
        }
        model.notice = nil
        let voice = defaults.string(forKey: DriveSettings.azureVoice) ?? DriveSettings.defaultVoice
        let synthesizer = AzureSpeechClient(config: AzureSpeechConfig(key: azureKey, region: region, voice: voice))

        let model = model
        let audio = LiveAudio()
        let provider = GeminiLiveProvider(credentials: KeychainRealtimeCredentials())
        let revoicer = Revoicer(synthesizer: synthesizer, playback: audio)
        let navigationClock = SystemClock()
        // F-16a: read per request, so switching 位置来源 in 设置 applies to the next question.
        let location = SwitchableLocationProvider(device: CoreLocationProvider(clock: navigationClock),
                                                  demo: DemoLocation(clock: navigationClock),
                                                  useDevice: { DriveSettings.usesDeviceLocation() })
        // Starts CoreLocation now, so the first request already has a fix.
        _ = await location.latestFix()
        let amapKey: @Sendable () -> String? = { try? KeychainCredentialStore().value(for: .amapWebKey) }
        let web = AmapWebClient(key: amapKey)
        let engine = AmapRouteEngine(key: amapKey, origin: {
            // Only a usable fix (F-16 §3) starts a route; the demo origin otherwise.
            guard let fix = await location.latestFix(), LocationQuality.of(fix, at: navigationClock.now) != nil else {
                return DriveSettings.demoOrigin
            }
            return CoordinateConverter.gcj02(fix.coordinate)
        },
                                     onGeometry: { geometry in Task { @MainActor in model.geometry = geometry } })
        let flags = AsyncStream.makeStream(of: NavigationFlowState.self, bufferingPolicy: .bufferingNewest(16))
        let savedPlaces = SavedPlaces(settings: DefaultsSettingsStore())
        let navigation = NavigationController(search: web, engine: engine, location: location, clock: navigationClock,
                                              saved: savedPlaces) { snapshot in
            flags.continuation.yield(snapshot)
        }
        await navigation.start()
        self.navigation = navigation
        let vehicleTools = ObservedVehicleExecutor(inner: VehicleToolExecutor(port: vehicle), vehicle: vehicle, model: model)
        // F-18: weather cached 10 min, adcodes 30 min (T-033).
        let cache = LiveInfoCache(weather: web, geocoder: web, clock: SystemClock())
        let liveInfo = LiveInfoExecutor(navigation: navigation, weather: cache, geocoder: cache, location: location)
        var executors: [String: any ToolExecutor] = [:]
        for name in VehicleToolExecutor.tools { executors[name] = vehicleTools }
        // F-12: scenarios go through the same simulated vehicle; the car card refreshes after each run.
        // F-13: the bundled loop on the media lane; play_music stays unavailable until OQ-IOS-7.
        let music = LaneMusicPlayer(audio: audio)
        let musicTools = MusicToolHandler(music: music, clock: SystemClock())
        for name in MusicToolHandler.tools { executors[name] = musicTools }
        executors[ScenarioToolHandler.tool] = ObservedVehicleExecutor(inner: ScenarioToolHandler(port: vehicle, music: music),
                                                                      vehicle: vehicle, model: model)
        for name in NavigationController.tools { executors[name] = navigation }
        executors["query_live_info"] = liveInfo
        executors[SavePlaceExecutor.tool] = SavePlaceExecutor(places: savedPlaces, search: web)
        executors["describe_camera_view"] = ObservedCameraExecutor(runtime: self)
        executors["place_call"] = PhoneCallHandler(contacts: ContactsStore(), dialer: SystemPhoneDialer(), clock: SystemClock())
        executors[OpenAppExecutor.tool] = OpenAppExecutor(surfaces: TabSurfaces())
        let settings = DefaultsSettingsStore()
        executors[SpeakingStyleHandler.tool] = SpeakingStyleHandler(settings: settings)
        // F-02: end_conversation sleeps the lifecycle; iOS has no wake word yet, so SLEEP ends the
        // session once the short goodbye has had time to play (PROPOSED 3 s).
        session += 1
        let thisSession = session
        let lifecycle = ConversationLifecycle(clock: SystemClock()) { effects in
            // Any state change re-applies the background policy (T-062).
            if effects.contains(where: { if case .stateChanged = $0 { true } else { false } }) {
                Task { @MainActor in
                    guard self.session == thisSession, self.scene == .background else { return }
                    await self.reevaluate()
                }
            }
            guard effects.contains(.stateChanged(.sleep)) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard self.session == thisSession else { return }
                // SLEEP keeps the session while navigating (listening-lifecycle §2): guidance goes on.
                guard await !navigation.current.navigating else { return }
                guard self.session == thisSession else { return }
                self.stop()
            }
        }
        await lifecycle.send(.wake)
        self.lifecycle = lifecycle
        executors[EndConversationHandler.tool] = EndConversationHandler(lifecycle: lifecycle)
        let speechOutput = SpeechOutputSwitch()
        executors[SpeechOutputHandler.tool] = SpeechOutputHandler(output: speechOutput)
        // F-21: the saved tone is read once here, at session start.
        let instruction = PersonaInstruction.build(base: Persona.instruction, style: SpeakingStyle.saved(in: settings))
        // The live model closes 1007 "Thinking level is not supported for this model." for any level (fixture close1007).
        let config = SessionConfig(systemInstruction: instruction, tools: ToolCatalog.declarations, thinkingLevel: nil)
        let gate = GateBox()
        let ended = CoreRelay()
        let sink = RuntimeSink(realtime: provider, config: config, revoicer: revoicer, audio: audio, model: model,
                               speechOutput: speechOutput, fallbackVoice: SystemSpeechGuidanceVoice(), gate: gate,
                               guidanceEnded: { id in await ended.send(.playback(.guidanceEnded(id))) })
        let core = AgentCore(clock: SystemClock(), sink: sink, tools: ToolRunner(executors: executors))
        ended.core = core
        self.core = core
        self.audio = audio
        speakLine = { line in
            if let pcm = try? await synthesizer.synthesize(line, style: .default, deadline: .seconds(6)) {
                audio.playGuidance(pcm, id: GuidanceID(UInt64(abs(line.hashValue % 1_000_000))))
            }
        }
        model.climate = await vehicle.climateState()
        model.cabin = await vehicle.cabinState()

        // Provider events, in order, to the core; the driver's words also to the screen.
        tasks.append(Task {
            for await event in provider.events {
                switch event.event {
                case .userTranscript(let text, _):
                    await MainActor.run { model.driverLine = text }
                case .failed(let error):
                    RuntimeLog.agent.error("provider failed \(error.code.rawValue, privacy: .public)")
                    await MainActor.run { model.notice = "连接错误：\(error.code.rawValue)" }
                case .closed, .setupComplete, .goAway:
                    RuntimeLog.agent.notice("provider \(String(describing: event.event), privacy: .public)")
                default:
                    break
                }
                await core.send(.realtime(event.event, connection: event.connection))
            }
        })
        tasks.append(Task {
            for await event in audio.events {
                await core.send(.playback(event))
                // F-14: a fallback waits until nothing of her reply is left, at the revoicer or on the lane.
                if case .replyFinished(let epoch) = event, await revoicer.pendingClauses == 0 {
                    await core.send(.playback(.replyIdle(epoch)))
                }
            }
        })
        // Navigation: the guards' flags, the screen, and each guidance sentence through the relay (F-14).
        tasks.append(Task {
            var relayed: GuidanceID?
            // Overspeed alerts get ids far above the engine's, so they never collide.
            var overspeedID = GuidanceID(1 << 40)
            var overspeed = OverspeedMonitor(clock: SystemClock())
            for await snapshot in flags.stream {
                let changed = await MainActor.run { () -> Bool in
                    let changed = model.nav.phase != snapshot.phase
                    model.nav = snapshot
                    return changed
                }
                // Every phase change re-applies the policy (a failed route swap returns to idle too).
                if changed { Task { await self.reevaluate() } }
                await core.send(.navigation(NavigationFlags(navigating: snapshot.navigating,
                                                            guidanceRunning: snapshot.navigating,
                                                            listOpen: snapshot.listOpen)))
                await core.send(.manoeuvreDistance(meters: snapshot.navigating ? snapshot.info?.stepDistanceMeters : nil))
                // F-17 (T-053): the overspeed alert is a guidance sentence, so the arbiter and relay order it.
                if snapshot.navigating, let info = snapshot.info, let alert = overspeed.observe(info) {
                    overspeedID = overspeedID.next()
                    await core.send(.guidancePrompt(alert, overspeedID))
                }
                if snapshot.navigating, let text = snapshot.lastGuidance, let id = snapshot.lastGuidanceID, id != relayed {
                    relayed = id
                    await core.send(.guidancePrompt(text, id))
                }
                if !snapshot.navigating { relayed = nil }
            }
        })
        // Uplink: the local gate decides what is sent and tells the core when the driver speaks.
        let gateEvents = AsyncStream.makeStream(of: UplinkGateOutput.self, bufferingPolicy: .bufferingNewest(512))
        tasks.append(Task {
            for await output in gateEvents.stream {
                switch output {
                case .speechStarted:
                    await core.send(.speechStarted(recentSpeech: gate.recentSpeech))
                case .speechStopped:
                    await core.send(.speechStopped)
                case .streamEnd:
                    await provider.sendAudioStreamEnd()
                case .audio:
                    break
                }
            }
        })
        let route: @Sendable (UplinkGateOutput) -> Void = { output in
            if case .audio(let frame) = output { provider.sendAudio(frame) } else { gateEvents.continuation.yield(output) }
        }
        gate.onOutput(route)
        // One capture only (ADR-006): the wake listener lets go of the mic before the session takes it.
        await wake.update(sessionRunning: true)
        do {
            try audio.start { frame in gate.process(frame).forEach(route) }
        } catch {
            model.notice = "麦克风启动失败"
            stop()
            return
        }
        Task { await synthesizer.warmUp() }
        await core.send(.start)
        model.running = true
    }

    func stop() {
        session += 1
        // F-20a §5: session stop closes the camera.
        if model.cameraOpen { closeCamera() }
        speakLine = nil
        navigation = nil
        lifecycle = nil
        guard let core else { return }
        let audio = audio
        Task {
            await core.send(.stop)
            audio?.stop()
        }
        tasks.forEach { $0.cancel() }
        tasks = []
        self.core = nil
        self.audio = nil
        model.running = false
        model.view = AgentViewState()
        if !UITestDrive.enabled { Task { await wake.update(sessionRunning: false) } }
    }

    /// Applies the wake policy at launch and after settings change.
    func refreshWake() async {
        guard !UITestDrive.enabled else { return }
        await wake.update(sessionRunning: model.running)
    }
}

enum RuntimeLog {
    static let agent = Logger(subsystem: "com.asapacsin.novadrive", category: "agent")
}

/// The uplink gate behind a lock; it runs on the capture thread.
final class GateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = SpeechUplinkGate()

    func process(_ frame: PCMFrame16k) -> [UplinkGateOutput] { lock.withLock { gate.process(frame) } }
    var recentSpeech: Bool { lock.withLock { gate.hasRecentSpeech } }
    /// Where outputs that do not come from a frame go (the force-close of an open segment).
    private var forward: (@Sendable (UplinkGateOutput) -> Void)?

    func onOutput(_ forward: @escaping @Sendable (UplinkGateOutput) -> Void) { lock.withLock { self.forward = forward } }

    /// F-08: closed while guidance sounds. Closing an open segment yields speechStopped, the closing
    /// silence and streamEnd, which go out exactly like frame outputs.
    func setForcedClosed(_ closed: Bool) {
        let (outputs, forward) = lock.withLock { (gate.setForcedClosed(closed), self.forward) }
        outputs.forEach { forward?($0) }
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Lets the sink report back to the core it belongs to (set once the core exists).
final class CoreRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _core: AgentCore?
    var core: AgentCore? {
        get { lock.withLock { _core } }
        set { lock.withLock { _core = newValue } }
    }

    func send(_ event: AgentEvent) async { await core?.send(event) }
}

/// Finds the Azure Speech region a key belongs to: the token endpoint answers 200 only there.
enum AzureRegionProbe {
    static let regions = ["eastasia", "southeastasia", "eastus", "westus2", "westeurope", "japaneast", "eastus2",
                          "westus", "northeurope", "centralus", "koreacentral", "australiaeast", "uksouth",
                          "francecentral", "centralindia", "canadacentral", "chinaeast2", "chinanorth2"]

    static func find(key: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for region in regions {
                group.addTask {
                    let host = region.hasPrefix("china") ? "\(region).api.cognitive.azure.cn" : "\(region).api.cognitive.microsoft.com"
                    var request = URLRequest(url: URL(string: "https://\(host)/sts/v1.0/issueToken")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 8
                    request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
                    request.setValue("0", forHTTPHeaderField: "Content-Length")
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return region
                }
            }
            for await found in group where found != nil {
                group.cancelAll()
                return found
            }
            return nil
        }
    }
}
