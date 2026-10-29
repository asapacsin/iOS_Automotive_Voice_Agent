import Foundation
import NovaKit
import NovaPorts

/// One declared tool. `repeatSensitive`: an identical second call in one driver turn is dropped
/// (`RealtimeToolCatalog.ToolSpec`, `ToolCallGuards.repeatedInTurn`).
public struct ToolSpec: Sendable, Hashable {
    public let domain: String
    public let repeatSensitive: Bool
    public let declaration: ToolDeclaration
    public var name: String { declaration.name }
}

/// The product tool catalog (`A/tools/ToolRegistry.kt` + `*Domain.kt`) with each domain's argument rules.
public enum ToolCatalog {
    /// `RealtimeToolCatalog.MAX_ARGUMENT_BYTES`.
    public static let maxArgumentBytes = 4096
    public static let maxChoiceIndex = 10
    public static let choicePreferences: Set<String> = ["fastest", "shortest", "recommended", "no_toll", "fewest_lights", "nearest"]
    public static let liveInfoKinds = ["weather", "route_traffic", "along_route", "place_details", "current_location"]
    public static let climateActions = ["power_on", "power_off", "set_temperature", "adjust_temperature", "set_fan",
                                        "adjust_fan", "get_state"]
    public static let windowActions = ["open", "close", "set", "adjust", "get_state"]
    public static let windows = ["all", "front", "rear", "driver", "passenger", "front_left", "front_right",
                                 "rear_left", "rear_right"]
    public static let seatActions = ["adjust_height", "set_height", "get_state"]
    public static let seats = ["driver", "passenger"]
    public static let scenarios = ["mosquito", "mosquito_done", "stuffy", "drowsy"]
    public static let speakingStyles = ["default", "sweet", "tsundere", "gentle", "lively"]

    /// All tools in Android domain order.
    public static let specs: [ToolSpec] = generatedSpecs
    public static let declarations: [ToolDeclaration] = specs.map(\.declaration)
    private static let byName: [String: ToolSpec] = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })

    public static func spec(_ name: String) -> ToolSpec? { byName[name] }

    /// Rule-violation code, `UNKNOWN_TOOL`, `ARGUMENTS_TOO_LARGE`, or nil when the call may proceed.
    public static func validate(_ call: ToolCall) -> ToolErrorCode? {
        guard spec(call.name) != nil else { return .unknownTool }
        guard case .object(let args) = call.arguments else { return .malformedJson }
        let bytes = (try? JSONValue.canonicalEncoder().encode(call.arguments).count) ?? Int.max
        if bytes > maxArgumentBytes { return .argumentsTooLarge }
        return validate(call.name, args)
    }

    // Port of each `*Domain.validate`. Lengths are UTF-16 units, as Kotlin `String.length` counts. `args.opt(k) is String/Number` checks become JSONValue cases.
    static func validate(_ name: String, _ a: [String: JSONValue]) -> ToolErrorCode? {
        let keys = Set(a.keys)
        func str(_ k: String) -> String? { a[k]?.stringValue }
        func isString(_ k: String) -> Bool { str(k) != nil }
        func num(_ k: String) -> Double? {
            switch a[k] {
            case .int(let v): Double(v)
            case .double(let v): v
            default: nil
            }
        }
        func isNumber(_ k: String) -> Bool { num(k) != nil }
        let trimmed: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        switch name {
        case "navigate_to":
            if keys != ["destination"] { return .invalidFields }
            guard let d = str("destination") else { return .invalidFieldType }
            if trimmed(d).isEmpty { return .blankDestination }
            if trimmed(d).utf16.count > 120 { return .destinationTooLong }
        case "choose_navigation_option":
            if keys.count != 1 || !keys.isSubset(of: ["index", "preference", "name"]) { return .invalidFields }
            if keys.contains("index") {
                let index: Int? = switch a["index"] {
                case .int(let v): Int(v)
                case .double(let v) where v.truncatingRemainder(dividingBy: 1) == 0: Int(exactly: v)
                case .string(let s): Int(trimmed(s))
                default: nil
                }
                if index == nil || !(1...maxChoiceIndex).contains(index!) { return .invalidIndex }
            } else if keys.contains("preference") {
                if !(str("preference").map(choicePreferences.contains) ?? false) { return .preferenceNotAllowed }
            } else {
                guard let n = str("name"), !trimmed(n).isEmpty, n.utf16.count <= 40 else { return .invalidName }
            }
        case "exit_navigation_mode", "end_conversation":
            if !keys.isEmpty { return .invalidFields }
        case "open_app":
            if keys != ["app"] { return .invalidFields }
            guard let app = str("app") else { return .invalidFieldType }
            if !["maps", "settings"].contains(app) { return .appNotAllowed }
        case "control_music":
            if keys != ["action"] { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !["play", "stop"].contains(action) { return .actionNotAllowed }
        case "play_music":
            let fields: Set<String> = ["title", "artist", "album_or_work", "mood", "query", "exclude_title"]
            let describing = ["title", "artist", "album_or_work", "query", "mood"]
            if keys.isEmpty || !keys.isSubset(of: fields) { return .invalidFields }
            if keys.contains(where: { !isString($0) }) { return .invalidFieldType }
            if keys.contains(where: { str($0)!.utf16.count > 80 }) { return .invalidFieldValue }
            if !describing.contains(where: { !(str($0).map(trimmed) ?? "").isEmpty }) { return .missingValue }
        case "control_climate":
            if !keys.contains("action") || !keys.isSubset(of: ["action", "value"]) { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !climateActions.contains(action) { return .actionNotAllowed }
            if keys.contains("value") && !isNumber("value") { return .invalidFieldType }
            if ["set_temperature", "set_fan"].contains(action) && !keys.contains("value") { return .missingValue }
        case "control_window":
            if !keys.contains("action") || !keys.isSubset(of: ["action", "window", "value"]) { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !windowActions.contains(action) { return .actionNotAllowed }
            if keys.contains("window") && !isString("window") { return .invalidFieldType }
            if keys.contains("window") && !windows.contains(str("window")!) { return .invalidFieldValue }
            if keys.contains("value") && !isNumber("value") { return .invalidFieldType }
            if action == "set" && !keys.contains("value") { return .missingValue }
            if action == "adjust" && keys.contains("value") && num("value") == 0 { return .invalidValue }
        case "control_seat":
            if !keys.contains("action") || !keys.isSubset(of: ["action", "seat", "value"]) { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !seatActions.contains(action) { return .actionNotAllowed }
            if keys.contains("seat") && !isString("seat") { return .invalidFieldType }
            if keys.contains("seat") && !seats.contains(str("seat")!) { return .invalidFieldValue }
            if keys.contains("value") && !isNumber("value") { return .invalidFieldType }
            if ["set_height", "adjust_height"].contains(action) && !keys.contains("value") { return .missingValue }
            // Android: optDouble("value") == 0.0 (a missing value is NaN, already MISSING_VALUE above).
            if action == "adjust_height" && num("value") == 0 { return .invalidValue }
        case "run_scenario":
            if keys != ["name"] { return .invalidFields }
            guard let n = str("name") else { return .invalidFieldType }
            if !scenarios.contains(n) { return .invalidFieldValue }
        case "describe_camera_view":
            if !keys.contains("question") || !keys.isSubset(of: ["question", "camera"]) { return .invalidFields }
            guard let q = str("question") else { return .invalidFieldType }
            if keys.contains("camera") && str("camera").flatMap(CameraLens.init(rawValue:)) == nil {
                return .invalidFieldValue
            }
            if trimmed(q).isEmpty { return .blankQuestion }
            if q.utf16.count > 200 { return .questionTooLong }
        case "place_call":
            return nil  // PhoneDomain: no rules beyond the schema; the handler checks its own arguments.
        case "query_live_info":
            if !keys.contains("kind") || !keys.isSubset(of: ["kind", "where", "day", "category", "target"]) {
                return .invalidFields
            }
            if keys.contains(where: { !isString($0) }) { return .invalidFieldType }
            if !liveInfoKinds.contains(str("kind")!) { return .invalidKind }
            if keys.contains(where: { str($0)!.utf16.count > 20 }) { return .invalidArgument }
        case "set_speech_output":
            if keys != ["mode"] { return .invalidFields }
            guard let mode = str("mode") else { return .invalidFieldType }
            if !["silent", "spoken"].contains(mode) { return .modeNotAllowed }
        case "set_speaking_style":
            if keys != ["style"] { return .invalidFields }
            guard let style = str("style") else { return .invalidFieldType }
            if !speakingStyles.contains(style) { return .styleNotAllowed }
        default:
            return nil
        }
        return nil
    }
}

/// `A/ToolFailureAdvice.kt`: the one place that says what the driver hears after a refusal.
public enum ToolFailureAdvice {
    public static func forCode(_ code: ToolErrorCode) -> String? { generatedTable[code] ?? iosTable[code] }

    /// iOS-only codes (I-2): one honest sentence for a tool with no iOS executor yet.
    static let iosTable: [ToolErrorCode: String] = [
        .notAvailableOnIOSYet: "这个功能在这台 iPhone 上还没有做好，所以没有执行。请用一句话如实告诉用户暂时还不能用，不要说已经做了。",
        .cameraPermissionDenied: "摄像头没有权限，请在设置里允许。请如实说明，不要描述画面。",
        .cameraUnavailable: "摄像头现在用不了。请如实说明，不要描述画面。",
        .navigationNotRequested: "司机还没有选路线，所以没有开始导航。不要说已经开始或已经选好；请只问一句：有几条路线（按屏幕上的条数说），要走哪一条？",
        .confirmRequired: "导航还在继续，没有结束。请只问一句：要结束导航吗？不要说已经结束。",
        .styleNotAllowed: "没有这种语气，语气没有改。请用一句话告诉用户只有甜、傲娇、温柔、元气和正常这几种。",
    ]
}
