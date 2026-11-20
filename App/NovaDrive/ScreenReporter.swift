import NovaKit
import SwiftUI

/// F-09b §16 item 2 (T-031z): each panel's view reports `on` in `onAppear` and `off` in `onDisappear`; the key is on
/// while at least one of its views is on screen (one panel can be drawn by two branches, and SwiftUI may show the new
/// branch before it removes the old). Reports apply in order to the one `ScreenStateStore`.
@MainActor
final class ScreenReporter {
    static let shared = ScreenReporter()

    let store: ScreenStateStore
    private let reports: AsyncStream<(ScreenPanel, Bool)>.Continuation
    private var shown: [ScreenPanel: Int] = [:]

    private init() {
        let store = ScreenStateStore()
        let (stream, continuation) = AsyncStream.makeStream(of: (ScreenPanel, Bool).self)
        self.store = store
        self.reports = continuation
        Task { for await (panel, on) in stream { await store.report(panel, on: on) } }
    }

    func report(_ panel: ScreenPanel, appeared: Bool) {
        let before = shown[panel, default: 0]
        let after = max(0, before + (appeared ? 1 : -1))
        shown[panel] = after
        if (before > 0) != (after > 0) { reports.yield((panel, after > 0)) }
    }
}

private struct ScreenPanelReport: ViewModifier {
    let panel: ScreenPanel
    func body(content: Content) -> some View {
        content
            .onAppear { ScreenReporter.shared.report(panel, appeared: true) }
            .onDisappear { ScreenReporter.shared.report(panel, appeared: false) }
    }
}

extension View {
    /// §16 item 2: this view is (part of) `panel`; it reports itself on screen while it is shown.
    func screenPanel(_ panel: ScreenPanel) -> some View { modifier(ScreenPanelReport(panel: panel)) }
}
