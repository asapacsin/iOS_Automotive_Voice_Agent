/// Reply language guard (product-spec "Reply language", owner rule 2026-10-28): she replies only in
/// Mandarin. Device evidence 2026-10-28: she heard 「¿Qué?」 and answered in Spanish.
public enum ReplyLanguage {
    /// Letters outside Han before a reply with no Han character counts as another language. A short
    /// Latin token alone (「OK」, 「4S」) stays allowed.
    static let foreignLetterLimit = 6

    /// The reply so far is in another language: any letter of a script other than Han or Latin (F-05a §13
    /// item 4), or enough letters with none of them Chinese.
    public static func isNotMandarin(_ text: String) -> Bool {
        var foreign = 0
        var han = false
        for scalar in text.unicodeScalars {
            if isHan(scalar) { han = true; continue }
            guard scalar.properties.isAlphabetic else { continue }
            if !isLatin(scalar), scalar.properties.generalCategory != .nonspacingMark { return true }
            foreign += 1
        }
        return !han && foreign >= foreignLetterLimit
    }

    /// Han script, including 々 and 〇 (F-05a §13).
    static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    /// Latin script: `TranscriptLanguage.isLatin` plus full-width Latin letters and digits (ＯＫ, ４Ｓ).
    static func isLatin(_ s: Unicode.Scalar) -> Bool {
        TranscriptLanguage.isLatin(s) || (0xFF10...0xFF19).contains(s.value) || (0xFF21...0xFF3A).contains(s.value)
            || (0xFF41...0xFF5A).contains(s.value)
    }
}
