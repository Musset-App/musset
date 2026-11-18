import WebKit

/// A whole copy of a web page (text, images, style), as Safari keeps it: opened from the Bible even if the site goes.
@MainActor
final class WebArchiver: NSObject, WKNavigationDelegate {
    private let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
    private var done: CheckedContinuation<Data?, Never>?

    /// The page's web archive, or nil if it can't be had within 20 seconds.
    static func archive(_ url: URL) async -> Data? {
        let a = WebArchiver()
        return await a.load(url)
    }

    private func load(_ url: URL) async -> Data? {
        view.navigationDelegate = self
        return await withCheckedContinuation { c in
            done = c
            view.load(URLRequest(url: url))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finish(nil)
            }
        }
    }

    private func finish(_ data: Data?) {
        guard let c = done else { return }
        done = nil
        view.stopLoading()
        c.resume(returning: data)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // A moment for late images and fonts.
            try? await Task.sleep(for: .seconds(1))
            self.view.createWebArchiveData { result in
                Task { @MainActor in self.finish(try? result.get()) }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
