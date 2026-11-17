import AppKit
import SwiftUI
import WebKit

struct MarkdownPreview: NSViewRepresentable {
    let session: WritingSession
    let visible: Bool
    let preparing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setAccessibilityLabel("Rendered Markdown")
        view.underPageBackgroundColor = PaperTheme.paper
        view.navigationDelegate = context.coordinator
        let assets = Assets.bundle.resourceURL!.appendingPathComponent("Preview", isDirectory: true)
        let location = assets.appendingPathComponent("index.html")
        context.coordinator.location = location
        view.loadFileURL(location, allowingReadAccessTo: assets)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(session.text, visible: visible, preparing: preparing, in: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.stopLoading()
        view.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var location: URL?
        private weak var session: WritingSession?
        private var renderTask: Task<Void, Never>?
        private var source = ""
        private var rendered: String?
        private var visible = false
        private var preparing = false
        private var ready = false
        private var revision = 0

        init(session: WritingSession) { self.session = session }

        func stop() {
            renderTask?.cancel()
            revision += 1
        }

        func update(_ text: String, visible: Bool, preparing: Bool, in view: WKWebView) {
            guard source != text || self.visible != visible || self.preparing != preparing else { return }
            source = text
            self.visible = visible
            self.preparing = preparing
            requestRender(in: view)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            requestRender(in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            session?.cancelPreviewTransition()
            NSLog("Could not load preview: %@", error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            stop()
            ready = false
            rendered = nil
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL,
               url.resolvingSymlinksInPath().path == location?.resolvingSymlinksInPath().path {
                decisionHandler(.allow)
                return
            }
            if visible, navigationAction.navigationType == .linkActivated,
               let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        private func requestRender(in view: WKWebView) {
            stop()
            guard ready, visible || preparing else { return }
            let text = source
            let currentRevision = revision
            let waitForHandoff = preparing
            let needsRender = text != rendered

            renderTask = Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                if needsRender && !waitForHandoff { try? await Task.sleep(for: .milliseconds(120)) }
                guard !Task.isCancelled else { return }
                if needsRender {
                    let script = waitForHandoff
                        ? "window.renderMarkdown(source); await window.ribbonWaitForPaint()"
                        : "window.renderMarkdown(source)"
                    let result = await withCheckedContinuation { continuation in
                        view.callAsyncJavaScript(script, arguments: ["source": text], in: nil, in: .page) {
                            continuation.resume(returning: $0)
                        }
                    }
                    if case let .failure(error) = result {
                        if currentRevision == revision {
                            session?.cancelPreviewTransition()
                            NSLog("Could not update preview: %@", error.localizedDescription)
                        }
                        return
                    }
                }
                guard currentRevision == revision, !Task.isCancelled else { return }
                rendered = text
                if waitForHandoff { session?.previewSurfacePrepared(source: text) }
            }
        }
    }
}
