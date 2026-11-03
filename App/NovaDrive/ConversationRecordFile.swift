import Foundation
import NovaAgent

/// F-12 §17 items 1-2, 6 (T-031f): the test record's file and drain loop. Only file writing and the setting live here;
/// formatting, merging and retention are in NovaCore. Nothing written here goes to `RuntimeLog` (I-8).
struct ConversationRecordFile: RecordWriter {
    let url: URL

    static var directory: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(ConversationFiles.directory, isDirectory: true)
    }

    /// A new file for this session, after removing the oldest beyond the newest 50.
    static func create(at date: Date = Date()) -> ConversationRecordFile? {
        guard let dir = directory else { return nil }
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let url = dir.appendingPathComponent(ConversationFiles.name(for: date))
        guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for old in ConversationFiles.toDelete(names) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        return ConversationRecordFile(url: url)
    }

    /// 「删除全部对话记录」: only files with the record's name pattern.
    static func deleteAll() {
        guard let dir = directory else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where ConversationFiles.isRecord(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    func append(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Drains off the audio and event paths, every half second, until cancelled; then once more.
    static func drainLoop(_ record: ConversationRecord, to file: ConversationRecordFile) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                record.drain(to: file)
                try? await Task.sleep(for: .milliseconds(500))
            }
            record.drain(to: file)
        }
    }
}
