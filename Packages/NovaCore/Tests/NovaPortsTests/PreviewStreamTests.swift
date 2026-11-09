import Foundation
import Testing
@testable import NovaPorts

/// A top-level MP4 box header (`size` covers the header) followed by `body` bytes of its payload.
private func box(_ type: String, size: Int, body: Int? = nil) -> Data {
    var d = Data()
    withUnsafeBytes(of: UInt32(size).bigEndian) { d.append(contentsOf: $0) }
    d.append(contentsOf: Array(type.utf8))
    d.append(Data(count: body ?? max(size - 8, 0)))
    return d
}

@Suite("T-032e F-13 §17 preview streaming (pure)")
struct PreviewStreamTests {
    @Test("T-032e row 6: PreviewLayout.scan gives streamable, wholeFile, needMore")
    func layout() {
        // ftyp(24) moov(…) free mdat: the moov header is enough.
        let moovFirst = box("ftyp", size: 24) + box("moov", size: 40_000, body: 100)
        #expect(PreviewLayout.scan(moovFirst) == .streamable)
        #expect(PreviewLayout.scan(box("ftyp", size: 24) + box("moov", size: 16) + box("free", size: 8) + box("mdat", size: 64)) == .streamable)
        #expect(PreviewLayout.scan(box("ftyp", size: 24) + box("mdat", size: 900_000, body: 100)) == .wholeFile)
        #expect(PreviewLayout.scan(box("ftyp", size: 24).prefix(12)) == .needMore)
        // A free box before mdat still decides by the first of moov/mdat; a 64-bit size is followed.
        var large = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { large.append(contentsOf: $0) }
        large.append(contentsOf: Array("free".utf8))
        withUnsafeBytes(of: UInt64(24).bigEndian) { large.append(contentsOf: $0) }
        large.append(Data(count: 8))
        #expect(PreviewLayout.scan(box("ftyp", size: 24) + large + box("moov", size: 8)) == .streamable)
        #expect(PreviewLayout.scan(Data("<html>not a preview</html>".utf8)) == .wholeFile)
        #expect(PreviewLayout.streamable.logName == "stream" && PreviewLayout.wholeFile.logName == "whole")
    }

    @Test("T-032e row 7: PreviewStartRule waits below 1.0 s while downloading, starts at 1.0 s or at the end")
    func startRule() {
        #expect(!PreviewStartRule.shouldStart(scheduledSeconds: 0.9, downloadEnded: false))
        #expect(PreviewStartRule.shouldStart(scheduledSeconds: 1.0, downloadEnded: false))
        #expect(PreviewStartRule.shouldStart(scheduledSeconds: 0.4, downloadEnded: true))
        #expect(PreviewStartRule.pieceSeconds == 0.5)
    }

    @Test("T-032e row 8: stage codes and log lines exactly as item 6")
    func lines() {
        let all: [(PreviewFailure, String)] = [(.downloadTimeout, "download_timeout"), (.downloadNetwork, "download_network"),
                                               (.downloadHTTP(404), "download_http_404"), (.tooLarge, "too_large"),
                                               (.parse, "parse"), (.engine, "engine"), (.stopped, "stopped")]
        for (failure, code) in all { #expect(failure.code == code) }
        #expect(PreviewLine.failed(.downloadTimeout, ms: 5003, bytes: 0) == "music preview failed stage=download_timeout ms=5003 bytes=0")
        #expect(PreviewLine.cut(.downloadNetwork, playedMs: 4210) == "music preview cut stage=download_network played_ms=4210")
        #expect(PreviewLine.start(firstByteMs: 180, startMs: 420, layout: .streamable)
                == "music preview start first_byte_ms=180 start_ms=420 layout=stream")
        #expect(PreviewLine.start(firstByteMs: 180, startMs: 2400, layout: .wholeFile).hasSuffix("layout=whole"))
    }
}
