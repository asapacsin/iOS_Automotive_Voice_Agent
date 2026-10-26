import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-20a default vision backend (OQ-CAM-1): Gemini `generateContent` with one JPEG and the question,
/// same Keychain key as Live. Only status codes reach diagnostics; image and question never do (I-8).
public struct GeminiVisionClient: VisionPort {
    public static let host = "https://generativelanguage.googleapis.com"
    public static let defaultModel = "gemini-flash-latest"
    static let systemText = "只根据图片回答，看不清就说看不清，不要猜。用一两句中文口语回答。"

    private let key: @Sendable () -> String?
    private let model: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    /// `key` is read per request, so a key saved in 设置 works without a restart.
    public init(key: @escaping @Sendable () -> String?, model: String = defaultModel,
                transport: any HTTPTransport = URLSessionTransport(), timeout: NovaDuration = .seconds(8)) {
        self.key = key
        self.model = model
        self.transport = transport
        self.timeout = Double(timeout.milliseconds) / 1000
    }

    public func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        guard let key = key(), !key.isEmpty,
              let url = URL(string: "\(Self.host)/v1beta/models/\(model):generateContent") else { return .notConfigured }
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
        guard let (status, data) = try? await transport.send(request) else { return .failed }
        if status == 401 || status == 403 { return .authFailed }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 400, let message = (json?["error"] as? [String: Any])?["message"] as? String,
           message.contains("API key") {
            return .authFailed
        }
        let candidate = (json?["candidates"] as? [[String: Any]])?.first
        guard status == 200,
              let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return .failed }
        let text = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failed : .answer(text)
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
        guard let key = key(), !key.isEmpty, let url = URL(string: Self.endpoint) else { return .notConfigured }
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
        guard let (status, data) = try? await transport.send(request) else { return .failed }
        if status == 401 || status == 403 { return .authFailed }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200,
              let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return .failed }
        return .answer(text)
    }
}

/// Picks the backend per request (OQ-CAM-1): Gemini when its key is saved, else Qianfan when that key
/// is saved, else `notConfigured`.
public struct PreferredVision: VisionPort {
    private let gemini: GeminiVisionClient
    private let qianfan: QianfanVisionClient?
    private let hasGeminiKey: @Sendable () -> Bool

    public init(gemini: GeminiVisionClient, qianfan: QianfanVisionClient?,
                hasGeminiKey: @escaping @Sendable () -> Bool) {
        self.gemini = gemini
        self.qianfan = qianfan
        self.hasGeminiKey = hasGeminiKey
    }

    public func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        if hasGeminiKey() { return await gemini.ask(question, image: image) }
        return await qianfan?.ask(question, image: image) ?? .notConfigured
    }
}
