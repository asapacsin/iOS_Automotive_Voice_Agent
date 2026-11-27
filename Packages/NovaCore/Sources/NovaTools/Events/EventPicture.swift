import Foundation
import NovaKit
import NovaPorts

/// F-18 §43 item 4 (T-046zf, PoC 2026-11-25: 6 of 7 pictures right): an event's picture is (a) its own page's
/// `og:image`, else (b) the first image-search result whose title has the event's whole name, whose date is from 75
/// days before the start to the end and whose host is not a shop or generated-image host, else (c) none. Never a
/// page's first `<img>` (on government and news pages it was the site's logo or banner).
public enum EventPicture {
    /// §43 item 4b: the shop and generated-image hosts (`gen_ai` anywhere in the URL).
    public static let blockedHosts = ["alicdn.com", "taobao", "tmall", "jd.com", "360buyimg", "yangkeduo", "pinduoduo"]
    public static let blockedInURL = "gen_ai"
    /// §43 item 4b: a result dated from this many days before the event's start.
    public static let daysBefore = 75

    /// §43 item 4a: `<meta property="og:image" content="…">`, else `name="og:image"`; a `//` URL gets `https:`.
    /// Only an http(s) URL counts.
    public static func ogImage(_ html: String) -> String? {
        for attribute in ["property", "name"] {
            for tag in metaTags(html) where attr(tag, attribute)?.lowercased() == "og:image" {
                guard var url = attr(tag, "content")?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { continue }
                url = url.replacingOccurrences(of: "&amp;", with: "&")
                if url.hasPrefix("//") { url = "https:" + url }
                let lower = url.lowercased()
                if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return url }
            }
        }
        return nil
    }

    /// Every `<meta …>` tag of the page.
    static func metaTags(_ html: String) -> [String] {
        matches(#"<meta\b[^>]*>"#, in: html)
    }

    /// The value of `name="…"` (or `'…'`) in one tag.
    static func attr(_ tag: String, _ name: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...2 {
            if let r = Range(m.range(at: i), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// §43 item 4b: 「<event name> <YYYY> 海报」 (the start's year).
    public static func query(_ e: EventEntry) -> String {
        "\(e.name) \(EventDay(e.start)?.year ?? 0) 海报"
    }

    /// Lower-cased, spaces removed.
    static func folded(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    /// §43 item 4b: the first result that passes all three rules; nil when none does.
    public static func pick(_ hits: [EventImageHit], for e: EventEntry) -> String? {
        guard let start = EventDay(e.start), let end = EventDay(e.end) else { return nil }
        let earliest = start.adding(days: -daysBefore)
        let name = folded(e.name)
        return hits.first { h in
            guard !name.isEmpty, folded(h.title).contains(name) else { return false }
            guard let d = EventDay(String(h.date.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").prefix(10))),
                  d >= earliest, d <= end else { return false }
            return !blocked(h.imageURL)
        }?.imageURL
    }

    /// A shop or generated-image URL.
    public static func blocked(_ url: String) -> Bool {
        if url.lowercased().contains(blockedInURL) { return true }
        let host = (URL(string: url)?.host ?? "").lowercased()
        return blockedHosts.contains { host.contains($0) }
    }

    /// §43 item 4: the record line.
    public static func line(_ e: EventEntry) -> String { "events image name=\(e.name) via=\(e.imageVia)" }
}
