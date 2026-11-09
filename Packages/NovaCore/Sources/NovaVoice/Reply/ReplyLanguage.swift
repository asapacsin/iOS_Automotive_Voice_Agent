/// Reply language guard (product-spec "Reply language"): she answers in Chinese, English or Japanese, the
/// language the driver used (F-05a §14 item 4, owner 2026-11-09; before that Mandarin only, owner rule 2026-10-28).
public enum ReplyLanguage {
    /// F-05a §14 item 4: true as soon as the reply has a letter from a script other than Han, Kana or Latin.
    public static func isNotAllowed(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if isHan(scalar) || isLatin(scalar) || isKana(scalar) { continue }
            if scalar.properties.generalCategory != .nonspacingMark { return true }
        }
        return false
    }

    /// Hiragana, Katakana (with ー and the phonetic extensions) and half-width Katakana (F-05a §14 item 3).
    static func isKana(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true
        default: false
        }
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
