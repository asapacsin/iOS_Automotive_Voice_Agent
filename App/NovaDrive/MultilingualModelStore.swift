import CryptoKit
import Foundation
import NovaKit
import NovaVoice
import os

/// F-05a §14 item 1 (T-016l): downloads the SenseVoice model after install with a background `URLSession`, checks
/// each file's size and SHA-256, and installs it under `Application Support/SpeechModels/sensevoice-2024-07-17/`
/// (excluded from backup). The pure `MultilingualDownload` decides; this class runs its commands. Audio never leaves
/// the phone; only the model files are downloaded. Nothing here logs a path or a URL (I-8).
final class MultilingualModelStore: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = MultilingualModelStore()
    static let sessionID = "com.asapacsin.novadrive.multilingual-model"
    /// 设置 switch 「多语言识别（中文 / English / 日本語）」, on by default.
    static let switchKey = "multilingualASR"
    private static let verifiedMarker = ".verified"

    private let lock = NSLock()
    private var machine: MultilingualDownload
    private var watchers: [UUID: @Sendable (MultilingualModelState) -> Void] = [:]
    private var session: URLSession!
    /// Until the running tasks are adopted (after a relaunch), `start()` waits, so a download is never started twice.
    private var adopted = false
    private var startPending = false
    /// iOS's completion handler for background session events (`handleEventsForBackgroundURLSession`).
    private var backgroundDone: (() -> Void)?

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SpeechModels", isDirectory: true)
            .appendingPathComponent(MultilingualModel.folder, isDirectory: true)
    }
    private static var staging: URL {
        folder.deletingLastPathComponent().appendingPathComponent(".staging", isDirectory: true)
    }

    /// Both files in the folder with the right sizes, and the marker written after they passed the check.
    static var installed: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(verifiedMarker).path) else { return false }
        return MultilingualModel.files.allSatisfy { f in
            let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(f.name).path)[.size] as? NSNumber)?.int64Value
            return size == f.bytes
        }
    }

    static var switchOn: Bool { UserDefaults.standard.object(forKey: switchKey) as? Bool ?? true }

    private override init() {
        machine = MultilingualDownload(installed: Self.installed)
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        // A download still running from before a relaunch is adopted (`file|host|cellular`).
        session.getAllTasks { [self] tasks in
            var kept = false
            for task in tasks {
                let parts = (task.taskDescription ?? "").split(separator: "|").map(String.init)
                // One running task at most; anything else is cancelled.
                guard !kept, parts.count == 3, let host = Int(parts[1]) else { task.cancel(); continue }
                kept = true
                update { $0.adopt(file: parts[0], host: host, cellular: parts[2] == "1"); return [] }
            }
            let run = lock.withLock { () -> Bool in
                adopted = true
                return startPending
            }
            if run { start() }
        }
    }

    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        lock.withLock { backgroundDone = completion }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = lock.withLock { () -> (() -> Void)? in
            defer { backgroundDone = nil }
            return backgroundDone
        }
        if let done { Task { @MainActor in done() } }
    }

    var state: MultilingualModelState { lock.withLock { machine.state } }

    /// Calls `onChange` with each new state until the task is cancelled (one session's record).
    func watch(_ onChange: @escaping @Sendable (MultilingualModelState) -> Void) -> Task<Void, Never> {
        let id = UUID()
        lock.withLock { watchers[id] = onChange }
        return Task { [weak self] in
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            } onCancel: { self?.lock.withLock { _ = self?.watchers.removeValue(forKey: id) } }
        }
    }

    // MARK: actions (设置)

    /// App start and the switch turning on: with the model missing, start on Wi-Fi only (the session's requests
    /// do not use cellular or Low Data networks, so on cellular it waits). Then load it when ready.
    func start() {
        guard Self.switchOn else { return }
        let wait = lock.withLock { () -> Bool in
            if !adopted { startPending = true }
            return !adopted
        }
        guard !wait else { return }
        update { $0.switchOn(onWiFi: true) }
        if state == .ready { LocalSpeechModels.shared.loadMultilingual() }
    }

    /// 「用流量下载」.
    /// A Wi-Fi-only request still waiting is cancelled first, then the same file is fetched with cellular allowed.
    func useCellular() {
        guard !lock.withLock({ machine.allowsCellular && machine.currentFile != nil }) else { return }
        session.getAllTasks { [self] tasks in
            for task in tasks { task.taskDescription = "cancelled"; task.cancel() }
            update { $0.useCellular() }
        }
    }

    /// 「用流量下载」 shows while the model is missing, failed, or waiting for Wi-Fi.
    var offersCellular: Bool {
        lock.withLock {
            switch machine.state {
            case .missing, .failed: true
            case .downloading: !machine.allowsCellular
            case .ready, .loadFailed: false
            }
        }
    }

    /// 「下载失败，点按重试」.
    func retry() { update { $0.retry(onWiFi: true) } }

    /// The switch turned off: unload, keep the files.
    func switchOff() { LocalSpeechModels.shared.unloadMultilingual() }

    /// 「删除多语言模型」.
    func delete() {
        LocalSpeechModels.shared.unloadMultilingual()
        session.getAllTasks { tasks in tasks.forEach { $0.taskDescription = "cancelled"; $0.cancel() } }
        update { $0.delete() }
    }

    /// The files are ready but the model did not load (§14 item 2: 「加载失败」).
    func loadFailed() { update { $0.loadFailed(); return [] } }

    // MARK: machine

    private func update(_ step: (inout MultilingualDownload) -> [MultilingualDownload.Command]) {
        let (commands, before, host) = lock.withLock { () -> ([MultilingualDownload.Command], MultilingualModelState, Int) in
            let before = machine.state
            let commands = step(&machine)
            return (commands, before, machine.hostIndex)
        }
        // An install that fails resets the machine; the commands after it no longer apply.
        for command in commands {
            guard run(command, host: host) else { break }
        }
        let after = state
        guard after != before else { return }
        // Percent steps are not a state change for the record or the log.
        if case .downloading = before, case .downloading = after { notifyView(after); return }
        RuntimeLog.agent.notice("asrMulti state=\(after.code, privacy: .public)")
        let targets = lock.withLock { Array(watchers.values) }
        targets.forEach { $0(after) }
        notifyView(after)
        if after == .ready && Self.switchOn { LocalSpeechModels.shared.loadMultilingual() }
    }

    private func notifyView(_ state: MultilingualModelState) {
        Task { @MainActor in NotificationCenter.default.post(name: .multilingualModelState, object: nil) }
    }

    /// false: the install failed and the machine was reset.
    @discardableResult
    private func run(_ command: MultilingualDownload.Command, host: Int) -> Bool {
        let fm = FileManager.default
        switch command {
        case .fetch(let url, let file, let cellular):
            guard let url = URL(string: url) else { return true }
            var request = URLRequest(url: url)
            request.allowsExpensiveNetworkAccess = cellular
            request.allowsConstrainedNetworkAccess = cellular
            request.allowsCellularAccess = true
            let task = session.downloadTask(with: request)
            task.taskDescription = "\(file)|\(host)|\(cellular ? "1" : "0")"
            task.resume()
        case .discard(let file):
            try? fm.removeItem(at: Self.staging.appendingPathComponent(file))
        case .install(let file):
            do {
                try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                var folder = Self.folder
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? folder.setResourceValues(values)
                let target = Self.folder.appendingPathComponent(file)
                try? fm.removeItem(at: target)
                try fm.moveItem(at: Self.staging.appendingPathComponent(file), to: target)
                if MultilingualModel.files.allSatisfy({ fm.fileExists(atPath: Self.folder.appendingPathComponent($0.name).path) }) {
                    fm.createFile(atPath: Self.folder.appendingPathComponent(Self.verifiedMarker).path, contents: Data())
                }
            } catch {
                // A file that cannot be moved into place counts as a failed download (nothing half-installed loads).
                RuntimeLog.agent.error("asrMulti state=install_failed")
                try? fm.removeItem(at: Self.folder.appendingPathComponent(Self.verifiedMarker))
                lock.withLock {
                    machine = MultilingualDownload(installed: false)
                    _ = machine.markFailed()
                }
                return false
            }
        case .removeAll:
            try? fm.removeItem(at: Self.folder)
            try? fm.removeItem(at: Self.staging)
        }
        return true
    }

    /// SHA-256 of a file in 1 MB pieces (lower-case hex).
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update { $0.progress(received: totalBytesWritten); return [] }
    }

    /// The temporary file is gone when this returns: it is moved to staging and checked here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let name = (downloadTask.taskDescription ?? "").split(separator: "|").first.map(String.init) ?? ""
        // A cancelled or stale task (not the file the machine waits for) is not checked against it.
        guard name == lock.withLock({ machine.currentFile }) else { return }
        let fm = FileManager.default
        let staged = Self.staging.appendingPathComponent(name)
        guard status == 200, !name.isEmpty,
              (try? fm.createDirectory(at: Self.staging, withIntermediateDirectories: true)) != nil else {
            return update { $0.failed() }
        }
        try? fm.removeItem(at: staged)
        guard (try? fm.moveItem(at: location, to: staged)) != nil else { return update { $0.failed() } }
        let size = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? -1
        let sha = Self.sha256(of: staged) ?? ""
        update { $0.finished(size: size, sha256: sha) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        // A cancel from 「删除多语言模型」 is not a failure.
        if (error as? URLError)?.code == .cancelled || task.taskDescription == "cancelled" { return }
        let name = (task.taskDescription ?? "").split(separator: "|").first.map(String.init)
        guard name == lock.withLock({ machine.currentFile }) else { return }
        update { $0.failed() }
    }
}

extension Notification.Name {
    static let multilingualModelState = Notification.Name("NovaDrive.multilingualModelState")
}
