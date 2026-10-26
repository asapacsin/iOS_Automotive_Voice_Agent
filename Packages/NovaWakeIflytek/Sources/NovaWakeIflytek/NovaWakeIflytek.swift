import NovaKit
import NovaPorts
import NovaVoice

/// iFlytek AIKit wake word (T-060, F-01). App: NovaDrive车载助手, APPID entered in 设置 (a7f534f1);
/// SDK: AIKit-语音唤醒 iOS (`iOS_ivw_v1-0-13_v2-2-15-rc6`), placed under `Vendor/` by the owner.
/// In-app wake only (OQ-IOS-1): it listens only while the app runs.
public struct IflytekWakeConfig: Sendable, Hashable {
    public var appID: String
    public var apiKey: String
    public var apiSecret: String
    /// Detection threshold, as on Android (`0:1450`).
    public var threshold = "0:1450"

    public init(appID: String, apiKey: String, apiSecret: String) {
        self.appID = appID
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }
}

/// `WakeEngine` over AIKit. Until the SDK is in `Vendor/`, `start` throws `sdkMissing`, so
/// `RetryingWakeDetector` reports `.unavailable` after its bounded retries and the talk button stays the
/// way to start a conversation.
public final class IflytekWakeEngine: WakeEngine {
    public enum Failure: Error, Sendable { case sdkMissing, notConfigured }

    private let config: IflytekWakeConfig

    public init(config: IflytekWakeConfig) { self.config = config }

    public static var sdkLinked: Bool {
        #if canImport(AIKit)
        true
        #else
        false
        #endif
    }

    public func start(onEvent: @escaping @Sendable (WakeEngineEvent) -> Void) async throws {
        guard !config.appID.isEmpty else { throw Failure.notConfigured }
        // AIKit calls go here once the SDK is vendored (init with appID/apiKey/apiSecret, load the ivw
        // resource and keyword, start, wake callback → .detected, errors → .failed).
        throw Failure.sdkMissing
    }

    public func write(_ frame: PCMFrame16k) {}

    public func stop() async {}
}

/// The wake detector the app arms: AIKit behind the bounded-retry controller.
public enum IflytekWake {
    public static func detector(config: IflytekWakeConfig, clock: any NovaClock) -> RetryingWakeDetector {
        RetryingWakeDetector(engine: IflytekWakeEngine(config: config), clock: clock)
    }
}
