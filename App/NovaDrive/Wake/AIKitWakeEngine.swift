import Foundation
import NovaKit
import NovaPorts
import NovaVoice
#if canImport(AIKIT)
import AIKIT
#endif

/// T-060 iFlytek AIKit wake word (`AIKit-语音唤醒` iOS v1.0.13, ability `e867a88f2`), app
/// NovaDrive车载助手. The SDK is licensed and device-only (arm64, no simulator slice), so it is not in
/// the public repo: `scripts/vendor_aikit.sh <sdk.zip>` puts it in `App/Vendor/AIKit/`, and only a
/// device build with it present compiles the AIKit path. Otherwise `start` throws and
/// `RetryingWakeDetector` reports `.unavailable` after its bounded retries; the talk button stays.
/// Flow as in the SDK demo (`IVWEngine.m`): initSDK → loadData(key_word) → specifyDataSet → start →
/// write/read per frame → end. In-app wake only (OQ-IOS-1).
final class AIKitWakeEngine: NSObject, WakeEngine, @unchecked Sendable {
    enum Failure: Error { case sdkMissing, notConfigured, code(Int) }

    static let abilityID = "e867a88f2"
    /// The wake phrase (F-01). AIKit takes it as text; no `.jet` model is needed.
    static let keyword = "你好小诺"
    /// AIKit score threshold, `<file> <word>:<score>`; 900 is the SDK demo default (PROPOSED, tune on device).
    static let threshold = "0 0:900"

    static var sdkLinked: Bool {
        #if canImport(AIKIT)
        true
        #else
        false
        #endif
    }

    private let credentials: any CredentialStore
    private let lock = NSLock()
    private var onEvent: (@Sendable (WakeEngineEvent) -> Void)?
    private var sdkReady = false
    #if canImport(AIKIT)
    private var handle: AiHandle?
    private var first = true
    #endif

    init(credentials: any CredentialStore) { self.credentials = credentials }

    func start(onEvent: @escaping @Sendable (WakeEngineEvent) -> Void) async throws {
        guard let appID = try? credentials.value(for: .iflytekAppID), !appID.isEmpty,
              let apiKey = try? credentials.value(for: .iflytekAPIKey), !apiKey.isEmpty,
              let apiSecret = try? credentials.value(for: .iflytekAPISecret), !apiSecret.isEmpty else {
            throw Failure.notConfigured
        }
        #if canImport(AIKIT)
        try lock.withLock {
            if !sdkReady {
                let code = ILibrary.initSDK { maker in
                    _ = maker.appId(appID).apiKey(apiKey).apiSecret(apiSecret).ability(Self.abilityID)
                }
                guard code == 0 else { throw Failure.code(Int(code)) }
                sdkReady = true
            }
            let words = AIKITCustomData()
            words.addText(Self.keyword + ";", key: "key_word", index: 0)
            var code = AiHelper.loadData(Self.abilityID, data: words)
            guard code == 0 else { throw Failure.code(Int(code)) }
            var indexes: [Int32] = [0]
            code = indexes.withUnsafeMutableBufferPointer {
                AiHelper.specifyDataSet(Self.abilityID, key: "key_word", indexs: $0.baseAddress!, count: 1)
            }
            guard code == 0 else { throw Failure.code(Int(code)) }
            let params = AIKITParameters()
            params.addString("wdec_param_nCmThreshold", value: Self.threshold)
            params.addBool("gramLoad", value: true)
            let started = AiHelper.start(Self.abilityID, param: params, ctxContent: nil)
            guard started.isSuccess() else { throw Failure.code(started.code) }
            AiHelper.registerAbilityCallback(Self.abilityID, callback: self)
            handle = started
            first = true
            self.onEvent = onEvent
        }
        #else
        _ = (appID, apiKey, apiSecret, onEvent)
        throw Failure.sdkMissing
        #endif
    }

    /// One 10 ms frame (16 kHz mono s16le), the format the SDK demo writes.
    func write(_ frame: PCMFrame16k) {
        #if canImport(AIKIT)
        let failed: Bool = lock.withLock {
            guard let handle else { return false }
            let bytes = frame.samples.withUnsafeBufferPointer { Data(buffer: $0) }
            let input = AIKITInputData()
            input.addAudio(bytes, key: "wav", status: first ? DataStatusBegin : DataStatusContinue)
            first = false
            return AiHelper.write(input, handle: handle) != 0 || AiHelper.read(handle) != 0
        }
        if failed { lock.withLock { onEvent }?(.failed) }
        #endif
    }

    func stop() async {
        #if canImport(AIKIT)
        lock.withLock {
            if let handle { _ = AiHelper.end(handle) }
            handle = nil
            onEvent = nil
        }
        #endif
    }
}

#if canImport(AIKIT)
extension AIKitWakeEngine: AIKitCoreDelegate {
    func aikitOnResult(_ ability: String, handleId: Int, outputData data: [AIKITDataModel], usrCtx context: AIKITCtxContent) {
        lock.withLock { onEvent }?(.detected)
    }

    func aikitOnEvent(_ ability: String, handleId: Int, event: Int, eventData data: [AIKITDataModel], usrCtx context: AIKITCtxContent) {
        // 3 = timeout: the session ended without a wake; restart through the bounded retry.
        if event == 3 { lock.withLock { onEvent }?(.failed) }
    }

    func aikitOnError(_ ability: String, handleId: Int, error: AIKITError, usrCtx context: AIKITCtxContent) {
        lock.withLock { onEvent }?(.failed)
    }
}
#endif
