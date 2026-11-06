import Foundation
import NovaPorts

/// F-16 §14 item 2 (T-042c): the iOS pinyin port, Foundation's Mandarin→Latin transform with the tone marks
/// stripped. Each Han character gives one syllable; Latin and digit runs stay one token; punctuation is dropped.
public struct FoundationPinyinConverter: PinyinConverter {
    public init() {}

    public func syllables(_ text: String) -> [String] {
        var tokens: [String] = []
        var run = ""
        for character in text {
            if Self.isHan(character) {
                if !run.isEmpty { tokens.append(run.lowercased()) }
                run = ""
                tokens.append(Self.toneless(String(character)))
            } else if character.isLetter || character.isNumber {
                run.append(character)
            } else {
                if !run.isEmpty { tokens.append(run.lowercased()) }
                run = ""
            }
        }
        if !run.isEmpty { tokens.append(run.lowercased()) }
        return tokens
    }

    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    static func toneless(_ han: String) -> String {
        #if canImport(Darwin)
        let latin = han.applyingTransform(.mandarinToLatin, reverse: false) ?? han
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.lowercased().trimmingCharacters(in: .whitespaces)
        #else
        // swift-corelibs-foundation has no ICU transform here: the character itself stands in (same-character match).
        return han
        #endif
    }
}
