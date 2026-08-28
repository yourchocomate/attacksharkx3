import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the menu bar so the window can switch to settings.
    ///
    /// A notification rather than a shared AppState: the menu is built by the
    /// app delegate and the state belongs to the view, and making it a
    /// singleton just to connect them would outlive its usefulness.
    static let asctlShowSettings = Notification.Name("asctl.showSettings")
    static let asctlShowDevice = Notification.Name("asctl.showDevice")
}

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

        installStatusItem()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window hides the app rather than quitting it.
    ///
    /// The listener, the scroll tap and the device watch all have to keep
    /// running for the app to be any use in the background, so terminating on
    /// last-window-close would silently stop the very things the user asked to
    /// keep working. The menu bar item is how you get the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu bar

    private var statusItem: NSStatusItem?

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "computermouse", accessibilityDescription: "asctl")
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Mouse", action: #selector(openFromMenu), keyEquivalent: "1")
            .target = self
        menu.addItem(
            withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Reveal config folder", action: #selector(revealConfig),
            keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit asctl", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc func openFromMenu() {
        showWindow()
        NotificationCenter.default.post(name: .asctlShowDevice, object: nil)
    }

    @objc func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configDirectory])
    }

    @objc func openSettings() {
        showWindow()
        NotificationCenter.default.post(name: .asctlShowSettings, object: nil)
    }
}

func runGUI() -> Never {
    guard #available(macOS 12.0, *) else {
        FileHandle.standardError.write(Data("asctl gui requires macOS 12 or later.\n".utf8))
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = GUIAppDelegate()
    app.delegate = delegate
    // After the delegate exists — the Settings item targets it.
    installMenuBar()
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
    let settingsItem = appMenu.addItem(
        withTitle: "Settings…", action: #selector(GUIAppDelegate.openSettings),
        keyEquivalent: ",")
    settingsItem.target = NSApp.delegate
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Hide asctl", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(
        withTitle: "Quit asctl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let mouseEntry = viewMenu.addItem(
        withTitle: "Mouse", action: #selector(GUIAppDelegate.openFromMenu),
        keyEquivalent: "1")
    mouseEntry.target = NSApp.delegate
    let settingsEntry = viewMenu.addItem(
        withTitle: "Settings", action: #selector(GUIAppDelegate.openSettings),
        keyEquivalent: "2")
    settingsEntry.target = NSApp.delegate
    viewItem.submenu = viewMenu
    mainMenu.addItem(viewItem)

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
