/// F-05a §8: is a transcript Chinese? Gemini guesses the input language per utterance and short Mandarin can
/// come back as Portuguese; such text is never the driver's words.
public enum TranscriptLanguage {
    /// True when the text has a Han character and Han characters are ≥ 60 % of its letters. Digits and
    /// punctuation are ignored. PROPOSED: a run of Latin letters counts as one letter (one word), so a name
    /// inside a Chinese sentence (「导航去 Costa」) does not outweigh the Chinese around it.
    public static func isChinese(_ text: String) -> Bool {
        var han = 0
        var other = 0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                han += 1
                inLatinWord = false
            } else if inLatinWord, scalar.properties.generalCategory == .nonspacingMark {
                continue  // a decomposed accent (a + ◌̃) stays inside its word
            } else if scalar.properties.isAlphabetic {
                if isLatin(scalar) {
                    if !inLatinWord { other += 1 }
                    inLatinWord = true
                } else {
                    other += 1
                    inLatinWord = false
                }
            } else {
                inLatinWord = false
            }
        }
        return han > 0 && Double(han) >= 0.6 * Double(han + other)
    }

    /// Basic Latin through Latin Extended-B and Latin Extended Additional (Portuguese ã, ç, ê).
    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value)
    }

    /// CJK Unified Ideographs and Extension A.
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }
}
