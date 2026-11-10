import Foundation

/// F-05a §16 item 3 (T-016n): SenseVoice and its download are removed. On the first launch of this version its model
/// folder and any partial download are deleted once, in the background, and the freed bytes go to the next record as
/// `asr-model removed bytes=<n>`. No path or URL is logged (I-8).
enum SenseVoiceRemoval {
    /// Set once the removal ran; it never runs again.
    static let doneKey = "senseVoiceRemoved"
    /// Bytes freed, waiting for the next record (cleared when written).
    static let pendingKey = "senseVoiceRemovedBytes"
    /// The old downloader's settings and background session (T-016l).
    static let oldSwitchKey = "multilingualASR"
    static let oldSessionID = "com.asapacsin.novadrive.multilingual-model"

    /// `Application Support/SpeechModels`: the model folder `sensevoice-2024-07-17/` and the `.staging` partial files.
    static var speechModels: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechModels", isDirectory: true)
    }

    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        DispatchQueue.global(qos: .utility).async {
            // A download still queued in the old background session is cancelled, so nothing lands afterwards.
            URLSession(configuration: .background(withIdentifier: oldSessionID)).invalidateAndCancel()
            let fm = FileManager.default
            var bytes: Int64 = 0
            for name in ["sensevoice-2024-07-17", ".staging"] {
                let url = speechModels.appendingPathComponent(name, isDirectory: true)
                guard fm.fileExists(atPath: url.path) else { continue }
                bytes += size(of: url, fm)
                try? fm.removeItem(at: url)
            }
            // The SpeechModels folder held only SenseVoice; remove it when empty.
            if (try? fm.contentsOfDirectory(atPath: speechModels.path))?.isEmpty == true {
                try? fm.removeItem(at: speechModels)
            }
            UserDefaults.standard.removeObject(forKey: oldSwitchKey)
            UserDefaults.standard.set(NSNumber(value: bytes), forKey: pendingKey)
            RuntimeLog.agent.notice("asr-model removed bytes=\(bytes, privacy: .public)")
        }
    }

    /// The freed bytes for the record, once: nil when there is nothing to report (or it was already written).
    static func takePending() -> Int64? {
        let defaults = UserDefaults.standard
        guard let n = defaults.object(forKey: pendingKey) as? NSNumber else { return nil }
        defaults.removeObject(forKey: pendingKey)
        return n.int64Value
    }

    private static func size(of folder: URL, _ fm: FileManager) -> Int64 {
        guard let items = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
