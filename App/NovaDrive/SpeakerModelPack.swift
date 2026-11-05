#if canImport(BackgroundAssets)
import BackgroundAssets
#endif
import CryptoKit
import Foundation
import NovaAsrSherpa
import NovaVoice

/// F-04b §12 (T-013f): finds the speaker model. Debug builds keep it in the bundle; App Store / TestFlight builds get
/// it as the Apple-hosted asset pack `SpeakerModelPin.assetPackID`, which iOS downloads at install (essential policy).
/// Nothing is loaded here; only the directory and its state are found. The pack's model is hashed once per app run.
final class SpeakerModelLocator: @unchecked Sendable {
    static let shared = SpeakerModelLocator()
    /// Posted on the main queue when `availability` changes.
    static let changed = Notification.Name("SpeakerModelLocator.changed")

    private let lock = NSLock()
    private var packState: SpeakerPackState
    private var packDirectory: URL?
    private var running = false

    /// `SherpaModels/speaker` in the bundle, when it holds a model (stripped from Release builds).
    static var bundleDirectory: URL? {
        let dir = Bundle.main.url(forResource: "SherpaModels", withExtension: nil)?
            .appendingPathComponent("speaker", isDirectory: true)
        return SherpaSpeakerVerifier.modelPresent(in: dir) ? dir : nil
    }

    private init() {
        if #available(iOS 26, *) { packState = .downloading } else { packState = .unsupportedSystem }
    }

    var availability: SpeakerModelAvailability {
        let state = lock.withLock { packState }
        return SpeakerModelAvailability.resolve(bundlePresent: Self.bundleDirectory != nil, pack: state)
    }

    /// The directory to load from, or nil while the model is not usable (§12 item 3).
    var directory: URL? {
        switch availability {
        case .bundle: Self.bundleDirectory
        case .pack: lock.withLock { packDirectory }
        default: nil
        }
    }

    /// Called at launch and by 重试: asks the system for the pack (waits while it downloads), then checks it.
    func refresh() {
        guard Self.bundleDirectory == nil else { return }
        #if canImport(BackgroundAssets)
        if #available(iOS 26, *) {
            let start = lock.withLock { () -> Bool in
                if running { return false }
                running = true
                if case .downloaded(let h) = packState, h.map(SpeakerModelPin.matches) == true { running = false; return false }
                packState = .downloading
                return true
            }
            guard start else { return }
            post()
            Task.detached(priority: .utility) { await self.fetchPack() }
        }
        #endif
    }

    #if canImport(BackgroundAssets)
    @available(iOS 26, *)
    private func fetchPack() async {
        var state = SpeakerPackState.failed
        var dir: URL?
        do {
            let manager = AssetPackManager.shared
            let pack = try await manager.assetPack(withID: SpeakerModelPin.assetPackID)
            try await manager.ensureLocalAvailability(of: pack)
            let manifest = try manager.url(for: "speaker/speaker.json")
            let folder = manifest.deletingLastPathComponent()
            let hash = Self.sha256(of: folder.appendingPathComponent(SpeakerModelPin.modelFile))
            state = .downloaded(sha256: hash)
            dir = folder
        } catch {
            state = .failed
        }
        lock.withLock {
            packState = state
            packDirectory = dir
            running = false
        }
        post()
    }
    #endif

    private func post() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// Streams the file in 1 MB chunks; nil when it cannot be read.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20) else { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
