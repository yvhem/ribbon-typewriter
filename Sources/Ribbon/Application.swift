import AppKit
import SwiftUI

@main
enum RibbonApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = RibbonDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class RibbonDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var settings: NSWindowController?
    private var session: WritingSession? {
        (NSDocumentController.shared.currentDocument as? RibbonDocument)?.session
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        RibbonDefaults.register()
        NSDocumentController.shared.autosavingDelay = 5
        installMenu()
    }

    @objc private func showSettings(_ sender: Any?) {
        if settings == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: RibbonSettings()))
            window.title = "Ribbon Settings"
            window.styleMask = [.titled, .closable]
            window.center()
            settings = NSWindowController(window: window)
        }
        settings?.showWindow(sender)
        settings?.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func showSource() { session?.showStyle(.source) }
    @objc private func showLive() { session?.showStyle(.live) }
    @objc private func showEditor() { session?.showLayout(.editor) }
    @objc private func showSplit() { session?.showLayout(.split) }
    @objc private func togglePreview() { session?.togglePreview() }
    @objc private func toggleFocus() { session?.toggleFocus() }
    @objc private func insertInlineMath() { session?.insertMath(display: false) }
    @objc private func insertDisplayMath() { session?.insertMath(display: true) }

    @objc private func toggleSound() {
        let prefs = UserDefaults.standard
        let enabled = !prefs.bool(forKey: RibbonDefaults.soundEnabled)
        prefs.set(enabled, forKey: RibbonDefaults.soundEnabled)
        if enabled { KeySound.shared.play(.key) }
    }

    @objc private func increaseSize() { changeSize(by: 1) }
    @objc private func decreaseSize() { changeSize(by: -1) }
    @objc private func resetSize() { UserDefaults.standard.set(17.0, forKey: RibbonDefaults.fontSize) }

    @objc private func editUndo(_ sender: NSMenuItem) {
        let redo = sender.tag == 1
        if session?.presentation.usesLiveEditor == true {
            session?.liveEditor?.command(redo ? "redo" : "undo")
        } else {
            NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: sender)
        }
    }

    @objc private func editFind(_ sender: NSMenuItem) {
        if session?.presentation.usesLiveEditor == true {
            let action: String
            switch sender.tag {
            case Int(NSFindPanelAction.next.rawValue): action = "next"
            case Int(NSFindPanelAction.previous.rawValue): action = "previous"
            default: action = "show"
            }
            session?.liveEditor?.find(action)
        } else {
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
        }
    }

    private func changeSize(by amount: Double) {
        let prefs = UserDefaults.standard
        let size = prefs.double(forKey: RibbonDefaults.fontSize)
        prefs.set(min(30, max(12, size + amount)), forKey: RibbonDefaults.fontSize)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showSource): return validateStyle(.source, item: item)
        case #selector(showLive): return validateStyle(.live, item: item)
        case #selector(showEditor): return validateLayout(.editor, item: item)
        case #selector(showSplit): return validateLayout(.split, item: item)
        case #selector(togglePreview):
            item.state = session?.presentation.isPreviewing == true ? .on : .off
            return session != nil
        case #selector(toggleFocus):
            item.state = session?.focusMode == true ? .on : .off
            return session != nil
        case #selector(toggleSound):
            item.state = UserDefaults.standard.bool(forKey: RibbonDefaults.soundEnabled) ? .on : .off
            return true
        case #selector(editUndo(_:)):
            let manager = session?.document?.undoManager
            let redo = item.tag == 1
            item.title = (redo ? manager?.redoMenuItemTitle : manager?.undoMenuItemTitle) ?? (redo ? "Redo" : "Undo")
            return redo ? manager?.canRedo == true : manager?.canUndo == true
        case #selector(editFind(_:)), #selector(insertInlineMath), #selector(insertDisplayMath):
            return session != nil
        default:
            return true
        }
    }

    private func validateStyle(_ style: EditorStyle, item: NSMenuItem) -> Bool {
        item.state = session?.presentation.style == style ? .on : .off
        return session != nil
    }

    private func validateLayout(_ layout: EditorLayout, item: NSMenuItem) -> Bool {
        item.state = session?.presentation.layout == layout ? .on : .off
        return session != nil
    }

    private func installMenu() {
        let main = NSMenu()
        let documents = NSDocumentController.shared

        func menu(_ title: String) -> NSMenu {
            let root = NSMenuItem()
            let child = NSMenu(title: title)
            root.submenu = child
            main.addItem(root)
            return child
        }

        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
            return item
        }

        let app = menu("Ribbon")
        add(app, "About Ribbon", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        app.addItem(serviceItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "Hide Ribbon", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Ribbon", #selector(NSApplication.terminate(_:)), "q")

        let file = menu("File")
        add(file, "New", #selector(NSDocumentController.newDocument(_:)), "n", target: documents)
        add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: documents)
        let recents = NSMenu(title: "Open Recent")
        recents.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                  keyEquivalent: ""))
        let recentItem = NSMenuItem(title: "Open Recent", action: Selector(("openRecentDocument:")), keyEquivalent: "")
        recentItem.submenu = recents
        file.addItem(recentItem)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Save…", #selector(NSDocument.save(_:)), "s")
        add(file, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", modifiers: [.command, .shift])
        add(file, "Rename…", #selector(NSDocument.rename(_:)))
        add(file, "Move To…", #selector(NSDocument.move(_:)))

        let edit = menu("Edit")
        add(edit, "Undo", #selector(editUndo(_:)), "z", target: self)
        add(edit, "Redo", #selector(editUndo(_:)), "z", modifiers: [.command, .shift], target: self).tag = 1
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = add(edit, "Find…", #selector(editFind(_:)), "f", target: self)
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let findNext = add(edit, "Find Next", #selector(editFind(_:)), "g", target: self)
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        let findPrevious = add(edit, "Find Previous", #selector(editFind(_:)), "g",
                               modifiers: [.command, .shift], target: self)
        findPrevious.tag = Int(NSFindPanelAction.previous.rawValue)

        let insert = menu("Insert")
        add(insert, "Inline Equation", #selector(insertInlineMath), "m", modifiers: [.command, .option], target: self)
        add(insert, "Display Equation", #selector(insertDisplayMath), "m",
            modifiers: [.command, .option, .shift], target: self)

        let view = menu("View")
        add(view, "Editor", #selector(showEditor), "1", target: self)
        add(view, "Split", #selector(showSplit), "2", target: self)
        add(view, "Preview", #selector(togglePreview), "3", target: self)
        view.addItem(.separator())
        add(view, "Source", #selector(showSource), "4", modifiers: [.command, .option], target: self)
        add(view, "Live", #selector(showLive), "4", target: self)
        view.addItem(.separator())
        add(view, "Focus Mode", #selector(toggleFocus), "f", modifiers: [.command, .shift], target: self)
        add(view, "Typing Sounds", #selector(toggleSound), "k", modifiers: [.command, .shift], target: self)
        view.addItem(.separator())
        add(view, "Bigger Text", #selector(increaseSize), "=", target: self)
        add(view, "Smaller Text", #selector(decreaseSize), "-", target: self)
        add(view, "Default Text Size", #selector(resetSize), "0", target: self)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])

        let window = menu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
