import SwiftUI
import UIKit
import WebKit

/// F-18 §16 item 8 (T-046d): Google's Search Suggestions for her latest searched answer, shown only to this driver.
/// The HTML is Google's `renderedContent`; links open in the browser, never inside the app. Nothing is cached.
struct SearchSuggestionView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        let page = "<html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"margin:0\">\(html)</body></html>"
        view.loadHTMLString(page, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The page itself loads in place; every link the driver taps opens in the browser.
            if action.navigationType == .linkActivated || action.targetFrame == nil, let url = action.request.url,
               url.scheme == "https" || url.scheme == "http" {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return action.navigationType == .other ? .allow : .cancel
        }
    }
}
