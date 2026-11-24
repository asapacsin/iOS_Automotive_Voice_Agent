import Foundation

/// F-18 §35 items 3-4 (T-046x): what `open_page` returns. The page fetch is NovaRealtime's; reading the HTML is here.
public struct PageText: Sendable, Hashable {
    public struct Link: Sendable, Hashable {
        public let url: String
        public let text: String
    }

    public let title: String
    /// The visible text, one line per block.
    public let lines: [String]
    /// Up to `maxLinks` absolute links with their text.
    public let links: [Link]

    public static let maxLinks = 40
    /// Item 4: at most this many characters per page sent to the model.
    public static let maxExcerpt = 2500
    /// Item 4: a page with no date sends its first characters only.
    public static let noDateChars = 600

    public var text: String { lines.joined(separator: "\n") }

    /// Script, style and tags removed; block ends become line breaks; entities decoded.
    public init(html: String) {
        var s = html
        s = Self.replace(#"(?is)<(script|style|noscript|template)\b[^>]*>.*?</\1\s*>"#, in: s, with: " ")
        s = Self.replace(#"(?s)<!--.*?-->"#, in: s, with: " ")
        let titleText = Self.first(#"(?is)<title[^>]*>(.*?)</title>"#, in: s).map { Self.clean(Self.replace(#"<[^>]+>"#, in: $0, with: " ")) } ?? ""
        var links: [Link] = []
        let anchor = try! NSRegularExpression(pattern: #"(?is)<a\b[^>]*?href\s*=\s*["'](https?://[^"'\s>]+)["'][^>]*>(.*?)</a\s*>"#)
        let ns = s as NSString
        for m in anchor.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let text = Self.clean(Self.replace(#"<[^>]+>"#, in: ns.substring(with: m.range(at: 2)), with: " "))
            guard !text.isEmpty else { continue }
            links.append(Link(url: Self.entities(ns.substring(with: m.range(at: 1))), text: String(text.prefix(40))))
            if links.count == Self.maxLinks { break }
        }
        s = Self.replace(#"(?is)<head\b.*?</head\s*>"#, in: s, with: " ")
        s = Self.replace(#"(?i)<\s*(br|/p|/div|/li|/tr|/h[1-6]|/section|/article|/dd|/dt|/td|/table|/ul|/ol|p|li|tr|h[1-6])\b[^>]*>"#, in: s, with: "\n")
        s = Self.replace(#"<[^>]+>"#, in: s, with: " ")
        s = Self.entities(s)
        self.title = titleText
        self.lines = s.split(whereSeparator: \.isNewline).map { Self.clean(String($0)) }.filter { !$0.isEmpty }
        self.links = links
    }

    public init(title: String, lines: [String], links: [Link] = []) {
        self.title = title
        self.lines = lines
        self.links = links
    }

    /// Item 4: the title and the lines that hold a date, each with one line before and after, up to `maxExcerpt`
    /// characters; a page with no date gives its first `noDateChars` characters.
    public var excerpt: String {
        let dated = lines.indices.filter { EventDates.hasDate(lines[$0]) }
        let head = title.isEmpty ? "" : title + "\n"
        guard !dated.isEmpty else { return String((head + text).prefix(Self.noDateChars)) }
        var keep = IndexSet()
        for i in dated { keep.insert(integersIn: max(0, i - 1)...min(lines.count - 1, i + 1)) }
        var out = head
        var last: Int?
        for i in keep {
            let line = (last.map { i > $0 + 1 } ?? false ? "…\n" : "") + lines[i] + "\n"
            if out.count + line.count > Self.maxExcerpt { break }
            out += line
            last = i
        }
        return String(out.prefix(Self.maxExcerpt))
    }

    static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" || $0 == "\u{3000}" || $0 == "\r" })
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replace(_ pattern: String, in s: String, with t: String) -> String {
        let r = try! NSRegularExpression(pattern: pattern)
        return r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }

    static func first(_ pattern: String, in s: String) -> String? {
        let r = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                       ("&ensp;", " "), ("&emsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&middot;", "·")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let numeric = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]{1,6});"#)
        let ns = out as NSString
        var result = ""
        var at = 0
        for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            let hex = m.range(at: 1).length > 0
            if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n) {
                result += String(Character(u))
            }
            at = m.range.location + m.range.length
        }
        result += ns.substring(from: at)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
