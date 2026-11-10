import Foundation
import NovaAgent
import NovaAudio
import NovaServices
import NovaTools

/// F-13a (T-032g): the app's one volume executor, shared by `set_volume` and the 设置 sliders (I-6). It lives as long
/// as the app, so a slider applies with or without a session; a session attaches its engine to `output`.
final class AppVolume: Sendable {
    static let shared = AppVolume()

    let output: LaneVolume
    /// The running session's record (§7: the record gets the same line as RuntimeLog); nil without one.
    let records: VolumeRecordBox
    let controller: VolumeController

    private init() {
        let output = LaneVolume()
        let records = VolumeRecordBox()
        self.output = output
        self.records = records
        controller = VolumeController(store: DefaultsSettingsStore(), output: output) { line in
            // §7, I-8: numbers and codes only.
            RuntimeLog.agent.notice("\(line, privacy: .public)")
            records.record?.submit(.volume(line))
        }
    }
}

final class VolumeRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _record: ConversationRecord?
    var record: ConversationRecord? {
        get { lock.withLock { _record } }
        set { lock.withLock { _record = newValue } }
    }
}
