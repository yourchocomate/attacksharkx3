import Combine
import Foundation
import SwiftUI

/// The whole editable device configuration, plus connection and log state.
///
/// One object rather than several because the protocol forces it: reports 0x04
/// and 0x08 are atomic and unreadable, so "apply DPI" necessarily transmits the
/// sensor toggles and every stage colour too. Splitting the model would invite
/// a view to apply a partial picture and silently reset the rest.
@available(macOS 12.0, *)
final class AppState: ObservableObject {

    // MARK: Connection

    @Published var link: GUITransport.Link = .receiver
    @Published var devices: [HIDDeviceRef] = []
    @Published var dryRun = false
    @Published var battery: Int?

    var configurableDevice: HIDDeviceRef? { devices.first { $0.canConfigure } }

    var connectionSummary: String {
        switch link {
        case .bluetooth:
            return "Bluetooth (GATT) — writes go to FEE3"
        case .receiver:
            guard let device = configurableDevice else {
                return "no configurable interface — plug in the receiver or the USB cable"
            }
            return device.descriptorText
        }
    }

    var isReady: Bool { link == .bluetooth || configurableDevice != nil }

    // MARK: DPI and sensor — report 0x04

    struct Stage: Identifiable {
        let id = UUID()
        var dpi: Int
        var enabled: Bool
        var colour: Color
    }

    @Published var stages: [Stage] = [
        Stage(dpi: 800, enabled: true, colour: .red),
        Stage(dpi: 1600, enabled: true, colour: .green),
        Stage(dpi: 3200, enabled: true, colour: .blue),
        Stage(dpi: 6400, enabled: true, colour: .yellow),
        Stage(dpi: 12800, enabled: false, colour: .purple),
        Stage(dpi: 16000, enabled: false, colour: .cyan),
        Stage(dpi: 20000, enabled: false, colour: .orange),
        Stage(dpi: 26000, enabled: false, colour: .white),
    ]
    @Published var activeStage = 0

    @Published var liftOff2mm = false
    @Published var rippleControl = false
    @Published var angleSnap = false
    @Published var motionSync = false

    // MARK: Polling rate — report 0x06

    @Published var pollingRate = 1000

    // MARK: Power and debounce — report 0x05

    @Published var sleepMinutes = 10
    @Published var deepSleepMinutes = 10
    @Published var debounceMs = 10

    // MARK: Buttons — report 0x08

    /// Physical positions, in the order the report expects them. Entry 5 is the
    /// mode-switch button; remapping it costs Bluetooth channel switching until
    /// the factory table is restored, so the UI marks it.
    static let buttonNames = [
        "Left click", "Right click", "Wheel click", "DPI button", "Mode switch",
        "DPI down", "Forward", "Backward", "Mode switch (2)",
        "Button 10", "Button 11", "Button 12", "Button 13", "Button 14",
        "Button 15", "Button 16", "Wheel down", "Wheel up",
    ]

    @Published var buttonActions: [String] = AppState.factoryActionNames

    static let factoryActionNames = [
        "left", "right", "middle", "dpi_cycle", "mode_switch",
        "dpi_down", "forward", "backward", "mode_switch",
        "button_off", "button_off", "button_off", "button_off",
        "button_off", "button_off", "button_off",
        "scroll_down", "scroll_up",
    ]

    /// Curated picker list. `actionTable` holds aliases as well as canonical
    /// names; showing all of them would be noise.
    static let actionGroups: [(String, [(key: String, label: String)])] = [
        ("Mouse", [
            ("left", "Left click"), ("right", "Right click"), ("middle", "Wheel click"),
            ("backward", "Back"), ("forward", "Forward"),
            ("double_click", "Double click"), ("fire_button", "Fire button"),
            ("scroll_up", "Scroll up"), ("scroll_down", "Scroll down"),
            ("tilt_left", "Tilt left"), ("tilt_right", "Tilt right"),
        ]),
        ("Device", [
            ("dpi_cycle", "DPI cycle"), ("dpi_up", "DPI up"), ("dpi_down", "DPI down"),
            ("profile_cycle", "Profile cycle"), ("profile_up", "Profile up"),
            ("profile_down", "Profile down"), ("mode_switch", "Mode switch"),
            ("easy_aim", "Easy aim"), ("led_loop", "LED loop"),
        ]),
        ("Media", [
            ("play_pause", "Play / pause"), ("media_stop", "Stop"),
            ("previous_track", "Previous track"), ("next_track", "Next track"),
            ("mute", "Mute"), ("volume_up", "Volume up"), ("volume_down", "Volume down"),
            ("media_player", "Media player"),
        ]),
        ("System", [
            ("browser_home", "Browser home"), ("browser_search", "Browser search"),
            ("browser_refresh", "Browser refresh"), ("browser_favorites", "Favourites"),
            ("my_computer", "My computer"), ("calculator", "Calculator"),
            ("email", "Email"), ("copy", "Copy"), ("paste", "Paste"),
            ("undo", "Undo"), ("select_all", "Select all"),
            ("screen_capture", "Screen capture"), ("lock_pc", "Lock"),
        ]),
        ("Off", [("button_off", "Disabled"), ("none", "Unassigned")]),
    ]

    static let actionChoices: [(key: String, label: String)] =
        actionGroups.flatMap { $0.1 }

    static func label(forAction key: String) -> String {
        if key.hasPrefix("key:") { return "Shortcut \(key.dropFirst(4))" }
        if key.hasPrefix("macro:") { return "Macro \(key.dropFirst(6))" }
        if key.hasPrefix("raw:") { return "Raw \(key.dropFirst(4))" }
        return actionChoices.first { $0.key == key }?.label ?? key
    }

    // MARK: Log

    @Published var log: [String] = ["asctl ready."]
    @Published var busy = false

    func note(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: Refresh

    func refreshDevices() {
        devices = HID.attackSharkDevices()
        if devices.isEmpty {
            note("no Attack Shark interface found")
        } else {
            note("found \(devices.count) interface(s)")
        }
    }

    func refreshBattery() {
        busy = true
        note("reading battery over Bluetooth…")
        DispatchQueue.global().async {
            let (level, message) = GUITransport.readBattery()
            DispatchQueue.main.async {
                self.battery = level
                self.note(message)
                self.busy = false
            }
        }
    }

    // MARK: Report building

    private func rgb(_ colour: Color) -> (r: UInt8, g: UInt8, b: UInt8) {
        let native = NSColor(colour).usingColorSpace(.sRGB) ?? .red
        return (
            UInt8(max(0, min(255, native.redComponent * 255))),
            UInt8(max(0, min(255, native.greenComponent * 255))),
            UInt8(max(0, min(255, native.blueComponent * 255)))
        )
    }

    func dpiReport() -> [UInt8] {
        let enabled = stages.filter { $0.enabled }
        let list = enabled.isEmpty ? [stages[0]] : enabled
        return DpiReport.build(
            stages: list.map { $0.dpi },
            activeStage: min(activeStage, list.count - 1),
            colours: list.map { rgb($0.colour) },
            toggles: DpiReport.Toggles(
                liftOffDistance2mm: liftOff2mm,
                rippleControl: rippleControl,
                angleSnap: angleSnap,
                motionSync: motionSync
            ).bytes)
    }

    func pollingReport() -> [UInt8]? { PollingRate.report(hz: pollingRate) }

    func powerReport() -> [UInt8] {
        LightReport.build(
            mode: .off,
            sleepMinutes: UInt8(clamping: sleepMinutes),
            deepSleepMinutes: UInt8(clamping: deepSleepMinutes),
            keyDebounceMs: UInt8(clamping: debounceMs))
    }

    func buttonReport() -> [UInt8] {
        ButtonReport.build(buttonActions.map { ButtonReport.parseAction($0) })
    }

    var buttonsHaveLeftClick: Bool {
        buttonActions.contains { ButtonReport.parseAction($0)?.code == ButtonReport.leftClickCode }
    }

    // MARK: Applying

    func apply(_ what: String, _ reports: [[UInt8]]) {
        guard !busy else { return }
        busy = true
        note("── \(what)")
        let link = self.link
        let dryRun = self.dryRun
        DispatchQueue.global().async {
            let result = GUITransport.send(reports, over: link, dryRun: dryRun)
            DispatchQueue.main.async {
                for line in result.lines { self.note(line) }
                self.busy = false
            }
        }
    }

    func applyDPI() { apply("DPI and sensor (report 0x04)", [dpiReport()]) }

    func applyPolling() {
        guard let report = pollingReport() else {
            note("unsupported polling rate \(pollingRate)")
            return
        }
        apply("polling rate (report 0x06)", [report])
    }

    func applyPower() { apply("power and debounce (report 0x05)", [powerReport()]) }

    func applyButtons() {
        guard buttonsHaveLeftClick else {
            note("refused: at least one button must remain a left click, or you "
                + "cannot click to undo the change")
            return
        }
        apply("button mapping (report 0x08)", [buttonReport()])
    }

    func restoreFactoryButtons() {
        buttonActions = AppState.factoryActionNames
        apply("factory button mapping", [ButtonReport.build(
            ButtonReport.factoryDefault.map {
                ButtonReport.Action(code: $0, describe: "factory")
            })])
    }

    func applyEverything() {
        var reports: [[UInt8]] = [dpiReport()]
        if let polling = pollingReport() { reports.append(polling) }
        reports.append(powerReport())
        if buttonsHaveLeftClick { reports.append(buttonReport()) }
        apply("everything", reports)
    }
}
