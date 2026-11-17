import AppKit
import SwiftUI
import WebKit

// CodeMirror uses a single UTF-16 position for a line ending. Keep the original
// bytes of existing line endings in the Markdown document, including CRLF.
struct LiveEditorSource {
    let text: String
    let normalized: String
    let lineEnding: String
    private let offsets: [Int]?

    init(_ text: String) {
        self.text = text
        guard text.utf16.contains(13) else {
            normalized = text
            lineEnding = "\n"
            offsets = nil
            return
        }
        let source = Array(text.utf16)
        var boundaries = [0]
        var index = 0
        while index < source.count {
            index += source[index] == 13 && index + 1 < source.count && source[index + 1] == 10 ? 2 : 1
            boundaries.append(index)
        }
        offsets = boundaries
        lineEnding = text.range(of: "\r\n") != nil ? "\r\n" : "\r"
        normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    func original(_ range: NSRange) -> NSRange? {
        guard range.location >= 0, range.length >= 0,
              range.location <= normalized.utf16.count,
              range.length <= normalized.utf16.count - range.location else { return nil }
        guard let offsets else { return range }
        let start = offsets[range.location]
        return NSRange(location: start, length: offsets[NSMaxRange(range)] - start)
    }

    func editorRange(_ range: NSRange) -> NSRange {
        let sourceLength = text.utf16.count
        let start = min(range.location, sourceLength)
        let end = min(NSMaxRange(range), sourceLength)
        guard let offsets else { return NSRange(location: start, length: end - start) }
        let from = offsets.firstIndex(where: { $0 >= start }) ?? offsets.count - 1
        let to = offsets.firstIndex(where: { $0 >= end }) ?? offsets.count - 1
        return NSRange(location: from, length: to - from)
    }
}

struct SourceEdit {
    let range: NSRange
    let text: String
}

struct LiveEditor: NSViewRepresentable {
    @ObservedObject var session: WritingSession
    let fontSize: Double
    let active: Bool
    let preparing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "ribbonLive")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = PaperTheme.paper
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        let assets = Assets.bundle.resourceURL!.appendingPathComponent("Preview", isDirectory: true)
        context.coordinator.attach(view, location: assets.appendingPathComponent("live.html"), fontSize: fontSize)
        view.loadFileURL(assets.appendingPathComponent("live.html"), allowingReadAccessTo: assets)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.sync(fontSize: fontSize, active: active, preparing: preparing)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ribbonLive", contentWorld: .page)
        view.stopLoading()
        view.navigationDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        private weak var session: WritingSession?
        private weak var view: WKWebView?
        private var location: URL?
        private var size = 17.0
        private var source = LiveEditorSource("")
        private var generation = 0
        private var ready = false
        var isReady: Bool { ready }
        private var leaving = false
        private var active = false
        private var preparing = false
        private var preparationText: String?

        init(session: WritingSession) { self.session = session }

        func attach(_ view: WKWebView, location: URL, fontSize: Double) {
            self.view = view
            self.location = location
            size = fontSize
            session?.liveEditor = self
        }

        func detach() { ready = false }

        func sync(fontSize: Double, active: Bool, preparing: Bool) {
            self.active = active
            if self.preparing != preparing { preparationText = nil }
            self.preparing = preparing
            if size != fontSize {
                size = fontSize
                if ready { run("window.ribbonLiveEditor.setSize(size)", ["size": size]) }
            }
            refreshDocument()
        }

        private func refreshDocument() {
            guard ready, !leaving, let session else { return }
            if preparing {
                let text = session.text
                guard preparationText != text else { return }
                preparationText = text
                source = LiveEditorSource(text)
                generation += 1
                let expectedGeneration = generation
                view?.callAsyncJavaScript(
                    "window.ribbonLiveEditor.setDocument(source, generation, selection); await window.ribbonWaitForPaint()",
                    arguments: documentArguments(), in: nil, in: .page
                ) { [weak self] result in
                    guard let self, preparing, generation == expectedGeneration else { return }
                    if case .success = result {
                        self.session?.liveSurfacePrepared(source: text)
                    } else {
                        ready = false
                        self.session?.recoverFromLiveEditorFailure()
                    }
                }
            } else if active, source.text != session.text {
                source = LiveEditorSource(session.text)
                generation += 1
                run("window.ribbonLiveEditor.setDocument(source, generation, selection)", documentArguments())
            }
        }

        func focus() {
            guard ready, let view else { return }
            view.window?.makeFirstResponder(view)
            run("window.ribbonLiveEditor.focus()")
        }

        func finishEditing() {
            guard let session else { return }
            guard ready, !leaving else {
                if !leaving { session.completeLiveTransition() }
                return
            }
            leaving = true
            run("await window.ribbonLiveEditor.finish()") { [weak self] in
                guard let self, leaving else { return }
                leaving = false
                session.completeLiveTransition()
            }
        }

        func insertMath(display: Bool) {
            run("window.ribbonLiveEditor.insertMath(display)", ["display": display])
        }

        func command(_ action: String) {
            run("await window.ribbonLiveEditor.command(action)", ["action": action])
        }

        func find(_ action: String) {
            run("window.ribbonLiveEditor.find(action)", ["action": action])
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let session else { return }
            source = LiveEditorSource(session.text)
            let initialText = source.text
            generation += 1
            var arguments = documentArguments()
            arguments["size"] = size
            webView.callAsyncJavaScript(
                "window.ribbonLiveEditor.start(source, generation, selection, size); await window.ribbonWaitForPaint()",
                arguments: arguments, in: nil, in: .page
            ) { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    ready = true
                    if preparing, self.session?.text == initialText {
                        preparationText = initialText
                        self.session?.liveSurfacePrepared(source: initialText)
                    } else {
                        refreshDocument()
                    }
                    if active {
                        focus()
                        self.session?.insertPendingMath()
                    }
                } else {
                    self.session?.recoverFromLiveEditorFailure()
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            preparationText = nil
            if leaving {
                leaving = false
                session?.completeLiveTransition()
            } else {
                webView.reload()
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            ready = false
            session?.recoverFromLiveEditorFailure()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigation: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigation.request.url
            let matching = url?.isFileURL == true
                && url?.resolvingSymlinksInPath().path == location?.resolvingSymlinksInPath().path
            decisionHandler(matching ? .allow : .cancel)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, ready, active, let session,
                  let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String,
                  payload["generation"] as? Int == generation else {
                replyHandler(nil, nil)
                return
            }
            switch kind {
            case "edit":
                guard let changes = payload["changes"] as? [[String: Any]],
                      let before = range(payload["before"]), let after = range(payload["after"]),
                      source.text == session.text else {
                    replyHandler(nil, nil)
                    return
                }
                let edits = changes.compactMap { change -> SourceEdit? in
                    guard let editorRange = range(change), let original = source.original(editorRange),
                          let text = change["text"] as? String else { return nil }
                    let replacement = text.replacingOccurrences(of: "\n", with: source.lineEnding)
                    return SourceEdit(range: original, text: replacement)
                }
                if edits.count == changes.count {
                    session.applyLiveEdits(edits, before: before, after: after)
                    source = LiveEditorSource(session.text)
                    if let identifier = payload["stroke"] as? String, let stroke = KeySound.Stroke(rawValue: identifier) {
                        KeySound.shared.play(stroke)
                    }
                }
                replyHandler(nil, nil)
            case "undo", "redo":
                if let selection = range(payload["selection"]) { session.liveSelection = selection }
                if kind == "undo" {
                    session.document?.undoManager?.undo()
                } else {
                    session.document?.undoManager?.redo()
                }
                source = LiveEditorSource(session.text)
                replyHandler(documentArguments(), nil)
            case "leave":
                if let selection = range(payload["selection"]) { session.liveSelection = selection }
                replyHandler(nil, nil)
                leaving = false
                session.completeLiveTransition()
            case "escape":
                if let selection = range(payload["selection"]) { session.liveSelection = selection }
                if session.focusMode { session.toggleFocus() }
                replyHandler(nil, nil)
            default:
                replyHandler(nil, nil)
            }
        }

        private func range(_ value: Any?) -> NSRange? {
            guard let dictionary = value as? [String: Any],
                  let from = dictionary["from"] as? Int, let to = dictionary["to"] as? Int,
                  from >= 0, to >= from else { return nil }
            return NSRange(location: from, length: to - from)
        }

        private func documentArguments() -> [String: Any] {
            let selection = session?.liveSelection ?? NSRange(location: 0, length: 0)
            return [
                "source": source.normalized, "generation": generation,
                "selection": ["from": selection.location, "to": NSMaxRange(selection)]
            ]
        }

        private func run(_ script: String, _ args: [String: Any] = [:], completion: (() -> Void)? = nil) {
            guard ready, let view else { completion?(); return }
            view.callAsyncJavaScript(script, arguments: args, in: nil, in: .page) { _ in completion?() }
        }
    }
}
