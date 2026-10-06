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
final class GUIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    /// One state object for the whole app. The menu bar popover shows the same
    /// live values as the window, which is only true if they share this.
    let state = AppState()
    private var popover: NSPopover?
    private var titleTimer: Timer?

    /// Whether this process was started by the login item.
    ///
    /// Kept so closing the window can put the app back where it came from. A
    /// launch someone performed deliberately keeps its Dock icon on close, as
    /// it always has; one that happened at login returns to the menu bar.
    private let startedInBackground: Bool

    init(background: Bool) {
        self.startedInBackground = background
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        guard !startedInBackground else {
            // No window and no activation. The menu bar item is the whole UI
            // until the user asks for more.
            state.note("started in the background — open from the menu bar")
            upgradeLoginItemIfNeeded()
            return
        }
        makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        upgradeLoginItemIfNeeded()
    }

    /// Rewrite a login item written before --background existed.
    ///
    /// Without this, anyone who already had "open at login" switched on would
    /// keep getting the window at every startup until they thought to toggle
    /// it off and on again.
    private func upgradeLoginItemIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            guard ScrollController.AppLogin.installed,
                  ScrollController.AppLogin.needsUpgrade
            else { return }
            try? ScrollController.AppLogin.install()
            DispatchQueue.main.async {
                self.state.note("updated the login item to start in the background")
            }
        }
    }

    /// Build the main window.
    ///
    /// `isReleasedWhenClosed` defaults to **true**, so AppKit frees an NSWindow
    /// the moment it is closed. That was harmless while the app quit with its
    /// last window; once it started living in the menu bar instead, closing the
    /// window and reopening it sent a message to freed memory and crashed —
    /// `objc_msgSend` on a dangling pointer from `makeKeyAndOrderFront:`.
    @discardableResult
    private func makeWindow() -> NSWindow {
        if let existing = window { return existing }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "asctl — Attack Shark X3"
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(state: state))
        window.center()
        window.setFrameAutosaveName("asctl.main")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        return window
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

    /// Give the Dock icon back when the window goes, if that is where we began.
    func windowWillClose(_ notification: Notification) {
        guard startedInBackground else { return }
        // After the close completes, or the policy change races the teardown
        // and the window is left behind as an empty frame.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        // A menu bar launch has no Dock icon; give it one as soon as there is a
        // window to go with it, or the window cannot be reached from Cmd-Tab.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        // Rebuild rather than assume one survives. Belt and braces alongside
        // isReleasedWhenClosed: a nil window here should reopen the app, not
        // silently do nothing.
        makeWindow().makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu bar

    private var statusItem: NSStatusItem?

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let symbol = NSImage(
            systemSymbolName: "computermouse", accessibilityDescription: "asctl")
        symbol?.isTemplate = true
        item.button?.image = symbol
        item.button?.imagePosition = symbol == nil ? .noImage : .imageLeading
        // A status item whose image failed to load and whose title is empty has
        // zero width, so it is present and invisible — indistinguishable from
        // not being created at all. Give it text to fall back on.
        if symbol == nil { item.button?.title = "asctl" }

        // Order matters here, and getting it wrong makes the icon vanish.
        //
        // autosaveName restores the item's saved *visibility* as well as its
        // position. Setting it after isVisible therefore overrode the value
        // just assigned: once macOS had recorded the item as hidden — which it
        // does when the menu bar is too full to place it — every later launch
        // restored that and the icon never came back.
        item.autosaveName = "asctl.statusItem"
        item.isVisible = true

        let visible = item.isVisible
        if symbol == nil || !visible {
            let line = "asctl: menu bar item — image "
                + (symbol == nil ? "missing" : "ok")
                + ", visible \(visible)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: MenuBarView(
                state: state,
                onOpen: { [weak self] in self?.closePopover(); self?.openFromMenu() },
                onSettings: { [weak self] in self?.closePopover(); self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }))
        popover.contentViewController = hosting
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
            // Size to the content every time it opens.
            //
            // A fixed contentSize leaves empty space below short content — the
            // panel grows and shrinks as the battery and DPI stage become known
            // — and that padding reads as the popover hanging away from the
            // menu bar rather than as the popover simply being too tall.
            if let content = popover.contentViewController?.view {
                let fitting = content.fittingSize
                if fitting.height > 1 {
                    popover.contentSize = NSSize(
                        width: max(260, fitting.width), height: fitting.height)
                }
            }
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

    /// Check from the app menu, and open the panel that shows the result.
    @objc func checkForUpdates() {
        state.checkForUpdate()
        togglePopover()
    }

    @objc func openSettings() {
        showWindow()
        NotificationCenter.default.post(name: .asctlShowSettings, object: nil)
    }
}

/// Hand over to a copy that is already running, if there is one.
///
/// Turning on "open at login" bootstraps a launchd job, and the job carries
/// RunAtLoad because that is what starts it at login — so launchd spawns a
/// second asctl the instant the switch is flipped. That appeared as a window
/// opening by itself, which is how this was found.
///
/// The spawn is unavoidable: RunAtLoad is required for the feature to work at
/// all. What is avoidable is two copies existing, and two would be worse than
/// the stray window — they would fight over one event tap, one HID device and
/// one menu bar item, each unaware of the other.
///
/// Activating rather than exiting silently also fixes the ordinary case: with
/// asctl already resident in the menu bar, opening it from Finder now brings
/// the running copy forward instead of doing nothing visible.
@available(macOS 12.0, *)
private func handOverToRunningInstance() -> Bool {
    guard let identifier = Bundle.main.bundleIdentifier else { return false }
    let mine = ProcessInfo.processInfo.processIdentifier
    let existing = NSRunningApplication
        .runningApplications(withBundleIdentifier: identifier)
        .first { $0.processIdentifier != mine && !$0.isTerminated }
    guard let existing else { return false }
    existing.activate(options: [.activateAllWindows])
    return true
}

func runGUI(background: Bool = false) -> Never {
    guard #available(macOS 12.0, *) else {
        FileHandle.standardError.write(Data("asctl gui requires macOS 12 or later.\n".utf8))
        exit(1)
    }
    // Before anything is built, so a duplicate launch costs nothing and leaves
    // no window, menu bar item or event tap behind.
    if handOverToRunningInstance() { exit(0) }

    let app = NSApplication.shared
    // Accessory means menu bar only: no Dock icon, no window, nothing taking
    // focus. Opening at login should not interrupt whatever someone is doing,
    // and a config tool for a mouse has no business being the front app every
    // time the machine starts.
    app.setActivationPolicy(background ? .accessory : .regular)
    let delegate = GUIAppDelegate(background: background)
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
    let updateItem = appMenu.addItem(
        withTitle: "Check for Updates…", action: #selector(GUIAppDelegate.checkForUpdates),
        keyEquivalent: "")
    updateItem.target = NSApp.delegate
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
