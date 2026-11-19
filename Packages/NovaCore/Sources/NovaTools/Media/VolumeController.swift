import Synchronization
import NovaKit
import NovaPorts

/// F-13a §4 item 1: what `set_volume` asks for.
public enum VolumeAction: String, Sendable, Hashable, CaseIterable {
    case up, down, set, mute, max
}

/// F-13a §7: who changed the level. A tap on the 设置 slider and the tool run the same executor (I-6).
public enum VolumeSource: String, Sendable, Hashable {
    case tool, settings
}

/// One change of a level, decided in code (I-1, I-14): the result and the announce come only from here.
public struct VolumeChange: Sendable, Hashable {
    public let target: VolumeTarget
    public let action: VolumeAction
    public let previous: Int
    public let level: Int
    /// §4 item 5: the level is at the end in the asked direction (it cannot go further that way), or the ask was
    /// refused or clamped at the voice floor (§3 item 2).
    public let limitReached: Bool
    /// The asked `set` value was below the voice floor and was raised to it.
    public let clamped: Bool

    /// §4 item 2: `up` / `down` by 2 (1 within 1 of the end), `set` to `value`, `mute` 0 for media (refused for
    /// voice), `max` 10.
    public static func decide(_ target: VolumeTarget, _ action: VolumeAction, value: Int?, from previous: Int) -> VolumeChange {
        let range = target.range
        let step = 2
        var level = previous
        var clamped = false
        let limit: Bool
        switch action {
        case .up:
            level = target.clamp(previous + step)
            limit = level == range.upperBound
        case .max:
            level = range.upperBound
            limit = true
        case .down:
            level = target.clamp(previous - step)
            limit = level == range.lowerBound
        case .mute:
            // §3 item 2, §4 item 2: her voice is never silenced; the level stays.
            if target == .voice { return VolumeChange(target, action, previous, previous, limit: true, clamped: false) }
            level = range.lowerBound
            limit = true
        case .set:
            let asked = value ?? previous
            level = target.clamp(asked)
            clamped = level != asked
            limit = clamped || asked > previous && level == range.upperBound || asked < previous && level == range.lowerBound
        }
        return VolumeChange(target, action, previous, level, limit: limit, clamped: clamped)
    }

    private init(_ target: VolumeTarget, _ action: VolumeAction, _ previous: Int, _ level: Int, limit: Bool, clamped: Bool) {
        self.target = target
        self.action = action
        self.previous = previous
        self.level = level
        self.limitReached = limit
        self.clamped = clamped
    }

    /// Towards louder (`up`, `max`, a `set` above the old level).
    var louder: Bool {
        switch action {
        case .up, .max: true
        case .down, .mute: false
        case .set: level > previous
        }
    }

    /// §3 item 4: below this phone volume the answer at 10 points to the side buttons.
    public static let lowPhoneVolume = 0.5

    /// §4 item 5: her one line, built in code. `phoneVolume` is `AVAudioSession.outputVolume` (nil when unknown).
    public func announce(phoneVolume: Double?) -> String {
        var text: String
        if target == .voice && action == .mute && level > target.minimum {
            text = "我说话的声音不能关掉，最小可以调到 \(target.minimum)"
        } else if limitReached && level == previous {
            text = louder ? "已经是最大了" : "已经是最小了"
        } else {
            text = (target == .media ? "音乐音量调到 \(level) 了" : "我说话的声音调到 \(level) 了")
            if clamped { text += "，不能再小了" }
        }
        if limitReached, level == VolumeLevels.maximum, let phoneVolume, phoneVolume < Self.lowPhoneVolume {
            text += "，可以按手机侧面的音量键再调大"
        }
        return text
    }

    /// §7: `volume set target=<media|voice> from=<n> to=<n> by=tool|settings limit=<bool>`. Numbers and codes only (I-8).
    public func line(by source: VolumeSource) -> String {
        "volume set target=\(target.rawValue) from=\(previous) to=\(level) by=\(source.rawValue) limit=\(limitReached)"
    }

    /// §4 item 5: the tool result. Always ok for a valid call; the end of the range is `limit_reached`.
    public func result(phoneVolume: Double?) -> ToolResult {
        let announce = announce(phoneVolume: phoneVolume)
        return .success([
            "target": .string(target.rawValue),
            "level": .int(Int64(level)),
            "previous": .int(Int64(previous)),
            "limit_reached": .bool(limitReached),
            "announce": .string(announce),
            "next": .string("只说这一句：" + announce),
        ])
    }
}

/// F-13a §3–§4, §6: the one volume executor. `set_volume` and the 设置 sliders both call it (I-6). Each change is
/// saved through the store, applied to the lanes before the result is returned (§4 item 5), and written as a §7 line.
public final class VolumeController: ToolExecutor {
    public static let tool = "set_volume"

    private let state: Mutex<VolumeLevels>
    private let store: any SettingsStore
    private let output: any VolumeOutput
    private let onLine: @Sendable (String) -> Void

    /// Reads the saved levels and applies them at once (§8 row 4: the same level at start).
    public init(store: any SettingsStore, output: any VolumeOutput, onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        let saved = VolumeLevels.saved(in: store)
        state = Mutex(saved)
        self.store = store
        self.output = output
        self.onLine = onLine
        output.apply(saved)
    }

    public var levels: VolumeLevels { state.withLock { $0 } }

    /// Changes one level. Saved and applied inside the lock, so a slider and a tool call never interleave.
    @discardableResult
    public func change(_ target: VolumeTarget, _ action: VolumeAction, value: Int? = nil, by source: VolumeSource) -> VolumeChange {
        let change = state.withLock { levels in
            let change = VolumeChange.decide(target, action, value: value, from: levels[target])
            if change.level != change.previous {
                levels[target] = change.level
                levels.save(target, in: store)
            }
            output.apply(levels)
            return change
        }
        onLine(change.line(by: source))
        return change
    }

    /// §6: a 设置 slider moved to `level`.
    @discardableResult
    public func slider(_ target: VolumeTarget, to level: Int) -> VolumeChange {
        change(target, .set, value: level, by: .settings)
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        // The dispatcher validated the call (ToolCatalog `set_volume`); this is the same check, never trusted blind.
        guard let target = call.arguments["target"]?.stringValue.flatMap(VolumeTarget.init(rawValue:)),
              let action = call.arguments["action"]?.stringValue.flatMap(VolumeAction.init(rawValue:)) else {
            return ToolDispatcher.failure(.invalidFieldValue)
        }
        let value: Int? = switch call.arguments["value"] {
        case .int(let v): Int(exactly: v)
        case .double(let v): Int(exactly: v)
        default: nil
        }
        if action == .set && value == nil { return ToolDispatcher.failure(.missingValue) }
        return change(target, action, value: value, by: .tool).result(phoneVolume: output.phoneVolume)
    }
}
