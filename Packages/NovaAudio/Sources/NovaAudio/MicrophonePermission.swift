import AVFAudio

/// Record permission (F-23), kept in the audio adapter so AVFAudio stays here (ios-architecture §3.2).
public enum MicrophonePermission {
    /// true granted, false denied, nil not asked yet.
    public static var current: Bool? {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: nil
        }
    }

    public static func request() async -> Bool { await AVAudioApplication.requestRecordPermission() }
}
