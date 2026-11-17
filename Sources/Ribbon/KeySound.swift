import AVFoundation

enum SoundStyle: String, CaseIterable, Identifiable {
    case soft, classic, original
    case olympia, hermes, olivetti, corsair, selectric
    case rainy75, cherryblue, cherryred

    static let mechanicalKeyboards: [Self] = [.rainy75, .cherryblue, .cherryred]
    static let typewriters = allCases.filter { !mechanicalKeyboards.contains($0) }

    var id: Self { self }

    var label: String {
        switch self {
        case .soft: "Soft"
        case .classic: "Classic"
        case .original: "Original"
        case .olympia: "Olympia"
        case .hermes: "Hermes Baby"
        case .olivetti: "Olivetti"
        case .corsair: "Smith-Corona Corsair"
        case .selectric: "IBM Selectric II"
        case .rainy75: "Rainy 75 (Creamy)"
        case .cherryblue: "Cherry MX Blue"
        case .cherryred: "Cherry MX Red"
        }
    }
}

@MainActor
final class KeySound {
    enum Stroke: String, CaseIterable {
        case key, space, backspace, returnKey
    }

    static let shared = KeySound()
    private var loadedStyle: SoundStyle?
    private var players: [Stroke: [AVAudioPlayer]] = [:]
    private var next: [Stroke: Int] = [:]
    private var previewTask: Task<Void, Never>?

    private init() {}

    private func load(_ style: SoundStyle) {
        let folder = Assets.bundle.resourceURL!
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(style.rawValue, isDirectory: true)
        let samples = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []

        for stroke in Stroke.allCases {
            players[stroke]?.forEach { $0.stop() }
            players[stroke] = samples
                .filter { $0.pathExtension == "wav" && $0.lastPathComponent.hasPrefix(stroke.rawValue + "-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url in
                    guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                    player.prepareToPlay()
                    return player
                }
        }
        next.removeAll()
        loadedStyle = style
    }

    func play(_ stroke: Stroke) {
        let preferences = UserDefaults.standard
        let volume = preferences.double(forKey: RibbonDefaults.volume)
        guard preferences.bool(forKey: RibbonDefaults.soundEnabled), volume > 0 else { return }

        let style = SoundStyle(rawValue: preferences.string(forKey: RibbonDefaults.soundStyle) ?? "") ?? .soft
        if loadedStyle != style { load(style) }

        guard let variants = players[stroke], !variants.isEmpty else { return }
        let index = next[stroke, default: 0]
        let player = variants[index]
        next[stroke] = (index + 1) % variants.count
        player.currentTime = 0
        player.volume = Float(volume)
        player.play()
    }

    func preview() {
        cancelPreview()
        previewTask = Task { [weak self] in
            let strokes: [Stroke] = [.key, .key, .space, .key, .backspace, .returnKey]
            for stroke in strokes {
                guard !Task.isCancelled else { return }
                self?.play(stroke)
                try? await Task.sleep(for: .milliseconds(135))
            }
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }
}
