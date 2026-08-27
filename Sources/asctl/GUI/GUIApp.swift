import AppKit
import SwiftUI

/// Bootstrapping the window without `@main`.
///
/// `main.swift` is a top-level-code file, and Swift forbids a second entry
/// point in the same module — so the usual `@main struct App: SwiftUI.App`
/// cannot be used here. Building the `NSApplication` by hand costs a few lines
/// and keeps the GUI and the CLI in one binary, with no duplicated protocol
/// code and nothing to keep in sync.
@available(macOS 12.0, *)
final class GUIAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "asctl — Attack Shark X3"
        window.contentView = NSHostingView(rootView: MainView())
        window.center()
        window.setFrameAutosaveName("asctl.main")
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func runGUI() -> Never {
    guard #available(macOS 12.0, *) else {
        FileHandle.standardError.write(Data("asctl gui requires macOS 12 or later.\n".utf8))
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    installMenuBar()
    let delegate = GUIAppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}

/// A bare-bones menu bar. Without one, the app runs but Cmd-Q does nothing and
/// text fields lose the standard edit shortcuts.
private func installMenuBar() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "About asctl", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Hide asctl", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(
        withTitle: "Quit asctl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    for (title, selector, key) in [
        ("Undo", Selector(("undo:")), "z"),
        ("Redo", Selector(("redo:")), "Z"),
        ("Cut", #selector(NSText.cut(_:)), "x"),
        ("Copy", #selector(NSText.copy(_:)), "c"),
        ("Paste", #selector(NSText.paste(_:)), "v"),
        ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] {
        editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
    }
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    NSApp.mainMenu = mainMenu
}
