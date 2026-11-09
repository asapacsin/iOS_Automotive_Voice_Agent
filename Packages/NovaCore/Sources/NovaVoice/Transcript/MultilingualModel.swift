import NovaKit

/// F-05a §14 item 1 (T-016l): the SenseVoice model downloaded after install, and its download as a pure state
/// machine. The App's `URLSession` runs the commands and reports back; checksums are computed there and come in
/// as values. Nothing that fails the check is ever installed.
public enum MultilingualModel {
    public struct File: Sendable, Hashable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
    }

    /// §14 Sources, checked 2026-11-09.
    public static let repo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    public static let revision = "2365baeacb507f821a0c8120fcee3d484dba7a07"
    public static let files = [
        File(name: "model.int8.onnx", bytes: 239_233_841, sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
        File(name: "tokens.txt", bytes: 315_894, sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
    ]
    /// Under `Application Support/SpeechModels/`.
    public static let folder = "sensevoice-2024-07-17"
    /// Hugging Face first; the same path on hf-mirror.com when it fails or times out.
    public static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]
    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    public static func url(host: String, file: String) -> String { "\(host)/\(repo)/resolve/\(revision)/\(file)" }
}

/// §14 item 1: the 设置 state under the switch.
public enum MultilingualModelState: Sendable, Hashable {
    case missing
    case downloading(percent: Int)
    case ready
    case failed
    /// §14 item 2: the files are there but the model did not load.
    case loadFailed

    public var label: String {
        switch self {
        case .missing: "未下载（约 240 MB）"
        case .downloading(let p): "下载中 \(p)%"
        case .ready: "已就绪"
        case .failed: "下载失败，点按重试"
        case .loadFailed: "加载失败"
        }
    }

    /// For the record's `asr-model state=<…>` and `RuntimeLog` (no words, I-8).
    public var code: String {
        switch self {
        case .missing: "missing"
        case .downloading: "downloading"
        case .ready: "ready"
        case .failed: "failed"
        case .loadFailed: "load_failed"
        }
    }
}

public struct MultilingualDownload: Sendable, Hashable {
    public enum Command: Sendable, Hashable {
        /// Download `file` from `url`; `cellular` false is Wi-Fi only (`allowsExpensiveNetworkAccess` and
        /// `allowsConstrainedNetworkAccess` false).
        case fetch(url: String, file: String, cellular: Bool)
        /// Delete the temporary file (it failed the check, or the download stopped).
        case discard(file: String)
        /// Move the checked file into the model folder (excluded from backup).
        case install(file: String)
        /// 「删除多语言模型」: remove the model folder.
        case removeAll
    }

    public private(set) var state: MultilingualModelState
    private var host = 0
    private var file = 0
    private var cellular = false
    private var finishedBytes: Int64 = 0

    /// `installed`: both files are already in the model folder, checked (they stay across updates and reinstalls).
    public init(installed: Bool) { state = installed ? .ready : .missing }

    private var active: Bool { if case .downloading = state { true } else { false } }

    /// The switch is on: with the model missing, the download starts by itself on Wi-Fi only.
    public mutating func switchOn(onWiFi: Bool) -> [Command] {
        guard state == .missing, onWiFi else { return [] }
        return start(cellular: false)
    }

    /// 「用流量下载」, or 「下载失败，点按重试」 tapped: starts on any network (the retry keeps Wi-Fi only unless asked).
    /// While a Wi-Fi-only request waits (on cellular it never starts), the tap replaces it: the App cancels the
    /// waiting request first.
    public mutating func useCellular() -> [Command] {
        guard state != .ready, state != .loadFailed, !(active && cellular) else { return [] }
        return start(cellular: true)
    }

    /// Whether the current request may use cellular (「用流量下载」 is shown while it may not).
    public var allowsCellular: Bool { cellular }

    /// The file the current request fetches; a finished download of any other file is not this one.
    public var currentFile: String? { active ? MultilingualModel.files[file].name : nil }

    public mutating func retry(onWiFi: Bool) -> [Command] {
        guard state == .failed, onWiFi else { return [] }
        return start(cellular: false)
    }

    private mutating func start(cellular: Bool) -> [Command] {
        host = 0
        file = 0
        finishedBytes = 0
        self.cellular = cellular
        state = .downloading(percent: 0)
        return [fetch()]
    }

    private func fetch() -> Command {
        let f = MultilingualModel.files[file]
        return .fetch(url: MultilingualModel.url(host: MultilingualModel.hosts[host], file: f.name), file: f.name, cellular: cellular)
    }

    /// After a relaunch: a background download of `file` from host `host` is still running; earlier files are
    /// already installed. An unknown file or host leaves the state as it is.
    public mutating func adopt(file name: String, host: Int, cellular: Bool) {
        guard let index = MultilingualModel.files.firstIndex(where: { $0.name == name }),
              MultilingualModel.hosts.indices.contains(host), state != .ready else { return }
        file = index
        self.host = host
        self.cellular = cellular
        finishedBytes = MultilingualModel.files[..<index].reduce(0) { $0 + $1.bytes }
        state = .downloading(percent: 0)
        progress(received: 0)
    }

    /// The host index of the current request (for the task's description, to adopt it after a relaunch).
    public var hostIndex: Int { host }

    /// Bytes received of the current file.
    public mutating func progress(received: Int64) {
        guard active else { return }
        let done = finishedBytes + min(max(received, 0), MultilingualModel.files[file].bytes)
        state = .downloading(percent: Int(done * 100 / MultilingualModel.totalBytes))
    }

    /// The current file arrived: checked against its size and SHA-256 (lower-case hex).
    public mutating func finished(size: Int64, sha256: String) -> [Command] {
        guard active else { return [] }
        let f = MultilingualModel.files[file]
        guard size == f.bytes, sha256.lowercased() == f.sha256 else {
            state = .failed
            return [.discard(file: f.name)]
        }
        finishedBytes += f.bytes
        file += 1
        guard file < MultilingualModel.files.count else {
            state = .ready
            return [.install(file: f.name)]
        }
        progress(received: 0)
        return [.install(file: f.name), fetch()]
    }

    /// The current request failed or timed out: the same path on the mirror, then 「下载失败，点按重试」.
    public mutating func failed() -> [Command] {
        guard active else { return [] }
        let name = MultilingualModel.files[file].name
        if host + 1 < MultilingualModel.hosts.count {
            host += 1
            return [.discard(file: name), fetch()]
        }
        state = .failed
        return [.discard(file: name)]
    }

    /// A checked file could not be moved into the model folder: 「下载失败，点按重试」.
    public mutating func markFailed() -> [Command] {
        state = .failed
        return []
    }

    /// The files are ready but the model did not load.
    public mutating func loadFailed() {
        if state == .ready { state = .loadFailed }
    }

    /// 「删除多语言模型」.
    public mutating func delete() -> [Command] {
        state = .missing
        return [.removeAll]
    }
}
