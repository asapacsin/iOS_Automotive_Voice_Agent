import AudioToolbox
import AVFAudio
import Foundation

/// F-13 §14 item 4 (T-032b): decodes a downloaded preview (`.m4a`, AAC) held in memory to PCM in `format`,
/// with Apple's AudioFile + ExtAudioFile reading from the bytes through callbacks. Nothing touches the disk.
enum PreviewDecoder {
    /// The bytes the AudioFile callbacks read from.
    private final class Bytes {
        let data: Data
        init(_ data: Data) { self.data = data }
    }

    static func decode(_ data: Data, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytes = Unmanaged.passRetained(Bytes(data))
        defer { bytes.release() }
        let read: AudioFile_ReadProc = { client, position, requested, buffer, actual in
            let d = Unmanaged<Bytes>.fromOpaque(client).takeUnretainedValue().data
            let start = Int(position)
            guard start >= 0, start < d.count else {
                actual.pointee = 0
                return noErr
            }
            let count = min(Int(requested), d.count - start)
            d.withUnsafeBytes { raw in
                buffer.copyMemory(from: raw.baseAddress!.advanced(by: start), byteCount: count)
            }
            actual.pointee = UInt32(count)
            return noErr
        }
        let size: AudioFile_GetSizeProc = { client in
            Int64(Unmanaged<Bytes>.fromOpaque(client).takeUnretainedValue().data.count)
        }
        var fileID: AudioFileID?
        guard AudioFileOpenWithCallbacks(bytes.toOpaque(), read, nil, size, nil, kAudioFileM4AType, &fileID) == noErr,
              let fileID else { return nil }
        defer { AudioFileClose(fileID) }
        var extRef: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(fileID, false, &extRef) == noErr, let ext = extRef else { return nil }
        defer { ExtAudioFileDispose(ext) }

        var client = format.streamDescription.pointee
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, asbdSize, &client) == noErr else { return nil }
        var fileFormat = AudioStreamBasicDescription()
        var propSize = asbdSize
        guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &propSize, &fileFormat) == noErr,
              fileFormat.mSampleRate > 0 else { return nil }
        var fileFrames: Int64 = 0
        propSize = UInt32(MemoryLayout<Int64>.size)
        _ = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &propSize, &fileFrames)
        // A 30 s preview; the cap keeps a wrong length from allocating without bound.
        let cap = format.sampleRate * 90
        let expected = fileFrames > 0 ? Double(fileFrames) * format.sampleRate / fileFormat.mSampleRate + 8_192 : cap
        let capacity = AVAudioFrameCount(min(expected, cap))
        let chunkFrames: AVAudioFrameCount = 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let outData = out.floatChannelData, let chunkData = chunk.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        var filled: AVAudioFrameCount = 0
        while filled < capacity {
            var frames = min(chunkFrames, capacity - filled)
            let list = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for i in 0..<list.count { list[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size) }
            guard ExtAudioFileRead(ext, &frames, chunk.mutableAudioBufferList) == noErr else { return nil }
            if frames == 0 { break }
            for c in 0..<channels {
                (outData[c] + Int(filled)).update(from: chunkData[c], count: Int(frames))
            }
            filled += frames
        }
        out.frameLength = filled
        return filled > 0 ? out : nil
    }
}
