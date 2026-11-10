import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaTools

/// UserDefaults stand-in.
final class VolumeMemoryStore: SettingsStore {
    let values = Mutex<[String: String]>([:])
    init(_ initial: [String: String] = [:]) { values.withLock { $0 = initial } }
    func string(_ key: String) -> String? { values.withLock { $0[key] } }
    func bool(_ key: String) -> Bool? { nil }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
    func set(_ value: Bool, for key: String) {}
}

/// Records every applied pair of lane gains.
final class RecordingVolumeOutput: VolumeOutput {
    let applied = Mutex<[VolumeLevels]>([])
    let phone: Double?
    init(phoneVolume: Double? = 1) { phone = phoneVolume }
    func apply(_ levels: VolumeLevels) { applied.withLock { $0.append(levels) } }
    var phoneVolume: Double? { phone }
    var last: VolumeLevels? { applied.withLock { $0.last } }
}

final class VolumeLines: Sendable {
    let lines = Mutex<[String]>([])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

func volumeCall(_ args: [String: JSONValue]) -> ToolCall {
    ToolCall(id: CallID("v1")!, name: "set_volume", arguments: .object(args))
}

@Suite("T-032g F-13a volume: levels, set_volume, settings")
struct VolumeTests {
    func controller(media: Int? = nil, voice: Int? = nil, phone: Double? = 1)
        -> (VolumeController, VolumeMemoryStore, RecordingVolumeOutput, VolumeLines) {
        var saved: [String: String] = [:]
        if let media { saved["volumeMedia"] = String(media) }
        if let voice { saved["volumeVoice"] = String(voice) }
        let store = VolumeMemoryStore(saved)
        let output = RecordingVolumeOutput(phoneVolume: phone)
        let lines = VolumeLines()
        return (VolumeController(store: store, output: output, onLine: lines.add), store, output, lines)
    }

    func run(_ c: VolumeController, _ target: String, _ action: String, _ value: Int? = nil) async -> ToolResult {
        var args: [String: JSONValue] = ["target": .string(target), "action": .string(action)]
        if let value { args["value"] = .int(Int64(value)) }
        let call = volumeCall(args)
        #expect(ToolCatalog.validate(call) == nil)
        return await c.execute(call)
    }

    @Test("F-13a row 1: every bad shape of §4 item 4 has its code; every good shape is accepted")
    func validator() {
        let bad: [([String: JSONValue], ToolErrorCode)] = [
            (["target": "media"], .invalidFields),
            (["action": "up"], .invalidFields),
            ([:], .invalidFields),
            (["target": "media", "action": "up", "level": .int(3)], .invalidFields),
            (["target": .int(1), "action": "up"], .invalidFieldType),
            (["target": "media", "action": .bool(true)], .invalidFieldType),
            (["target": "media", "action": "set", "value": "7"], .invalidFieldType),
            (["target": "media", "action": "set", "value": .int(11)], .invalidFieldValue),
            (["target": "media", "action": "set", "value": .int(-1)], .invalidFieldValue),
            (["target": "media", "action": "set", "value": .double(6.5)], .invalidFieldValue),
            (["target": "phone", "action": "up"], .invalidFieldValue),
            (["target": "media", "action": "louder"], .actionNotAllowed),
            (["target": "voice", "action": "set"], .missingValue),
        ]
        for (args, code) in bad {
            #expect(ToolCatalog.validate(volumeCall(args)) == code, "\(args)")
        }
        for target in ["media", "voice"] {
            for action in ["up", "down", "mute", "max"] {
                #expect(ToolCatalog.validate(volumeCall(["target": .string(target), "action": .string(action)])) == nil)
            }
            for value: JSONValue in [.int(0), .int(7), .int(10), .double(4)] {
                #expect(ToolCatalog.validate(volumeCall(["target": .string(target), "action": "set", "value": value])) == nil)
            }
        }
    }

    @Test("F-13a row 2: up from 10, down from 0 (media), down from 2 (voice), mute on voice: limit, level unchanged")
    func limits() async {
        let cases: [(media: Int, voice: Int, target: String, action: String, level: Int, announce: String)] = [
            (10, 10, "media", "up", 10, "已经是最大了"),
            (0, 10, "media", "down", 0, "已经是最小了"),
            (10, 2, "voice", "down", 2, "已经是最小了"),
            (10, 2, "voice", "mute", 2, "已经是最小了"),
            (10, 6, "voice", "mute", 6, "我说话的声音不能关掉，最小可以调到 2"),
            (10, 10, "voice", "max", 10, "已经是最大了"),
        ]
        for c in cases {
            let (volume, _, _, _) = controller(media: c.media, voice: c.voice)
            let r = await run(volume, c.target, c.action)
            #expect(r.ok && r.data["limit_reached"] == .bool(true), "\(c)")
            #expect(r.data["level"] == .int(Int64(c.level)) && r.data["previous"] == .int(Int64(c.level)), "\(c)")
            #expect(r.data["announce"] == .string(c.announce), "\(c)")
        }
        // §3 item 2: asking for less than 2 for her voice is the floor, never silence.
        let (volume, _, output, _) = controller(voice: 6)
        let r = await run(volume, "voice", "set", 1)
        #expect(r.data["level"] == .int(2) && r.data["limit_reached"] == .bool(true))
        #expect(r.data["announce"] == .string("我说话的声音调到 2 了，不能再小了"))
        #expect(output.last?.voice == 2)
    }

    @Test("F-13a row 3: up from 5, down from 9, set 7, max, mute on media; previous right; announce from code")
    func changes() async {
        let cases: [(from: Int, action: String, value: Int?, level: Int, limit: Bool)] = [
            (5, "up", nil, 7, false), (9, "down", nil, 7, false), (3, "set", 7, 7, false),
            (5, "max", nil, 10, true), (5, "mute", nil, 0, true),
            // §4 item 2: by 1 when within 1 of the end.
            (9, "up", nil, 10, true), (1, "down", nil, 0, true),
        ]
        for c in cases {
            let (volume, store, output, _) = controller(media: c.from)
            let r = await run(volume, "media", c.action, c.value)
            #expect(r.ok && r.data["target"] == .string("media"), "\(c)")
            #expect(r.data["level"] == .int(Int64(c.level)) && r.data["previous"] == .int(Int64(c.from)), "\(c)")
            #expect(r.data["limit_reached"] == .bool(c.limit), "\(c)")
            #expect(r.data["announce"] == .string("音乐音量调到 \(c.level) 了"), "\(c)")
            #expect(r.data["next"] == .string("只说这一句：音乐音量调到 \(c.level) 了"), "\(c)")
            // §4 item 5: applied before the result is returned, and saved.
            #expect(output.last?.media == c.level && output.last?.mediaGain == Double(c.level) / 10)
            #expect(store.string("volumeMedia") == String(c.level))
        }
        let (volume, _, output, _) = controller(voice: 6)
        let r = await run(volume, "voice", "up")
        #expect(r.data["announce"] == .string("我说话的声音调到 8 了") && output.last?.voiceGain == 0.8)
        // Voice steps stop at the floor: 3 → 2.
        let (low, _, _, _) = controller(voice: 3)
        #expect(await run(low, "voice", "down").data["level"] == .int(2))
    }

    @Test("F-13a §4 item 5: at 10 with the phone below half volume, she points to the side buttons")
    func sideButtons() async {
        let (quiet, _, _, _) = controller(media: 10, phone: 0.3)
        #expect(await run(quiet, "media", "max").data["announce"] == .string("已经是最大了，可以按手机侧面的音量键再调大"))
        let (rising, _, _, _) = controller(media: 6, phone: 0.3)
        #expect(await run(rising, "media", "max").data["announce"] == .string("音乐音量调到 10 了，可以按手机侧面的音量键再调大"))
        let (loud, _, _, _) = controller(media: 10, phone: 0.8)
        #expect(await run(loud, "media", "up").data["announce"] == .string("已经是最大了"))
        let (unknown, _, _, _) = controller(media: 10, phone: nil)
        #expect(await run(unknown, "media", "up").data["announce"] == .string("已经是最大了"))
        let (notAtTop, _, _, _) = controller(media: 6, phone: 0.3)
        #expect(await run(notAtTop, "media", "down").data["announce"] == .string("音乐音量调到 4 了"))
    }

    @Test("F-13a row 4: levels saved, app restarted: the same levels are applied at start; unset is 10")
    func persistence() async {
        let (first, store, _, _) = controller()
        #expect(first.levels == VolumeLevels(media: 10, voice: 10))
        _ = await run(first, "media", "set", 4)
        _ = await run(first, "voice", "down")
        let output = RecordingVolumeOutput()
        let restarted = VolumeController(store: store, output: output)
        #expect(restarted.levels == VolumeLevels(media: 4, voice: 8))
        #expect(output.applied.withLock { $0 } == [VolumeLevels(media: 4, voice: 8)])
        // A broken or out-of-range saved value never silences her.
        let odd = VolumeMemoryStore(["volumeMedia": "x", "volumeVoice": "0"])
        #expect(VolumeLevels.saved(in: odd) == VolumeLevels(media: 10, voice: 2))
    }

    @Test("F-13a row 5: voice level 6, barge-in dip, then flush: reply gain 0.6 × dip, then 0.6 (not 1)")
    func dipTimesVoice() {
        let voice = VolumeLevels(voice: 6).voiceGain
        let dipped = ReplyGain.value(voiceGain: voice, dipDb: 10)
        #expect(abs(dipped - 0.6 * 0.316_227_766) < 1e-6)
        #expect(ReplyGain.value(voiceGain: voice, dipDb: nil) == 0.6)
        #expect(ReplyGain.value(voiceGain: 1, dipDb: nil) == 1)
    }

    @Test("F-13a row 8: a 设置 slider runs the same executor; record line by=settings; the tool line by=tool")
    func slider() async {
        let (volume, store, output, lines) = controller(media: 6)
        let change = volume.slider(.media, to: 3)
        #expect(change.level == 3 && change.previous == 6 && output.last?.media == 3 && store.string("volumeMedia") == "3")
        _ = await run(volume, "media", "up")
        volume.slider(.voice, to: 2)
        _ = await run(volume, "voice", "mute")
        #expect(lines.all == [
            "volume set target=media from=6 to=3 by=settings limit=false",
            "volume set target=media from=3 to=5 by=tool limit=false",
            "volume set target=voice from=10 to=2 by=settings limit=true",
            "volume set target=voice from=2 to=2 by=tool limit=true",
        ])
    }

    @Test("F-13a §4 items 6–7: declared, not a comfort tool, not repeat-sensitive (two steps in one turn)")
    func declaration() throws {
        let spec = try #require(ToolCatalog.spec("set_volume"))
        #expect(!spec.repeatSensitive && !CarRequestRouter.comfortTools.contains("set_volume"))
        #expect(ToolCatalog.declarations.contains { $0.name == "set_volume" })
        #expect(ToolCatalog.declarations(for: .model, webSearch: true).contains { $0.name == "set_volume" })
        #expect(spec.declaration.parametersJSONSchema["required"] == ["target", "action"])
        var dispatcher = ToolDispatcher()
        let up = volumeCall(["target": "media", "action": "up"])
        let context = GuardContext(turn: 1)
        #expect(dispatcher.decide(up, context: context) == .execute(up))
        #expect(dispatcher.decide(up, context: context) == .execute(up))
    }
}
