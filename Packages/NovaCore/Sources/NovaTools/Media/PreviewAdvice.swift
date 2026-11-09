import NovaPorts

/// F-13 §17 item 7 (T-032e): the `NOT_PLAYING` advice for a preview, by the stage it failed at. The generated
/// Android table (`ToolFailureAdvice+Generated.swift`) is not used for previews: its 会员/版权 reason is false here.
public enum PreviewAdvice {
    public static let network = "试听没放起来：网络太慢或者连不上。请如实说没放成，可以让用户稍后再试；不要说版权或会员。"
    public static let file = "试听没放起来：这首的试听文件放不了。请如实说没放成，可以换一首；不要说版权或会员。"
    public static let engine = "试听没放起来：手机的声音通道没准备好。请如实说没放成，可以再试一次；不要说版权或会员。"

    /// `download_*`, `too_large`, `too_long` (§18 item 2), nil (still loading at 6 s) and `stopped` (not a driver-facing reason): network.
    public static func text(for failure: PreviewFailure?) -> String {
        switch failure {
        case .parse: file
        case .engine: engine
        case .downloadTimeout, .downloadNetwork, .downloadHTTP, .tooLarge, .tooLong, .stopped, nil: network
        }
    }
}
