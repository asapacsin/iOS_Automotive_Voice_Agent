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
    7. 不知道的事情如实说不知道，不要编造。
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
    func latestFix() async -> LocationFix? {
        LocationFix(coordinate: DriveSettings.demoOrigin, horizontalAccuracyMeters: 10, timestamp: SystemClock().now)
    }
}

/// Applies AgentCore effects to the real provider, revoicer, playback and screen.
struct RuntimeSink: AgentEffectSink {
    let realtime: GeminiLiveProvider
    let config: SessionConfig
    let revoicer: Revoicer
    let audio: LiveAudio
    let model: DriveModel

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
    func speak(_ clause: String) async { await revoicer.speak(clause) }

    func publish(_ view: AgentViewState) async {
        await MainActor.run { model.view = view }
    }

    func diagnostic(_ event: DiagnosticEvent) {
        RuntimeLog.agent.notice("diagnostic \(String(describing: event), privacy: .public)")
    }
}

/// Vehicle tools, refreshing the car card after each call.
struct ObservedVehicleExecutor: ToolExecutor {
    let inner: VehicleToolExecutor
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
        await runtime.askCamera(call.arguments["question"]?.stringValue ?? "")
    }
}

/// The composition root (ios-architecture §4): one live session with every adapter wired.
@MainActor
final class AgentRuntime {
    let model = DriveModel()
    private var core: AgentCore?
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
        return CameraQuestionHandler(camera: camera, vision: vision, clock: SystemClock())
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
    func askCamera(_ question: String) async -> ToolResult {
        if !model.cameraOpen, !(await openCamera()) {
            return model.cameraDenied
                ? ToolDispatcher.failure(.cameraPermissionDenied)
                : ToolDispatcher.failure(.cameraUnavailable)
        }
        model.cameraAsking = true
        model.cameraAnswer = nil
        let result = await cameraQuestions.ask(question)
        if result.code != .superseded {
            model.cameraAsking = false
            model.cameraAnswer = result.data["answer"]?.stringValue
        }
        return result
    }

    /// Speaks a line in her voice while a session runs (set in `start()`, cleared in `stop()`).
    private var speakLine: (@Sendable (String) async -> Void)?

    /// 问一下: the fixed question. The answer shows as her bubble and on the window, and is spoken in her
    /// voice while a session runs; with no session it is shown only (F-20a §7 as amended).
    func tapAsk() async {
        let result = await askCamera(CameraQuestionHandler.tapQuestion)
        guard result.code != .superseded else { return }
        let line = result.data["answer"]?.stringValue
            ?? result.advice?.components(separatedBy: "请如实").first ?? "刚才没看清楚，再问我一次吧。"
        model.cameraAnswer = line
        model.view.subtitle = line
        await speakLine?(line)
    }

    func start() async {
        guard !model.running else { return }
        model.notice = nil
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
        let location = DemoLocation()
        let amapKey: @Sendable () -> String? = { try? KeychainCredentialStore().value(for: .amapWebKey) }
        let web = AmapWebClient(key: amapKey)
        let engine = AmapRouteEngine(key: amapKey, origin: { await location.latestFix()?.coordinate },
                                     onGeometry: { geometry in Task { @MainActor in model.geometry = geometry } })
        let flags = AsyncStream.makeStream(of: NavigationFlowState.self, bufferingPolicy: .bufferingNewest(16))
        let navigation = NavigationController(search: web, engine: engine, location: location, clock: SystemClock()) { snapshot in
            flags.continuation.yield(snapshot)
        }
        await navigation.start()
        let vehicleTools = ObservedVehicleExecutor(inner: VehicleToolExecutor(port: vehicle), vehicle: vehicle, model: model)
        let liveInfo = LiveInfoExecutor(navigation: navigation, weather: web, geocoder: web, location: location)
        var executors: [String: any ToolExecutor] = [:]
        for name in VehicleToolExecutor.tools { executors[name] = vehicleTools }
        for name in NavigationController.tools { executors[name] = navigation }
        executors["query_live_info"] = liveInfo
        executors["describe_camera_view"] = ObservedCameraExecutor(runtime: self)
        executors["place_call"] = PhoneCallHandler(contacts: ContactsStore(), dialer: SystemPhoneDialer(), clock: SystemClock())
        let settings = DefaultsSettingsStore()
        executors[SpeakingStyleHandler.tool] = SpeakingStyleHandler(settings: settings)
        // F-21: the saved tone is read once here, at session start.
        let instruction = PersonaInstruction.build(base: Persona.instruction, style: SpeakingStyle.saved(in: settings))
        // The live model closes 1007 "Thinking level is not supported for this model." for any level (fixture close1007).
        let config = SessionConfig(systemInstruction: instruction, tools: ToolCatalog.declarations, thinkingLevel: nil)
        let sink = RuntimeSink(realtime: provider, config: config, revoicer: revoicer, audio: audio, model: model)
        let core = AgentCore(clock: SystemClock(), sink: sink, tools: ToolRunner(executors: executors))
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
            for await event in audio.events { await core.send(.playback(event)) }
        })
        // Navigation: the guards' flags, the screen, and each guidance sentence spoken on the guidance lane.
        tasks.append(Task {
            var spoken: String?
            var overspeed = OverspeedMonitor(clock: SystemClock())
            for await snapshot in flags.stream {
                // F-17: one alert per exceedance, 10 s apart, on the guidance lane.
                if snapshot.navigating, let info = snapshot.info, let alert = overspeed.observe(info),
                   let pcm = try? await synthesizer.synthesize(alert, style: .default, deadline: .seconds(6)) {
                    audio.playGuidance(pcm, id: GuidanceID(UInt64(abs(alert.hashValue % 1_000_000))))
                }
                await MainActor.run { model.nav = snapshot }
                await core.send(.navigation(NavigationFlags(navigating: snapshot.navigating,
                                                            guidanceRunning: snapshot.navigating,
                                                            listOpen: snapshot.listOpen)))
                if snapshot.navigating, let text = snapshot.lastGuidance, text != spoken {
                    spoken = text
                    if let pcm = try? await synthesizer.synthesize(text, style: .default, deadline: .seconds(6)) {
                        audio.playGuidance(pcm, id: GuidanceID(UInt64(abs(text.hashValue % 1_000_000))))
                    }
                }
                if !snapshot.navigating { spoken = nil }
            }
        })
        // Uplink: the local gate decides what is sent and tells the core when the driver speaks.
        let gateEvents = AsyncStream.makeStream(of: UplinkGateOutput.self, bufferingPolicy: .bufferingNewest(512))
        let gate = GateBox()
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
        do {
            try audio.start { frame in
                for output in gate.process(frame) {
                    if case .audio(let frame) = output { provider.sendAudio(frame) } else { gateEvents.continuation.yield(output) }
                }
            }
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
        // F-20a §5: session stop closes the camera.
        if model.cameraOpen { closeCamera() }
        speakLine = nil
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
