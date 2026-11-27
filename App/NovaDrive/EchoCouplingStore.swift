import Foundation

/// F-04b §19 item 0 (T-013n): the echo coupling the 音频测试 echo trial measured on this phone; nil until one ran.
enum EchoCouplingStore {
    private static let key = "audio.echoCoupling"

    static var value: Double? {
        get {
            let v = UserDefaults.standard.double(forKey: key)
            return v > 0 && v.isFinite ? v : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: key) }
    }
}
