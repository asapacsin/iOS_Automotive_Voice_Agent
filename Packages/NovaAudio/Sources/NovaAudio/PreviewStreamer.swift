import AudioToolbox
import AVFAudio
import Foundation
import NovaPorts

/// F-13 §17 item 1 (T-032e): parses a preview (`.m4a`, AAC, `moov` before `mdat`) as its bytes arrive with Audio File
/// Stream Services, converts the packets with `AVAudioConverter` to `output` (the preview node's 44.1 kHz stereo
/// float) and hands out PCM pieces of about `PreviewStartRule.pieceSeconds`. Copied practice: AudioStreaming,
/// audiostreamer (music.md §17). In memory only. Not thread-safe: one download task drives it.
final class PreviewStreamer {
    private let output: AVAudioFormat
    private let pieceFrames: AVAudioFrameCount
    private let emit: (AVAudioPCMBuffer) -> Void
    private var stream: AudioFileStreamID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var piece: AVAudioPCMBuffer?
    /// The parser or the converter could not read the bytes.
    private(set) var failed = false
    /// PCM frames handed out so far.
    private(set) var emittedFrames: AVAudioFramePosition = 0

    init(output: AVAudioFormat, emit: @escaping (AVAudioPCMBuffer) -> Void) {
        self.output = output
        self.pieceFrames = AVAudioFrameCount(output.sampleRate * PreviewStartRule.pieceSeconds)
        self.emit = emit
    }

    deinit {
        if let stream { AudioFileStreamClose(stream) }
    }

    /// Feeds the next bytes of the file, in order.
    func parse(_ bytes: Data) {
        guard !failed, !bytes.isEmpty else { return }
        if stream == nil {
            let property: AudioFileStream_PropertyListenerProc = { client, id, property, _ in
                Unmanaged<PreviewStreamer>.fromOpaque(client).takeUnretainedValue().property(id, property)
            }
            let packets: AudioFileStream_PacketsProc = { client, byteCount, packetCount, data, descriptions in
                Unmanaged<PreviewStreamer>.fromOpaque(client).takeUnretainedValue()
                    .packets(byteCount, packetCount, data, descriptions)
            }
            // The callbacks run inside AudioFileStreamParseBytes, while `self` is alive (closed in deinit).
            var id: AudioFileStreamID?
            guard AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), property, packets,
                                      kAudioFileM4AType, &id) == noErr, let id else {
                failed = true
                return
            }
            stream = id
        }
        guard let stream else { return }
        let status = bytes.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(stream, UInt32(raw.count), raw.baseAddress, [])
        }
        if status != noErr { failed = true }
    }

    /// The download ended: flushes the converter and hands out the last, shorter piece.
    func finish() {
        if !failed, converter != nil { convert(nil, packets: 0) }
        if let piece, piece.frameLength > 0 {
            self.piece = nil
            hand(piece)
        }
    }

    private func property(_ id: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets, converter == nil else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(id, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
              let input = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: input, to: output) else {
            failed = true
            return
        }
        // AAC needs its decoder configuration (the esds magic cookie).
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var cookie = Data(count: Int(cookieSize))
            let status = cookie.withUnsafeMutableBytes { raw in
                AudioFileStreamGetProperty(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, raw.baseAddress!)
            }
            if status == noErr { converter.magicCookie = cookie }
        }
        // A mono preview plays on both speakers (as the §16 decoder does).
        if input.channelCount == 1, output.channelCount == 2 { converter.channelMap = [0, 0] }
        inputFormat = input
        self.converter = converter
    }

    private func packets(_ byteCount: UInt32, _ packetCount: UInt32, _ data: UnsafeRawPointer,
                         _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard !failed, packetCount > 0 else { return }
        // AAC is variable-size: without packet descriptions the bytes cannot be split into packets.
        guard let descriptions, let input = inputFormat else {
            failed = true
            return
        }
        var largest = 0
        for i in 0..<Int(packetCount) { largest = max(largest, Int(descriptions[i].mDataByteSize)) }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: packetCount, maximumPacketSize: largest)
        compressed.data.copyMemory(from: data, byteCount: Int(byteCount))
        compressed.packetDescriptions?.update(from: descriptions, count: Int(packetCount))
        compressed.packetCount = packetCount
        compressed.byteLength = byteCount
        convert(compressed, packets: packetCount)
    }

    /// Converts one packet group (nil: end of stream, flush) into PCM and collects it into pieces.
    private func convert(_ compressed: AVAudioCompressedBuffer?, packets: AVAudioPacketCount) {
        guard let converter, let input = inputFormat else { return }
        let framesPerPacket = max(input.streamDescription.pointee.mFramesPerPacket, 1024)
        let inFrames = Double(max(packets, 1) * framesPerPacket)
        let capacity = AVAudioFrameCount(inFrames * output.sampleRate / input.sampleRate) + 2_048
        var fed = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                failed = true
                return
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let compressed, !fed {
                    fed = true
                    inputStatus.pointee = .haveData
                    return compressed
                }
                // More bytes are on the way: keep the converter's state for the next group.
                inputStatus.pointee = compressed == nil ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error || error != nil {
                failed = true
                return
            }
            if out.frameLength > 0 { collect(out) }
            // `.haveData`: the output filled up and more may be waiting; otherwise this group is done.
            guard status == .haveData, out.frameLength == out.frameCapacity else { return }
        }
    }

    /// Copies converted frames into the current piece; each full piece is handed out.
    private func collect(_ pcm: AVAudioPCMBuffer) {
        guard let source = pcm.floatChannelData else { return }
        let channels = Int(output.channelCount)
        var done: AVAudioFrameCount = 0
        while done < pcm.frameLength {
            if piece == nil { piece = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: pieceFrames) }
            guard let piece, let target = piece.floatChannelData else {
                failed = true
                return
            }
            let n = min(pcm.frameLength - done, piece.frameCapacity - piece.frameLength)
            for c in 0..<channels {
                (target[c] + Int(piece.frameLength)).update(from: source[c] + Int(done), count: Int(n))
            }
            piece.frameLength += n
            done += n
            if piece.frameLength == piece.frameCapacity {
                self.piece = nil
                hand(piece)
            }
        }
    }

    private func hand(_ piece: AVAudioPCMBuffer) {
        emittedFrames += AVAudioFramePosition(piece.frameLength)
        emit(piece)
    }
}
