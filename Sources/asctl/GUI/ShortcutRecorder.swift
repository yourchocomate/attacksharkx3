import AppKit
import SwiftUI

/// Record an arbitrary key combination and turn it into a button action.
///
/// The fixed list in the picker was never the limit of what the hardware can
/// do. Action `0x11` carries a standard HID modifier bitmask and a standard HID
/// usage, so any combination the keyboard can express is one the mouse can
/// send — the named entries are just the ones the vendor's own UI happened to
/// offer. The CLI has always accepted `key:cmd+c`; this exposes the same thing.
///
/// Recorded rather than typed, because a user knows the chord they want by
/// pressing it and generally does not know its HID usage number.
@available(macOS 12.0, *)
enum ShortcutRecorder {

    /// Convert a key event into a spec `Protocol.parseAction` understands.
    ///
    /// Returns nil for a press that carries no usable key, such as a modifier
    /// on its own: holding Command is not a shortcut, and recording it would
    /// store a combination the mouse could never usefully send.
    static func spec(from event: NSEvent) -> String? {
        guard let key = keyName(for: event) else { return nil }

        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Order fixed rather than in the order they were pressed, so the same
        // chord always produces the same string and comparisons stay simple.
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return "key:" + parts.joined(separator: "+")
    }

    /// The base key, ignoring modifiers.
    ///
    /// `charactersIgnoringModifiers` gives the unshifted character, so Shift+2
    /// records as shift+2 rather than as "@" — which matters because the wire
    /// carries a usage and a modifier separately, not a resulting character.
    private static func keyName(for event: NSEvent) -> String? {
        if let named = specialKeys[event.keyCode] { return named }
        guard let raw = event.charactersIgnoringModifiers?.lowercased(),
              let first = raw.first
        else { return nil }
        let name = String(first)
        return HIDUsage.names[name] != nil ? name : nil
    }

    /// Keys whose character form is a control code or absent, so the keyCode is
    /// the only reliable source.
    private static let specialKeys: [UInt16: String] = [
        0x24: "enter", 0x30: "tab", 0x31: "space", 0x33: "backspace",
        0x35: "esc", 0x75: "delete", 0x73: "home", 0x77: "end",
        0x74: "pageup", 0x79: "pagedown",
        0x7B: "left", 0x7C: "right", 0x7D: "down", 0x7E: "up",
        0x7A: "f1", 0x78: "f2", 0x63: "f3", 0x76: "f4", 0x60: "f5",
        0x61: "f6", 0x62: "f7", 0x64: "f8", 0x65: "f9", 0x6D: "f10",
        0x67: "f11", 0x6F: "f12",
    ]

    /// Render a spec the way a Mac user reads shortcuts.
    static func describe(_ spec: String) -> String {
        guard spec.hasPrefix("key:") else { return spec }
        var symbols = ""
        var key = ""
        for token in spec.dropFirst(4).split(separator: "+") {
            switch token {
            case "ctrl": symbols += "⌃"
            case "alt", "opt", "option": symbols += "⌥"
            case "shift": symbols += "⇧"
            case "cmd", "command", "win", "gui": symbols += "⌘"
            default: key = String(token)
            }
        }
        return symbols + display(key)
    }

    private static func display(_ key: String) -> String {
        switch key {
        case "enter": return "↩"
        case "tab": return "⇥"
        case "space": return "space"
        case "backspace": return "⌫"
        case "delete": return "⌦"
        case "esc": return "⎋"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }

    static func isCustom(_ spec: String) -> Bool {
        spec.hasPrefix("key:") || spec.hasPrefix("macro:") || spec.hasPrefix("raw:")
    }
}

/// A button that captures the next key combination pressed.
///
/// Uses a local event monitor rather than a focusable NSView: the monitor sees
/// the event before the window's normal key handling, so Command combinations
/// that would otherwise fire a menu item get recorded instead of performing the
/// menu action. It returns nil from the handler to swallow the event, so
/// recording Command-Q does not also quit the app.
@available(macOS 12.0, *)
struct ShortcutCaptureButton: View {
    @Binding var action: String
    @State private var armed = false
    @State private var monitor: Any?

    var body: some View {
        Button(armed ? "Press keys…" : "⌘…") {
            armed ? disarm() : arm()
        }
        .font(.system(size: 10))
        .controlSize(.small)
        .help(armed
            ? "Press the combination you want, or Escape to cancel"
            : "Record any key combination for this button")
        .onDisappear { disarm() }
    }

    private func arm() {
        armed = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels rather than recording, since a button mapped to
            // Escape is far less likely to be wanted than a way out of here.
            if event.keyCode == 0x35
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                disarm()
                return nil
            }
            if let spec = ShortcutRecorder.spec(from: event) {
                action = spec
                disarm()
            }
            return nil
        }
    }

    private func disarm() {
        armed = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
