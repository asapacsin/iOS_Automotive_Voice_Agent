import Foundation

/// F-15b §47 item 4 (T-040s): one Chinese sentence per OSRM step from the copied `zh-Hans` templates
/// (`OsrmZhHans`). The choice of template and the token values follow `compile`, `getWayName` and `tokenize` of
/// osrm-text-instructions 0.15.0 `index.js` (v5), so a code the templates do not cover falls back as the library does:
/// an unknown type is `turn`, an unknown modifier is the type's `default`.
enum OsrmInstructions {
    /// Parsed once, read only afterwards.
    nonisolated(unsafe) private static let v5: [String: Any] = {
        let root = (try? JSONSerialization.jsonObject(with: Data(OsrmZhHans.json.utf8))) as? [String: Any]
        return (root?["v5"] as? [String: Any]) ?? [:]
    }()

    private static func table(_ path: String...) -> [String: Any]? {
        var node: Any? = v5
        for key in path { node = (node as? [String: Any])?[key] }
        return node as? [String: Any]
    }

    /// `step` is one OSRM `RouteStep` as decoded JSON. `waypointName`: the destination, for the `named` arrive
    /// template (the library's `options.waypointName`); `legIndex`/`legCount` give `{nth}` as the library does.
    static func compile(_ step: [String: Any], legIndex: Int = 0, legCount: Int = 1, waypointName: String? = nil) -> String {
        let maneuver = step["maneuver"] as? [String: Any] ?? [:]
        guard var type = maneuver["type"] as? String else { return "" }
        let modifier = maneuver["modifier"] as? String
        if type != "depart", type != "arrive", modifier == nil { return "" }
        if table(type) == nil { type = "turn" }
        let side = step["driving_side"] as? String
        var object: [String: Any]
        if let mode = step["mode"] as? String, let special = table("modes", mode) {
            object = special
        } else {
            let omitSide = type == "off ramp" && side.map { (modifier ?? "").contains($0) } == true
            if let modifier, let specific = table(type, modifier), !omitSide {
                object = specific
            } else {
                object = table(type, "default") ?? [:]
            }
        }
        let rotaryName = nonEmpty(step["rotary_name"] as? String)
        let exitNumber = (maneuver["exit"] as? NSNumber)?.intValue
        var laneInstruction: String?
        switch type {
        case "use lane":
            laneInstruction = (table("constants", "lanes")?[laneConfig(step)] as? String)
            if laneInstruction == nil { object = table("use lane", "no_lanes") ?? object }
        case "rotary", "roundabout":
            if rotaryName != nil, exitNumber != nil, let o = object["name_exit"] as? [String: Any] {
                object = o
            } else if rotaryName != nil, let o = object["name"] as? [String: Any] {
                object = o
            } else if exitNumber != nil, let o = object["exit"] as? [String: Any] {
                object = o
            } else {
                object = object["default"] as? [String: Any] ?? [:]
            }
        default: break
        }
        let wayName = self.wayName(step)
        let destinations = nonEmpty(step["destinations"] as? String)
        let exits = nonEmpty(step["exits"] as? String)
        let junction = nonEmpty(step["junction_name"] as? String)
        let template: String? = if destinations != nil, exits != nil, let t = object["exit_destination"] as? String { t }
            else if destinations != nil, let t = object["destination"] as? String { t }
            else if exits != nil, let t = object["exit"] as? String { t }
            else if junction != nil, let t = object["junction_name"] as? String { t }
            else if !wayName.isEmpty, let t = object["name"] as? String { t }
            else if nonEmpty(waypointName) != nil, let t = object["named"] as? String { t }
            else { object["default"] as? String }
        guard let template else { return "" }

        var firstDestination = ""
        if let destinations {
            let parts = destinations.components(separatedBy: ": ")
            let ref = parts[0].components(separatedBy: ",")[0]
            let name = parts.count > 1 ? parts[1].components(separatedBy: ",")[0] : ""
            firstDestination = !name.isEmpty && !ref.isEmpty ? ref + ": " + name : (ref.isEmpty ? name : ref)
        }
        let nth = legIndex >= 0 && legIndex != legCount - 1 ? ordinalize(legIndex + 1) : ""
        var tokens: [String: String] = [
            "way_name": wayName,
            "destination": firstDestination,
            "exit": (exits ?? "").components(separatedBy: ";")[0],
            "exit_number": ordinalize(exitNumber ?? 1),
            "direction": direction((maneuver["bearing_after"] as? NSNumber)?.doubleValue),
            "nth": nth,
            "junction_name": (junction ?? "").components(separatedBy: ";")[0],
        ]
        if let rotaryName { tokens["rotary_name"] = rotaryName }
        if let laneInstruction { tokens["lane_instruction"] = laneInstruction }
        if let modifier, let m = table("constants", "modifier")?[modifier] as? String { tokens["modifier"] = m }
        if let waypointName { tokens["waypoint_name"] = waypointName }
        return tokenize(template, tokens)
    }

    /// `getWayName`: the name, the ref, or 「name（ref）」 from the `name and ref` phrase. No road classes are passed.
    static func wayName(_ step: [String: Any]) -> String {
        let stepRef = step["ref"] as? String
        var name = step["name"] as? String ?? ""
        let ref = (stepRef ?? "").components(separatedBy: ";")[0]
        if name == stepRef { name = "" }
        if let stepRef { name = name.replacingOccurrences(of: " (" + stepRef + ")", with: "") }
        if !name.isEmpty, !ref.isEmpty, name != ref {
            return tokenize(table("phrase")?["name and ref"] as? String ?? "{name} ({ref})", ["name": name, "ref": ref])
        }
        if name.isEmpty, !ref.isEmpty { return ref }
        return name
    }

    /// `{token}` and `{token:grammar}` replaced; an unknown token stays as written; double spaces collapsed.
    /// zh-Hans has no grammar rules and `capitalizeFirstLetter` is false.
    static func tokenize(_ template: String, _ tokens: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { rest = rest[open...]; break }
            let inner = rest[rest.index(after: open)..<close]
            let tag = String(inner.split(separator: ":", maxSplits: 1).first ?? "")
            let valid = !tag.isEmpty && inner.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" }
            if valid, let value = tokens[tag] { out += value } else { out += rest[open...close] }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    static func ordinalize(_ n: Int) -> String { table("constants", "ordinalize")?[String(n)] as? String ?? "" }

    static func direction(_ degree: Double?) -> String {
        guard let d = degree else { return "" }
        let key: String = switch d {
        case 0...20: "north"
        case 20..<70: "northeast"
        case 70...110: "east"
        case 110..<160: "southeast"
        case 160...200: "south"
        case 200..<250: "southwest"
        case 250...290: "west"
        case 290..<340: "northwest"
        case 340...360: "north"
        default: ""
        }
        return table("constants", "direction")?[key] as? String ?? ""
    }

    /// `laneConfig`: the first intersection's lanes contracted to `o` (valid) and `x` runs.
    static func laneConfig(_ step: [String: Any]) -> String {
        let lanes = ((step["intersections"] as? [[String: Any]])?.first?["lanes"] as? [[String: Any]]) ?? []
        var config = ""
        var current: Bool?
        for lane in lanes {
            let valid = (lane["valid"] as? Bool) ?? false
            if current != valid { config += valid ? "o" : "x" }
            current = valid
        }
        return config
    }

    private static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
}
