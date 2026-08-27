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
enum ScrollDirection: String {
    /// Do nothing — the mouse follows the macOS preference. Default.
    case follow
    /// Traditional direction, whatever macOS is set to.
    case standard
    /// Natural direction, whatever macOS is set to.
    case natural

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
        if let value = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") {
            return (value as? NSNumber)?.boolValue ?? true
        }
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

    /// Run the event tap until interrupted. Never returns under normal use.
    static func run(_ desired: ScrollDirection) {
        let invert = shouldInvert(desired)
        guard invert else {
            print("Nothing to do: macOS is already producing "
                + "\(desired == .natural ? "natural" : "traditional") scrolling for the mouse.")
            print("This command would only intercept events if the two disagreed.")
            return
        }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // The tap is disabled if it ever times out; re-arm rather than
                // silently dying.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                // Continuous means trackpad / Magic Mouse -- leave those alone,
                // otherwise this would undo natural scrolling everywhere.
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
                    let value = event.getIntegerValueField(field)
                    if value != 0 { event.setIntegerValueField(field, value: -value) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            FileHandle.standardError.write(Data("""
                error: could not create the event tap.

                This needs Accessibility permission. Grant it to your terminal in
                System Settings ▸ Privacy & Security ▸ Accessibility, then retry.

                """.utf8))
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("macOS natural scrolling: \(macOSNaturalScrolling ? "on" : "off")")
        print("mouse wheel: \(desired.label)")
        print("inverting discrete scroll events; trackpad untouched.")
        print("\nrunning — press Ctrl-C to stop.")
        CFRunLoopRun()
    }

    // MARK: - Running in the background

    static let agentLabel = "org.opensource.asctl.scroll"

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

    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}

