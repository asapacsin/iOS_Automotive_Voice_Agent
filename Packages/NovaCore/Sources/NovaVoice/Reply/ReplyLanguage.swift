/// Reply language guard (product-spec "Reply language", owner rule 2026-10-28): she replies only in
/// Mandarin. Device evidence 2026-10-28: she heard 「¿Qué?」 and answered in Spanish.
public enum ReplyLanguage {
    /// Letters outside Han before a reply with no Han character counts as another language. A short
    /// Latin token alone (「OK」, 「4S」) stays allowed.
    static let foreignLetterLimit = 6

    /// The reply so far is in another language: enough letters, none of them Chinese.
    public static func isNotMandarin(_ text: String) -> Bool {
        var foreign = 0
        for scalar in text.unicodeScalars {
            if isHan(scalar) { return false }
            if scalar.properties.isAlphabetic { foreign += 1 }
        }
        return foreign >= foreignLetterLimit
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}
