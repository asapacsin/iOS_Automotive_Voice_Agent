import Foundation

/// I-8 (review of T-046zf/zg, 2026-11-25): the events lines all go to the local record; only codes and counts go to
/// the system log. A line that names an event (`events drop|image|check|fill name=…`) is record-only; an
/// `events query … q=<text>` line (the query holds the driver's event name and cities) goes to the log without `q=`.
public enum EventLogLine {
    public static func forLog(_ line: String) -> String? {
        if line.contains(" name=") { return nil }
        if let r = line.range(of: " q=") { return String(line[..<r.lowerBound]) }
        return line
    }
}
