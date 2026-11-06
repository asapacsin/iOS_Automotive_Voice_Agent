/// F-16 §14 item 2: Chinese text to toneless pinyin syllables, one per Han character, lowercased; other runs
/// (Latin letters, digits) stay one token each. On iOS the adapter uses Foundation's Mandarin→Latin transform;
/// tests use a fixed table. Pure logic never converts text itself.
public protocol PinyinConverter: Sendable {
    func syllables(_ text: String) -> [String]
}
