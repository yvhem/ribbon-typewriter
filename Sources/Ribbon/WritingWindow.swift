import AppKit
import SwiftUI

enum PaperTheme {
    static let paper = adaptive("Ribbon Paper", light: 0xf8f3e9, dark: 0x24201d)
    static let ink = adaptive("Ribbon Ink", light: 0x302925, dark: 0xebe2d5)
    static let muted = adaptive("Ribbon Muted Ink", light: 0x74685e, dark: 0xb6a89b)
    static let rule = adaptive("Ribbon Rule", light: 0xe4d9c9, dark: 0x484039)
    static let accent = adaptive("Ribbon Accent", light: 0x865131, dark: 0xe3ac79)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255,
                alpha: 1
            )
        }
    }
}

enum RibbonDefaults {
    static let soundEnabled = "soundEnabled"
    static let volume = "soundVolume"
    static let soundStyle = "soundStyle"
    static let fontSize = "editorFontSize"

    static func register() {
        UserDefaults.standard.register(defaults: [
            soundEnabled: true, volume: 0.38, soundStyle: SoundStyle.soft.rawValue, fontSize: 17
        ])
    }
}

struct WritingWindow: View {
    @ObservedObject var session: WritingSession
    @AppStorage(RibbonDefaults.soundEnabled) private var soundEnabled = true
    @AppStorage(RibbonDefaults.fontSize) private var fontSize = 17.0

    var body: some View {
        VStack(spacing: 0) {
            if !session.focusMode {
                controls
                rule
            }
            GeometryReader { geometry in
                let current = session.presentation
                let pending = session.requestedPresentation
                let frames = PaneFrames(current, size: geometry.size)
                let nextFrames = PaneFrames(pending ?? current, size: geometry.size)

                ZStack(alignment: .topLeading) {
                    NativeEditor(session: session, fontSize: fontSize)
                        .frame(width: frames.editor.width, height: frames.editor.height)
                        .opacity(current.usesNativeEditor ? 1 : 0)
                        .allowsHitTesting(current.usesNativeEditor)
                        .accessibilityHidden(!current.usesNativeEditor)

                    if session.hasLiveSurface {
                        let size = current.usesLiveEditor ? frames.editor : nextFrames.editor
                        LiveEditor(session: session, fontSize: fontSize,
                                   active: current.usesLiveEditor,
                                   preparing: !current.usesLiveEditor && pending?.usesLiveEditor == true)
                            .frame(width: size.width, height: size.height)
                            .opacity(current.usesLiveEditor ? 1 : 0)
                            .allowsHitTesting(current.usesLiveEditor)
                            .accessibilityHidden(!current.usesLiveEditor)
                    }

                    if session.hasPreviewSurface {
                        let frame = current.showsPreview ? frames.preview : nextFrames.preview
                        MarkdownPreview(session: session, visible: current.showsPreview,
                                        preparing: !current.showsPreview && pending?.showsPreview == true)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .opacity(current.showsPreview ? 1 : 0)
                            .allowsHitTesting(current.showsPreview)
                            .accessibilityHidden(!current.showsPreview)
                    }

                    if let divider = frames.divider {
                        Rectangle()
                            .fill(Color(nsColor: PaperTheme.rule))
                            .frame(width: divider.width, height: divider.height)
                            .offset(x: divider.minX, y: divider.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
            if !session.focusMode { rule }
            status
        }
        .background(Color(nsColor: PaperTheme.paper))
        .tint(Color(nsColor: PaperTheme.accent))
        .onExitCommand {
            if session.focusMode { session.toggleFocus() }
        }
    }

    private var controls: some View {
        ZStack {
            Picker("Layout", selection: Binding<EditorLayout?>(
                get: { session.presentation.isPreviewing ? nil : session.presentation.layout },
                set: { if let layout = $0 { session.showLayout(layout) } }
            )) {
                ForEach(EditorLayout.allCases) { layout in
                    Text(layout.rawValue).tag(Optional(layout))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 112)
            .accessibilityLabel("Layout")
            .zIndex(1)

            HStack(spacing: 9) {
                Picker("Editing style", selection: Binding(
                    get: { session.presentation.style }, set: { session.showStyle($0) }
                )) {
                    ForEach(EditorStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 98)
                .accessibilityLabel("Editing style")

                Spacer(minLength: 0)

                Toggle("Preview", isOn: Binding(
                    get: { session.presentation.isPreviewing },
                    set: { _ in session.togglePreview() }
                ))
                .toggleStyle(PreviewToggleStyle())
                .help("Toggle Preview (⌘3)")

                Button {
                    soundEnabled.toggle()
                    if soundEnabled { KeySound.shared.play(.key) }
                } label: {
                    Image(systemName: soundEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: soundEnabled ? PaperTheme.accent : PaperTheme.muted))
                .accessibilityLabel(soundEnabled ? "Mute typing sounds" : "Unmute typing sounds")
                .help(soundEnabled ? "Mute typing sounds" : "Unmute typing sounds")
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 47)
    }

    private var status: some View {
        HStack(spacing: 9) {
            if !session.focusMode {
                Text("\(session.wordCount) \(session.wordCount == 1 ? "word" : "words")")
                Circle().frame(width: 2, height: 2).accessibilityHidden(true)
                Text("\(session.characterCount) \(session.characterCount == 1 ? "character" : "characters")")
            }
            Spacer()
            Button {
                session.toggleFocus()
            } label: {
                Image(systemName: session.focusMode ? "arrow.down.right.and.arrow.up.left" : "viewfinder")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.focusMode ? "Exit Focus Mode" : "Enter Focus Mode")
            .help(session.focusMode ? "Exit Focus Mode (Esc)" : "Focus Mode (⇧⌘F)")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(nsColor: PaperTheme.muted))
        .padding(.horizontal, 24)
        .frame(height: 31)
    }

    private var rule: some View {
        Rectangle().fill(Color(nsColor: PaperTheme.rule)).frame(height: 1)
    }
}

private struct PaneFrames {
    let editor: CGSize
    let preview: CGRect
    let divider: CGRect?

    init(_ presentation: EditorPresentation, size: CGSize) {
        guard presentation.layout == .split, !presentation.isPreviewing else {
            editor = size
            preview = CGRect(origin: .zero, size: size)
            divider = nil
            return
        }

        let stacked = size.width < 710
        let width = stacked ? size.width : max(0, (size.width - 1) / 2)
        let height = stacked ? max(0, (size.height - 1) / 2) : size.height
        let x = stacked ? 0 : width + 1
        let y = stacked ? height + 1 : 0
        editor = CGSize(width: width, height: height)
        preview = CGRect(x: x, y: y, width: max(1, size.width - x), height: max(1, size.height - y))
        divider = stacked ? CGRect(x: 0, y: height, width: size.width, height: 1)
            : CGRect(x: width, y: 0, width: 1, height: size.height)
    }
}

private struct PreviewToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(PreviewButtonStyle(isOn: configuration.isOn))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

private struct PreviewButtonStyle: ButtonStyle {
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isOn || configuration.isPressed
        let dark = colorScheme == .dark
        let ink = Color(nsColor: PaperTheme.ink)
        let face = ink.opacity(dark ? (pressed ? 0.08 : 0.21) : (pressed ? 0.15 : 0.08))
        let shape = RoundedRectangle(cornerRadius: 6)

        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink)
            .offset(y: pressed ? 1 : 0)
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background {
                if pressed {
                    shape.fill(face.shadow(.inner(color: .black.opacity(dark ? 0.55 : 0.25),
                                                  radius: 2, x: 0, y: 2)))
                } else {
                    shape.fill(face)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: pressed ? [.black.opacity(0.28), ink.opacity(0.18)]
                            : [ink.opacity(0.14), ink.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
    }
}

struct RibbonSettings: View {
    @AppStorage(RibbonDefaults.soundEnabled) private var enabled = true
    @AppStorage(RibbonDefaults.volume) private var volume = 0.38
    @AppStorage(RibbonDefaults.soundStyle) private var soundStyle = SoundStyle.soft
    @AppStorage(RibbonDefaults.fontSize) private var fontSize = 17.0

    var body: some View {
        Form {
            Section("Typewriter") {
                Toggle("Typing sounds", isOn: $enabled)
                HStack(spacing: 9) {
                    Text("Sound").accessibilityHidden(true)
                    Spacer()
                    Picker("Sound", selection: $soundStyle) {
                        Section("Mechanical Keyboards") {
                            ForEach(SoundStyle.mechanicalKeyboards) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        Section("Typewriters") {
                            ForEach(SoundStyle.typewriters) { style in
                                Text(style.label).tag(style)
                            }
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Sound")
                    .frame(width: 184)

                    Button {
                        KeySound.shared.preview()
                    } label: {
                        Label("Play sound preview", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Play sound preview")
                    .help("Play sound preview")
                    .disabled(!enabled || volume == 0)
                }
                .accessibilityElement(children: .contain)
                LabeledContent("Volume") {
                    Slider(value: $volume, in: 0...1) { Text("Volume") } onEditingChanged: { dragging in
                        if !dragging { KeySound.shared.play(.key) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Volume")
                    .disabled(!enabled)
                    .frame(width: 140)
                }
            }
            Section("Editor") {
                Stepper("Text size · \(Int(fontSize)) pt", value: $fontSize, in: 12...30, step: 1)
            }
        }
        .formStyle(.grouped)
        .frame(width: 390, height: 265)
        .onChange(of: soundStyle) { _, _ in KeySound.shared.cancelPreview() }
        .onChange(of: enabled) { _, enabled in
            if !enabled { KeySound.shared.cancelPreview() }
        }
        .onDisappear { KeySound.shared.cancelPreview() }
    }
}
