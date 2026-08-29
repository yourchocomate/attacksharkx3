import ApplicationServices
import CoreGraphics
import Foundation

/// Scroll direction independent of macOS's "Natural scrolling" preference.
///
/// macOS applies that single preference to the trackpad *and* every mouse, with
/// no way to separate them. Turning it on for the trackpad therefore inverts
/// the mouse wheel too. The X3 has no device-side scroll-direction setting —
/// nothing in the vendor UI or any config report touches it — so the only place
/// to fix this is on the host, by intercepting scroll events.
///
/// A `CGEventTap` sees every scroll event. Wheel and trackpad are distinguished
/// by `kCGScrollWheelEventIsContinuous`: trackpads and Magic Mice produce
/// *continuous* (pixel) scrolling, while a wheel produces *discrete* (line)
/// scrolling. Inverting only discrete events leaves the trackpad untouched.
enum ScrollDirection: String, CaseIterable, Identifiable {
    /// Do nothing — the mouse follows the macOS preference. Default.
    case follow
    /// Traditional direction, whatever macOS is set to.
    case standard
    /// Natural direction, whatever macOS is set to.
    case natural

    var id: String { rawValue }

    /// Short form for a segmented control.
    var short: String {
        switch self {
        case .follow: return "Follow macOS"
        case .standard: return "Traditional"
        case .natural: return "Natural"
        }
    }

    var label: String {
        switch self {
        case .follow: return "follow the macOS setting (no interception)"
        case .standard: return "always traditional (content moves opposite the wheel)"
        case .natural: return "always natural (content follows the wheel)"
        }
    }
}

enum ScrollController {
    /// Whether macOS "Natural scrolling" is currently on.
    ///
    /// Backed by the `com.apple.swipescrolldirection` global preference, which
    /// is what the Trackpad and Mouse panes both write.
    static var macOSNaturalScrolling: Bool {
        // Read the global domain directly rather than through UserDefaults.
        //
        // UserDefaults caches, and the obvious way to force a re-read —
        // removeObject on the key — does not invalidate anything: it writes a
        // *removal* into this process's own domain, which then shadows the
        // global value. The read then falls through to the "absent" default of
        // true, and a tap keyed off it silently stops inverting a couple of
        // seconds after starting.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyAppValue(
            "com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication)
        if let number = value as? NSNumber { return number.boolValue }
        // Absent means the factory default, which is natural scrolling on.
        return true
    }

    /// Whether events need flipping to reach `desired` from the current setting.
    static func shouldInvert(_ desired: ScrollDirection) -> Bool {
        switch desired {
        case .follow: return false
        case .natural: return !macOSNaturalScrolling
        case .standard: return macOSNaturalScrolling
        }
    }

    /// Whether the callback should currently flip events.
    ///
    /// A C function pointer cannot capture, so this has to be global — but it
    /// also has to be *live*. The first version decided once at startup, which
    /// is wrong for something that runs from login onwards: toggling macOS
    /// natural scrolling while the agent is running would leave it inverting in
    /// the wrong direction, and the user would have to know to restart it.
    fileprivate static var invertNow = false
    /// Log every event the inverting callback touches.
    fileprivate static var verbose = false

    /// Re-read the preference and update `invertNow`.
    ///
    /// Cheap, but not cheap enough to do per scroll event — a timer drives it.
    static func refreshInversion(_ desired: ScrollDirection) {
        let wanted = shouldInvert(desired)
        if wanted != invertNow {
            invertNow = wanted
            print("macOS natural scrolling changed — "
                + (wanted ? "now inverting the wheel" : "no longer inverting"))
        }
    }

    /// Whether this process holds Accessibility permission, optionally asking
    /// for it.
    ///
    /// `CGEvent.tapCreate` does **not** trigger the system prompt — it simply
    /// returns nil when the permission is missing, so a user who has never seen
    /// a dialog is told to grant something they were never asked for. The
    /// Accessibility API does prompt, so ask through that first.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// The path macOS will list in the Accessibility pane, which is not always
    /// what the user thinks they are granting.
    static var requestingProcessPath: String {
        Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.path
            : ProcessInfo.processInfo.arguments.first.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            } ?? "(unknown)"
    }

    /// Create and arm the tap on the current run loop, without blocking.
    ///
    /// Split out from `run` so the GUI can host the tap on its own run loop.
    @discardableResult
    static func start(_ desired: ScrollDirection) -> Bool {
        invertNow = shouldInvert(desired)

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, _ in
                // macOS disables a tap that stops responding. Re-arm rather
                // than dying silently — for an agent running from login, a tap
                // that quietly stopped would look exactly like the feature not
                // working.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = ScrollController.activeTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard ScrollController.invertNow else {
                    if ScrollController.verbose {
                        print("  pass-through (not inverting)")
                    }
                    return Unmanaged.passUnretained(event)
                }
                // Continuous means trackpad / Magic Mouse — leave those alone,
                // otherwise this would undo natural scrolling everywhere.
                if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
                    if ScrollController.verbose { print("  trackpad — left alone") }
                    return Unmanaged.passUnretained(event)
                }
                // Capture every field *before* writing any of them.
                //
                // Setting scrollWheelEventDeltaAxis1 makes CoreGraphics
                // recompute the point and fixed-point deltas from it. A loop
                // that reads and writes field by field therefore reads an
                // already-negated value for the later fields and negates it
                // back — leaving the line delta correct and the pixel delta
                // untouched. Apps that scroll smoothly use the pixel delta, so
                // the visible result was no change at all, while a log checking
                // only the line delta showed a correct flip.
                let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
                let f1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                let f2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)

                // Coarsest first, so the explicit finer values are the ones
                // that survive any recomputation.
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -d1)
                event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -d2)
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -p1)
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -p2)
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -f1)
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -f2)

                if ScrollController.verbose {
                    print(String(
                        format: "  delta %d->%d   point %d->%d   fixed %.3f->%.3f",
                        d1, event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                        p1, event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                        f1, event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)))
                }
                _ = proxy
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else { return false }

        activeTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        activeSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Follow the preference for as long as the tap lives.
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            refreshInversion(desired)
        }
        RunLoop.current.add(timer, forMode: .common)
        activeTimer = timer
        return true
    }

    /// Zero every wheel delta, so the wheel should stop scrolling entirely.
    ///
    /// The one unambiguous test of whether a modification made in this tap
    /// reaches the application at all. Negation is a poor probe for that: if it
    /// silently fails, the result is indistinguishable from doing nothing.
    /// Blocking is not — either the page stops moving or it does not.
    static func block() {
        guard ensureAccessibility(prompt: true) else {
            print("Accessibility permission is needed. Grant it, then retry.")
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
                if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
                    return Unmanaged.passUnretained(event)
                }
                for field in [
                    CGEventField.scrollWheelEventDeltaAxis1,
                    .scrollWheelEventDeltaAxis2,
                    .scrollWheelEventPointDeltaAxis1,
                    .scrollWheelEventPointDeltaAxis2,
                    .scrollWheelEventFixedPtDeltaAxis1,
                    .scrollWheelEventFixedPtDeltaAxis2,
                ] {
                    event.setIntegerValueField(field, value: 0)
                }
                print("  blocked a wheel event")
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("could not create the tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("""
            Wheel events are being zeroed. Scroll the WHEEL in any window.

              nothing moves      -> modifications from this tap do reach apps
              it scrolls anyway  -> they do not, and inverting never could work

            The trackpad is untouched either way. Ctrl-C to stop.

            """)
        CFRunLoopRun()
    }

    /// Print every scroll event as it arrives, changing nothing.
    ///
    /// Written because the tap armed successfully and the wheel still did not
    /// invert. That leaves several possibilities — the events are marked
    /// continuous and being skipped, the fields being negated are not the ones
    /// the apps read, or the flip is applied downstream of this tap and undoes
    /// the change — and none of them can be told apart without seeing the
    /// actual event.
    static func debug() {
        guard ensureAccessibility(prompt: true) else {
            print("Accessibility permission is needed. Grant it, then retry.")
            return
        }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
                let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
                let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                let f1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                print(String(
                    format: "continuous=%d  delta=%4d  pointDelta=%5d  fixed=%8.3f  "
                        + "phase=%d momentum=%d   [macOS natural=%@]",
                    continuous, d1, p1, f1, phase, momentum,
                    ScrollController.macOSNaturalScrolling ? "on" : "off"))
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("could not create the tap even with permission held")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("Scroll the WHEEL a few notches, then the TRACKPAD a little.")
        print("A wheel that reports continuous=1 is why inversion does nothing.\n")
        CFRunLoopRun()
    }

    static func stop() {
        if let tap = activeTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = activeSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        activeTimer?.invalidate()
        activeTap = nil
        activeSource = nil
        activeTimer = nil
    }

    fileprivate static var activeTap: CFMachPort?
    private static var activeSource: CFRunLoopSource?
    private static var activeTimer: Timer?

    /// Run the event tap until interrupted. Never returns under normal use.
    static func run(_ desired: ScrollDirection, verbose: Bool = false) {
        ScrollController.verbose = verbose
        guard desired != .follow else {
            print("`follow` means no interception — nothing to run.")
            print("The mouse already follows the macOS preference.")
            return
        }

        if !ensureAccessibility(prompt: false) {
            print("""
                Accessibility permission is needed to read scroll events.

                Asking for it now — a system dialog should appear. If it does
                not, add this to System Settings ▸ Privacy & Security ▸
                Accessibility by hand:

                    \(requestingProcessPath)

                Note that the entry is for the program that *asks*, which is the
                terminal you are running this from — not asctl itself, unless
                you launched the app bundle.

                """)
            ensureAccessibility(prompt: true)
            print("Grant it, then run this command again.")
            print("An already-listed entry may need to be toggled off and on "
                + "after the binary is rebuilt.")
            return
        }

        guard start(desired) else {
            FileHandle.standardError.write(Data("""
                error: the event tap could not be created even though
                Accessibility permission is held.

                Try toggling this entry off and on in System Settings:
                    \(requestingProcessPath)

                """.utf8))
            return
        }

        print("macOS natural scrolling: \(macOSNaturalScrolling ? "on" : "off")")
        print("mouse wheel: \(desired.label)")
        print(shouldInvert(desired)
            ? "inverting discrete scroll events; trackpad untouched."
            : "not inverting right now — the macOS setting already matches.")
        print("\nThis keeps watching the macOS preference, so toggling it while")
        print("this runs is handled without a restart.")
        print("\nrunning — press Ctrl-C to stop.")
        CFRunLoopRun()
    }

    // MARK: - Launching the app itself at login

    /// A login agent for the GUI, distinct from the scroll-only one.
    enum AppLogin {
        static let label = "io.github.yourchocomate.asctl.app"

        static var url: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        }

        static var installed: Bool {
            FileManager.default.fileExists(atPath: url.path)
        }

        /// The bundle's own executable, so the login item starts the app rather
        /// than a bare binary — a bundle keeps its Accessibility and Bluetooth
        /// grants across rebuilds, and a loose executable does not.
        ///
        /// Ask Bundle for the path rather than assembling one. This used to
        /// hard-code `Contents/MacOS/launch`, a wrapper script that was removed
        /// when the bundle was given its own identity — CFBundleExecutable has
        /// to match the running process name or macOS never reads Info.plist.
        /// Nothing noticed, because writing the plist succeeds whether or not
        /// the program it names exists: launchd only discovers the path is dead
        /// at login, and then fails silently. Which is exactly the report —
        /// logged out, logged back in, no asctl.
        static var launcher: String? {
            guard Bundle.main.bundleURL.pathExtension == "app",
                  let executable = Bundle.main.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path)
            else { return nil }
            return executable.path
        }

        static func install() throws {
            guard let program = launcher else {
                throw NSError(domain: "asctl", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Only the app bundle can be launched at login. "
                        + "Build it with Scripts/make-app.sh and run that.",
                ])
            }
            let lines = [
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                    + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
                "<plist version=\"1.0\">",
                "<dict>",
                "    <key>Label</key><string>\(label)</string>",
                "    <key>ProgramArguments</key>",
                "    <array><string>\(program)</string></array>",
                "    <key>RunAtLoad</key><true/>",
                "    <key>KeepAlive</key><false/>",
                "</dict>",
                "</plist>",
            ]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(
                to: url, atomically: true, encoding: .utf8)

            // Register it now rather than trusting the next login.
            //
            // launchd does read this directory at login, so the plist alone
            // would eventually work — but only eventually, which means a broken
            // entry stays invisible until the user logs out and finds the app
            // missing. Bootstrapping makes launchd parse it immediately, so a
            // bad path or a malformed plist is a failure we can report.
            bootout()
            _ = launchctl(["bootstrap", "gui/\(getuid())", url.path])
        }

        static func uninstall() throws {
            bootout()
            if installed { try FileManager.default.removeItem(at: url) }
        }

        /// Whether launchd has actually accepted the job, as opposed to a plist
        /// merely existing on disk. These are different things, and only this
        /// one predicts what happens at the next login.
        ///
        /// **Never call this on the main thread.** It runs a subprocess, and
        /// `waitUntilExit` pumps the calling run loop while it waits. On the
        /// main thread that lets AppKit re-enter layout, which re-evaluates
        /// SwiftUI bodies, which called this again — a nested wait that
        /// segfaulted the moment the login switch was touched.
        static var registered: Bool {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
        }

        private static func bootout() {
            _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        }

        /// Run launchctl and wait. Callers must be off the main thread — see
        /// `registered` for what happens otherwise.
        @discardableResult
        private static func launchctl(_ arguments: [String]) -> Int32 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return -1 }
            task.waitUntilExit()
            return task.terminationStatus
        }
    }

    // MARK: - Running in the background

    static let agentLabel = "io.github.yourchocomate.asctl.scroll"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// Install a LaunchAgent so the tap runs at login.
    ///
    /// The tap must be running whenever the mouse is in use, so a foreground
    /// process is not much good. `KeepAlive` restarts it if it is ever killed —
    /// including when macOS disables a tap that stopped responding.
    static func install(_ mode: ScrollDirection) throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        let lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\">",
            "<dict>",
            "    <key>Label</key><string>\(agentLabel)</string>",
            "    <key>ProgramArguments</key>",
            "    <array>",
            "        <string>\(binary)</string>",
            "        <string>scroll</string>",
            "        <string>\(mode.rawValue)</string>",
            "    </array>",
            "    <key>RunAtLoad</key><true/>",
            "    <key>KeepAlive</key><true/>",
            "</dict>",
            "</plist>",
        ]
        try FileManager.default.createDirectory(
            at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(
            to: agentURL, atomically: true, encoding: .utf8)
    }

    /// Whether the login agent is currently installed.
    static var agentInstalled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}

