import NovaPorts

/// F-20b §2: which lens a camera question is about, from its words. Naming neither side, or both, keeps
/// the lens the window shows now.
public enum CameraLensChooser {
    static let rearWords = ["后面", "后边", "后方", "后排", "车后", "车里", "车内"]
    static let frontWords = ["前面", "前边", "前方", "路上"]

    public static func choose(_ question: String, current: CameraLens) -> CameraLens {
        let rear = rearWords.contains { question.contains($0) }
        let front = frontWords.contains { question.contains($0) }
        switch (rear, front) {
        case (true, false): return .rearView
        case (false, true): return .frontView
        default: return current
        }
    }
}
