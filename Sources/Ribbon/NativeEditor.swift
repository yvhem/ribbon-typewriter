import AppKit
import SwiftUI

struct NativeEditor: NSViewRepresentable {
    let session: WritingSession
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let editor = TypewriterTextView(frame: scroll.contentView.bounds)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.insertionPointColor = PaperTheme.accent
        editor.setAccessibilityLabel("Markdown editor")
        editor.session = session
        editor.string = session.text
        editor.applyTypography(size: fontSize)
        editor.resizeMargins(width: scroll.contentSize.width)
        editor.delegate = context.coordinator

        scroll.documentView = editor
        session.editor = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? TypewriterTextView else { return }
        if editor.string != session.text {
            editor.breakUndoCoalescing()
            editor.string = session.text
        }
        editor.applyTypography(size: fontSize)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var session: WritingSession?

        init(session: WritingSession) { self.session = session }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            session?.updateText(editor.string)
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            session?.document?.undoManager
        }
    }
}

final class TypewriterTextView: NSTextView {
    weak var session: WritingSession?
    private var currentSize: Double?
    private var stroke: KeySound.Stroke?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeMargins(width: newSize.width)
    }

    func resizeMargins(width: CGFloat) {
        let margin = width < 555 ? 25.0 : 44.0
        let inset = NSSize(width: max(margin, (width - 672) / 2), height: width < 555 ? 34 : 49)
        if textContainerInset != inset { textContainerInset = inset }
    }

    func applyTypography(size: Double) {
        guard currentSize != size else { return }
        currentSize = size
        let face = NSFont(name: "Courier New", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 3
        paragraph.tabStops = []
        paragraph.defaultTabInterval = size * 2.4
        defaultParagraphStyle = paragraph
        font = face
        textColor = PaperTheme.ink
        let attributes: [NSAttributedString.Key: Any] = [
            .font: face, .foregroundColor: PaperTheme.ink, .paragraphStyle: paragraph
        ]
        if let storage = textStorage {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        typingAttributes = attributes
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, session?.focusMode == true, !hasMarkedText() {
            session?.toggleFocus()
            return
        }
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            switch event.keyCode {
            case 36, 76: stroke = .returnKey
            case 49: stroke = .space
            case 51, 117: stroke = .backspace
            default: stroke = .key
            }
        }
        defer { stroke = nil }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        if let stroke {
            KeySound.shared.play(stroke)
            self.stroke = nil
        }
    }

    func wrapMath(display: Bool) {
        let selection = selectedRange()
        let source = string as NSString
        let selected = source.substring(with: selection)
        func isLineBreak(at offset: Int) -> Bool {
            guard let scalar = UnicodeScalar(source.character(at: offset)) else { return false }
            return CharacterSet.newlines.contains(scalar)
        }
        let open = display ? "$$\n" : "$"
        let close = display ? "\n$$" : "$"
        let atLineStart = selection.location == 0 || isLineBreak(at: selection.location - 1)
        let leading = display && !atLineStart ? "\n\n" : ""
        let end = NSMaxRange(selection)
        let atLineEnd = end == source.length || isLineBreak(at: end)
        let trailing = display && !atLineEnd ? "\n\n" : ""
        breakUndoCoalescing()
        insertText(leading + open + selected + close + trailing, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + (leading + open).utf16.count,
                                 length: selection.length))
        breakUndoCoalescing()
    }
}
