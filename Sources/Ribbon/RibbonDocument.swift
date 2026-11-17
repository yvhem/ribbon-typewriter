import AppKit
import SwiftUI

enum EditorStyle: String, CaseIterable, Identifiable {
    case source = "Source"
    case live = "Live"

    var id: Self { self }
}

enum EditorLayout: String, CaseIterable, Identifiable {
    case editor = "Editor"
    case split = "Split"

    var id: Self { self }
}

struct EditorPresentation {
    var style: EditorStyle = .source
    var layout: EditorLayout = .editor
    var isPreviewing = false

    var showsPreview: Bool { isPreviewing || layout == .split }
    var usesLiveEditor: Bool { style == .live && !isPreviewing }
    var usesNativeEditor: Bool { style == .source && !isPreviewing }
}

final class WritingSession: ObservableObject {
    @Published var text = ""
    @Published private(set) var presentation = EditorPresentation()
    @Published var focusMode = false
    @Published private(set) var requestedPresentation: EditorPresentation?
    @Published private(set) var hasLiveSurface = false
    @Published private(set) var hasPreviewSurface = false
    @Published private(set) var wordCount = 0
    @Published private(set) var characterCount = 0

    weak var editor: TypewriterTextView?
    weak var liveEditor: LiveEditor.Coordinator?
    var liveSelection = NSRange(location: 0, length: 0)
    private var livePreparedSource: String?
    private var previewPreparedSource: String?
    private var flushedLiveEditor = false
    private var viewBeforeFocus: (layout: EditorLayout, isPreviewing: Bool)?
    private var pendingMathInsertion: Bool?
    weak var document: RibbonDocument?
    private var countTask: Task<Void, Never>?

    func updateText(_ source: String) {
        guard source != text else { return }
        text = source
        countTask?.cancel()
        countTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.wordCount = source.split(whereSeparator: \.isWhitespace).count
            self?.characterCount = source.count
        }
    }

    @MainActor func showStyle(_ style: EditorStyle) {
        var next = requestedPresentation ?? presentation
        next.style = style
        show(next)
    }

    @MainActor func showLayout(_ layout: EditorLayout) {
        var next = requestedPresentation ?? presentation
        next.layout = layout
        next.isPreviewing = false
        if layout == .split { focusMode = false }
        show(next)
    }

    @MainActor func togglePreview() {
        var next = requestedPresentation ?? presentation
        next.isPreviewing.toggle()
        if next.isPreviewing { focusMode = false }
        show(next)
    }

    @MainActor private func show(_ next: EditorPresentation) {
        if next.usesLiveEditor, !presentation.usesLiveEditor, requestedPresentation?.usesLiveEditor != true {
            liveSelection = LiveEditorSource(text).editorRange(editor?.selectedRange() ?? NSRange(location: 0, length: 0))
            livePreparedSource = nil
        }
        if next.showsPreview, !presentation.showsPreview, requestedPresentation?.showsPreview != true {
            previewPreparedSource = nil
        }
        requestedPresentation = next
        if next.usesLiveEditor { hasLiveSurface = true }
        if next.showsPreview { hasPreviewSurface = true }
        advancePresentation()
    }

    @MainActor func liveSurfacePrepared(source: String) {
        livePreparedSource = source
        advancePresentation()
    }

    @MainActor func previewSurfacePrepared(source: String) {
        previewPreparedSource = source
        advancePresentation()
    }

    @MainActor func completeLiveTransition() {
        flushedLiveEditor = true
        advancePresentation()
    }

    @MainActor func cancelPreviewTransition() {
        if !presentation.showsPreview, requestedPresentation?.showsPreview == true {
            requestedPresentation = nil
            flushedLiveEditor = false
            hasPreviewSurface = false
        }
    }

    @MainActor private func advancePresentation() {
        guard let next = requestedPresentation else { return }
        if next.usesLiveEditor, !presentation.usesLiveEditor, livePreparedSource != text { return }
        if next.showsPreview, !presentation.showsPreview, previewPreparedSource != text { return }

        if presentation.usesLiveEditor, !next.usesLiveEditor, !flushedLiveEditor, let liveEditor {
            liveEditor.finishEditing()
            return
        }

        requestedPresentation = nil
        flushedLiveEditor = false
        applyPresentation(next)
    }

    @MainActor private func applyPresentation(_ next: EditorPresentation) {
        if next.usesLiveEditor != presentation.usesLiveEditor {
            let source = LiveEditorSource(text)
            if next.usesLiveEditor {
                editor?.breakUndoCoalescing()
            } else if let editor, let selection = source.original(liveSelection) {
                if editor.string != text { editor.string = text }
                editor.setSelectedRange(selection)
            }
        }
        presentation = next
        if next.isPreviewing {
            editor?.window?.makeFirstResponder(nil)
        } else {
            focusEditor()
        }
    }

    @MainActor func toggleFocus() {
        var next = requestedPresentation ?? presentation
        if focusMode {
            focusMode = false
            if let previous = viewBeforeFocus {
                next.layout = previous.layout
                next.isPreviewing = previous.isPreviewing
            }
            viewBeforeFocus = nil
        } else {
            viewBeforeFocus = (next.layout, next.isPreviewing)
            focusMode = true
            next.layout = .editor
            next.isPreviewing = false
        }
        show(next)
    }

    @MainActor func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if presentation.usesLiveEditor {
                liveEditor?.focus()
                insertPendingMath()
            } else if presentation.usesNativeEditor, let editor {
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    @MainActor func insertMath(display: Bool) {
        if presentation.isPreviewing, presentation.style == .live {
            pendingMathInsertion = display
            showLayout(.editor)
            return
        }
        if presentation.isPreviewing { showLayout(.editor) }
        if presentation.usesLiveEditor {
            pendingMathInsertion = display
            insertPendingMath()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let editor = self?.editor else { return }
            editor.window?.makeFirstResponder(editor)
            editor.wrapMath(display: display)
        }
    }

    @MainActor func insertPendingMath() {
        guard let display = pendingMathInsertion, let liveEditor, liveEditor.isReady else { return }
        pendingMathInsertion = nil
        liveEditor.insertMath(display: display)
    }

    @MainActor func recoverFromLiveEditorFailure() {
        pendingMathInsertion = nil
        if presentation.usesLiveEditor || requestedPresentation?.usesLiveEditor == true {
            showStyle(.source)
        }
        hasLiveSurface = false
    }

    func applyLiveEdits(_ edits: [SourceEdit], before: NSRange, after: NSRange) {
        guard !edits.isEmpty else { return }
        let original = text as NSString
        var end = 0
        var delta = 0
        var inverse = [SourceEdit]()
        for edit in edits {
            guard edit.range.location >= end, edit.range.location <= original.length,
                  edit.range.length <= original.length - edit.range.location else { return }
            end = NSMaxRange(edit.range)
            let length = edit.text.utf16.count
            inverse.append(SourceEdit(
                range: NSRange(location: edit.range.location + delta, length: length),
                text: original.substring(with: edit.range)
            ))
            delta += length - edit.range.length
        }

        let edited = NSMutableString(string: text)
        for edit in edits.reversed() { edited.replaceCharacters(in: edit.range, with: edit.text) }
        let result = edited as String
        guard result != text else { return }
        flushedLiveEditor = false
        document?.undoManager?.registerUndo(withTarget: self) { target in
            target.applyLiveEdits(inverse, before: after, after: before)
            if !target.presentation.usesLiveEditor, let editor = target.editor,
               let selection = LiveEditorSource(target.text).original(before) {
                editor.setSelectedRange(selection)
            }
        }
        document?.undoManager?.setActionName("Typing")
        liveSelection = after
        updateText(result)
        if let editor, editor.string != result {
            editor.breakUndoCoalescing()
            editor.string = result
        }
    }
}

@objc(RibbonDocument)
final class RibbonDocument: NSDocument {
    let session = WritingSession()
    private static let markdownType = "net.daringfireball.markdown"

    override init() {
        super.init()
        session.document = self
        hasUndoManager = true
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let content = NSHostingController(rootView: WritingWindow(session: session))
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PaperTheme.paper
        window.setContentSize(NSSize(width: 900, height: 670))
        window.minSize = NSSize(width: 390, height: 360)
        window.center()
        window.setFrameAutosaveName("Ribbon Document")
        let controller = NSWindowController(window: window)
        addWindowController(controller)
        session.focusEditor()
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        if typeName == Self.markdownType || typeName == "Markdown" { return "md" }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(session.text.utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        session.updateText(source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source)
    }
}
