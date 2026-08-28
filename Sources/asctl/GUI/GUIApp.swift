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
    /// One state object for the whole app. The menu bar popover shows the same
    /// live values as the window, which is only true if they share this.
    let state = AppState()
    private var popover: NSPopover?
    private var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "asctl — Attack Shark X3"
        window.contentView = NSHostingView(rootView: MainView(state: state))
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
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 300)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                state: state,
                onOpen: { [weak self] in self?.closePopover(); self?.openFromMenu() },
                onSettings: { [weak self] in self?.closePopover(); self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }))
        self.popover = popover

        // The active DPI beside the icon: the one number worth having visible
        // without clicking anything, and the only device value that is reported
        // rather than assumed.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatusTitle()
        }
        RunLoop.main.add(timer, forMode: .common)
        titleTimer = timer
        refreshStatusTitle()
    }

    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        if let index = state.deviceActiveStage, state.stages.indices.contains(index) {
            button.title = " \(state.stages[index].dpi)"
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() { popover?.performClose(nil) }

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
    viewMenu.addItem(.separator())
    let revealEntry = viewMenu.addItem(
        withTitle: "Reveal Config Folder", action: #selector(GUIAppDelegate.revealConfig),
        keyEquivalent: "")
    revealEntry.target = NSApp.delegate
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
