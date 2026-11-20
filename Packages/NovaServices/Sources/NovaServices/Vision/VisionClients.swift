import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-20a §14 status mapping shared by every backend: 401/403 auth, 429/5xx busy, other non-200 failed.
enum VisionHTTP {
    enum Outcome {
        case success((Int, Data))
        case failure(VisionReply)
    }

    static func send(_ request: URLRequest, via transport: any HTTPTransport) async -> Outcome {
        do {
            let (status, data) = try await transport.send(request)
            return .success((status, data))
        } catch let error as URLError where error.code == .timedOut {
            return .failure(VisionReply(.busy, status: "timeout"))
        } catch {
            return .failure(VisionReply(.busy, status: Task.isCancelled ? "timeout" : "network"))
        }
    }

    /// F-18 §32 (T-046u): `send` behind the call budget. A refusal sends nothing and answers busy with
    /// `status=budget_<reason>` (codes only, I-8).
    static func send(_ request: URLRequest, via transport: any HTTPTransport, budget: CallBudget?, route: PaidRoute,
                     model: String, question: String, image: JPEGImage) async -> Outcome {
        guard let budget else { return await send(request, via: transport) }
        var h = Hasher()
        h.combine(image.data)
        let key = CallBudget.key(route, model: model, text: question + "|\(h.finalize())")
        if case .refuse(let r) = budget.ask(route, model: model, key: key) {
            return .failure(VisionReply(.busy, status: "budget_\(r.rawValue)"))
        }
        let outcome = await send(request, via: transport)
        switch outcome {
        case .success((let status, let data)):
            budget.done(route, model: model, ok: status == 200, tokens: CallBudget.reportedTokens(data),
                        quotaError: route == .geminiVision && QuotaError.gemini(status: status, body: data))
        case .failure:
            budget.done(route, model: model, ok: false, tokens: nil)
        }
        return outcome
    }

    /// The answer for a non-200 status, or nil for 200.
    static func failure(_ status: Int) -> VisionAnswer? {
        switch status {
        case 200: nil
        case 401, 403: .authFailed
        case 429, 500...599: .busy
        default: .failed
        }
    }
}

/// F-20a §14 item 2: Zhipu GLM-4.6V-Flash (free, hosted in China), OpenAI-style chat completions, thinking
/// off. The image is plain base64 as in Zhipu's example. Only codes and times reach logs (I-7, I-8).
public struct GLMVisionClient: VisionPort {
    public static let endpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
    public static let defaultModel = "glm-4.6v-flash"

    private let key: @Sendable () -> String?
    private let model: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval
    /// F-18 §32: the app passes `CallBudget.shared`.
    private let budget: CallBudget?

    /// `key` is read per request, so a key saved in 设置 works without a restart.
    public init(key: @escaping @Sendable () -> String?, model: String = defaultModel,
                transport: any HTTPTransport = URLSessionTransport(), timeout: NovaDuration = .seconds(8),
                budget: CallBudget? = nil) {
        self.budget = budget
        self.key = key
        self.model = model
        self.transport = transport
        self.timeout = Double(timeout.milliseconds) / 1000
    }

    public func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        await reply(question, image: image).answer
    }

    public func reply(_ question: String, image: JPEGImage) async -> VisionReply {
        guard let key = key(), !key.isEmpty, let url = URL(string: Self.endpoint) else {
            return VisionReply(.notConfigured, status: "-")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "thinking": ["type": "disabled"],
            "messages": [
                ["role": "system", "content": GeminiVisionClient.systemText],
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": Data(image.data).base64EncodedString()]],
                    ["type": "text", "text": question],
                ]],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let status: Int
        let data: Data
        switch await VisionHTTP.send(request, via: transport, budget: budget, route: .glmVision, model: model,
                                     question: question, image: image) {
        case .failure(let reply): return reply
        case .success(let ok): (status, data) = ok
        }
        if let failure = VisionHTTP.failure(status) { return VisionReply(failure, status: "\(status)") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        let text = Self.clean(message?["content"] as? String ?? "")
        return VisionReply(text.isEmpty ? .failed : .answer(text), status: "\(status)")
    }

    /// Trims and removes GLM's box markers.
    static func clean(_ content: String) -> String {
        content.replacingOccurrences(of: "<|begin_of_box|>", with: "")
            .replacingOccurrences(of: "<|end_of_box|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// F-20a vision backend (OQ-CAM-1): Gemini `generateContent` with one JPEG and the question,
/// same Keychain key as Live. Only status codes reach diagnostics; image and question never do (I-8).
public struct GeminiVisionClient: VisionPort {
    public static let host = "https://generativelanguage.googleapis.com"
    /// F-20a §14 item 5: a pinned GA model, never a `-latest` alias.
    public static let defaultModel = "gemini-3.5-flash-lite"
    static let systemText = "只根据图片回答，看不清就说看不清，不要猜。用一两句中文口语回答。"

    private let key: @Sendable () -> String?
    private let model: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval
    /// F-18 §32: the app passes `CallBudget.shared`.
    private let budget: CallBudget?

    /// `key` is read per request, so a key saved in 设置 works without a restart.
    public init(key: @escaping @Sendable () -> String?, model: String = defaultModel,
                transport: any HTTPTransport = URLSessionTransport(), timeout: NovaDuration = .seconds(8),
                budget: CallBudget? = nil) {
        self.budget = budget
        self.key = key
        self.model = model
        self.transport = transport
        self.timeout = Double(timeout.milliseconds) / 1000
    }

    public func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        await reply(question, image: image).answer
    }

    public func reply(_ question: String, image: JPEGImage) async -> VisionReply {
        guard let key = key(), !key.isEmpty,
              let url = URL(string: "\(Self.host)/v1beta/models/\(model):generateContent") else {
            return VisionReply(.notConfigured, status: "-")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Self.systemText]]],
            "contents": [["role": "user", "parts": [
                ["inline_data": ["mime_type": "image/jpeg", "data": Data(image.data).base64EncodedString()]],
                ["text": question],
            ]]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let status: Int
        let data: Data
        switch await VisionHTTP.send(request, via: transport, budget: budget, route: .geminiVision, model: model,
                                     question: question, image: image) {
        case .failure(let reply): return reply
        case .success(let ok): (status, data) = ok
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 400, let message = (json?["error"] as? [String: Any])?["message"] as? String,
           message.contains("API key") {
            return VisionReply(.authFailed, status: "400")
        }
        if let failure = VisionHTTP.failure(status) { return VisionReply(failure, status: "\(status)") }
        let candidate = (json?["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return VisionReply(text.isEmpty ? .failed : .answer(text), status: "200")
    }
}

/// F-20 Android parity backend: Qianfan chat completions with the image as a JPEG data URL
/// (contracts/api-contracts.md). `model` is passed in; the Android model name arrives by EVIDENCE_REQUEST.
public struct QianfanVisionClient: VisionPort {
    public static let endpoint = "https://qianfan.baidubce.com/v2/chat/completions"

    private let key: @Sendable () -> String?
    private let model: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    public init(key: @escaping @Sendable () -> String?, model: String,
                transport: any HTTPTransport = URLSessionTransport(), timeout: NovaDuration = .seconds(8)) {
        self.key = key
        self.model = model
        self.transport = transport
        self.timeout = Double(timeout.milliseconds) / 1000
    }

    public func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        await reply(question, image: image).answer
    }

    public func reply(_ question: String, image: JPEGImage) async -> VisionReply {
        guard let key = key(), !key.isEmpty, let url = URL(string: Self.endpoint) else {
            return VisionReply(.notConfigured, status: "-")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let dataURL = "data:image/jpeg;base64," + Data(image.data).base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": GeminiVisionClient.systemText],
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": dataURL]],
                    ["type": "text", "text": question],
                ]],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let status: Int
        let data: Data
        switch await VisionHTTP.send(request, via: transport) {
        case .failure(let reply): return reply
        case .success(let ok): (status, data) = ok
        }
        if let failure = VisionHTTP.failure(status) { return VisionReply(failure, status: "\(status)") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        let text = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VisionReply(text.isEmpty ? .failed : .answer(text), status: "200")
    }
}
