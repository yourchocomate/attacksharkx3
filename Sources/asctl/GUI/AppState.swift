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

    var isReady: Bool { link == .bluetooth ? bluetoothPresent : configurableDevice != nil }

    /// Whether the mouse is currently visible on each transport.
    ///
    /// The X3 is on one link at a time — the 2.4G/OFF/BT slider underneath
    /// decides which — so exactly one of these is normally true, and that is
    /// what makes auto-selection safe rather than a guess.
    var receiverPresent: Bool {
        devices.contains { $0.canConfigure && $0.vendorID == 0x1D57 }
    }

    var bluetoothPresent: Bool {
        devices.contains {
            $0.vendorID == 0x045E && $0.transport.lowercased().contains("bluetooth")
        }
    }

    /// Pick the transport the mouse is actually on.
    ///
    /// Preference goes to the receiver when both are somehow visible: it is the
    /// full-feature path, and it does not suffer the dead-cursor firmware fault.
    /// Battery is the opposite — only Bluetooth can report it.
    func detectLink() {
        if receiverPresent {
            if link != .receiver { note("detected the 2.4 GHz receiver / USB cable") }
            link = .receiver
        } else if bluetoothPresent {
            if link != .bluetooth { note("detected Bluetooth") }
            link = .bluetooth
        } else {
            note("no mouse found — check the 2.4G / OFF / BT slider underneath")
        }
    }

    /// Battery lives on GATT characteristic 2A19, so it is readable over
    /// Bluetooth and nowhere else. The 2.4 GHz status event that would carry it
    /// is decoded but has never once been observed firing.
    var batteryAvailable: Bool { bluetoothPresent }

    // MARK: DPI and sensor — report 0x04

    /// One of the report's **eight fixed slots**. The wire addresses slots by
    /// index and carries enablement only as a bitmask, so a slot keeps its
    /// index whether or not it is switched on.
    struct Stage: Identifiable {
        let id = UUID()
        var dpi: Int
        var enabled: Bool
        var colour: Color
    }

    /// The stock configuration of this unit, as observed on the hardware:
    /// five stages, 800 through 26000.
    ///
    /// Note this is **not** the vendor's reset table, which has six stages
    /// (800/1600/2400/3200/5000/26000) and a different palette. The device
    /// ships with its own defaults; `DpiReport.factorySlots` holds the
    /// vendor's, available from the presets menu.
    static let stockStages: [Stage] = [
        Stage(dpi: 800, enabled: true, colour: .blue),
        Stage(dpi: 1600, enabled: true, colour: .cyan),
        Stage(dpi: 3200, enabled: true, colour: .green),
        Stage(dpi: 5000, enabled: true, colour: .yellow),
        Stage(dpi: 26000, enabled: true, colour: .red),
        Stage(dpi: 0, enabled: false, colour: .purple),
        Stage(dpi: 0, enabled: false, colour: .orange),
        Stage(dpi: 0, enabled: false, colour: .white),
    ]

    static var vendorFactoryStages: [Stage] {
        DpiReport.factorySlots.map {
            Stage(dpi: $0.dpi, enabled: $0.enabled,
                  colour: Color(.sRGB,
                                red: Double($0.colour.r) / 255,
                                green: Double($0.colour.g) / 255,
                                blue: Double($0.colour.b) / 255))
        }
    }

    @Published var stages: [Stage] = AppState.vendorFactoryStages
    @Published var activeStage = DpiReport.factoryActiveSlot
    @Published var showAdvancedDPI = false

    func loadVendorFactoryStages() {
        stages = AppState.vendorFactoryStages
        activeStage = DpiReport.factoryActiveSlot
        note("loaded the vendor factory DPI table — 6 stages")
    }

    func loadStockStages() {
        stages = AppState.stockStages
        activeStage = 0
        note("loaded this unit's stock DPI table (5 stages)")
    }

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

    /// Report entries, named by the physical button each one drives.
    ///
    /// Established by experiment, not by reading the factory table: a distinct
    /// letter was written onto each entry and the mouse was watched. Entries 6
    /// and 9-18 produced **no observable button on this unit** — the factory
    /// table assigns them, but nothing on this shell triggers them.
    /// Names follow the vendor's own product diagram.
    static let buttonNames = [
        "Left Button", "Right Button", "Middle Button",
        "DPI Switch", "Mode Key",
        "(no button)", "Forward", "Backward",
        "(no button)", "(no button)", "(no button)", "(no button)",
        "(no button)", "(no button)", "(no button)", "(no button)",
        "(no button)", "(no button)",
    ]

    /// The seven entries that drive something you can press.
    static let physicalButtons = [0, 1, 2, 3, 4, 6, 7]

    /// Entry 5 cycles the Bluetooth identity. Remapping it costs channel
    /// switching until the factory table is restored.
    static let modeButtonEntry = 4

    @Published var buttonActions: [String] = AppState.factoryActionNames

    /// The vendor's own reset table, decoded from its defaults routine.
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

    // MARK: What the editor is showing

    /// Where the values on screen came from.
    ///
    /// This has to be stated, because **the protocol is write-only**: there is
    /// no report that asks the mouse what it is set to, so the editor can never
    /// simply mirror the device. It shows one of three things, and says which.
    enum Provenance {
        case defaults        // the vendor factory table
        case lastApplied     // what asctl last wrote, restored from disk
        case edited          // changed since it was loaded or applied

        var caption: String {
            switch self {
            case .defaults:
                return "Showing the vendor factory table. The mouse cannot be read, "
                    + "so this is a starting point, not its current state."
            case .lastApplied:
                return "Showing the last configuration asctl wrote to this mouse."
            case .edited:
                return "Edited — not yet written to the mouse."
            }
        }
    }

    @Published var provenance: Provenance = .defaults

    private static var lastAppliedURL: URL {
        Profile.directory.deletingLastPathComponent()
            .appendingPathComponent("last-applied.json")
    }

    /// Remember every successful write, so the next launch shows what the mouse
    /// was actually left set to rather than a generic default.
    func recordApplied() {
        guard let data = try? JSONEncoder().encode(currentProfile()) else { return }
        try? data.write(to: AppState.lastAppliedURL)
        provenance = .lastApplied
    }

    func restoreLastApplied() {
        guard let data = try? Data(contentsOf: AppState.lastAppliedURL),
              let profile = try? JSONDecoder().decode(Profile.self, from: data)
        else { return }
        apply(profile: profile)
        provenance = .lastApplied
        captureBaseline()
        note("restored the last configuration asctl wrote")
    }

    // MARK: Log

    @Published var log: [String] = ["asctl ready."]
    @Published var busy = false

    func markEdited() {
        if provenance != .edited { provenance = .edited }
    }

    func note(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: Refresh

    func refreshDevices(autoSelect: Bool = true) {
        devices = HID.attackSharkDevices()
        if autoSelect { detectLink() }
    }

    @Published var batteryReading = false
    /// The last few readings, kept visible. A level that behaves oddly is far
    /// easier to diagnose from a short history than from one number.
    @Published var batteryHistory: [(level: Int, raw: String, at: Date)] = []

    func refreshBattery() {
        guard batteryAvailable else {
            note("battery is only readable over Bluetooth")
            return
        }
        guard !batteryReading else { return }
        batteryReading = true
        // A refresh has to be a *new link*, not another read on the current
        // one. Reading 2A19 twice on one connection returns a value one higher
        // each time (measured: 4B 4C 4D 4E 4F), so re-reading in place produces
        // a number that climbs with clicks and tracks nothing.
        if monitorConnected {
            note("reconnecting for a fresh battery reading…")
            restartMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.batteryReading = false
            }
            return
        }
        oneShotBattery()
    }

    /// Read on a connection of our own. Used when no listener holds the link.
    private func oneShotBattery() {
        batteryReading = true
        DispatchQueue.global().async {
            let (level, message) = GUITransport.readBattery()
            DispatchQueue.main.async {
                if let level {
                    self.recordBattery(level, raw: message, name: "")
                } else {
                    self.note("battery: \(message)")
                }
                self.batteryReading = false
            }
        }
    }

    func recordBattery(_ level: Int, raw: String, name: String) {
        battery = level
        batteryHistory.insert((level, raw, Date()), at: 0)
        if batteryHistory.count > 4 { batteryHistory.removeLast() }
        batteryReading = false
    }

    // MARK: Live device state

    let monitor = StatusMonitor()
    @Published var monitorRunning = false
    @Published var monitorConnected = false
    /// The active DPI stage the *device* last reported, which is the only piece
    /// of its configuration it ever volunteers.
    @Published var deviceActiveStage: Int?

    /// Poll the HID registry so a mouse that is unplugged, switched off, or
    /// moved to another transport is noticed without the user pressing Rescan.
    ///
    /// The X3 has a physical 2.4G/OFF/BT slider, so the transport can change
    /// under the app at any moment. Detecting the link once at launch left the
    /// window claiming a connection that no longer existed and a listener bound
    /// to a device that had gone.
    private var deviceWatch: Timer?
    private var lastDeviceSignature = ""

    func startDeviceWatch() {
        deviceWatch?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollDevices()
        }
        RunLoop.main.add(timer, forMode: .common)
        deviceWatch = timer
        pollDevices()
    }

    private func pollDevices() {
        let found = HID.attackSharkDevices()
        let signature = found
            .map { "\($0.vendorID):\($0.productID):\($0.transport):\($0.usage)" }
            .sorted().joined(separator: "|")
        guard signature != lastDeviceSignature else { return }

        let wasConnected = !lastDeviceSignature.isEmpty
        lastDeviceSignature = signature
        devices = found

        if found.isEmpty {
            note("mouse disconnected — check the 2.4G / OFF / BT slider underneath")
            battery = nil
            deviceActiveStage = nil
            stopMonitor()
            return
        }

        let previous = link
        detectLink()
        if !wasConnected || link != previous {
            note("connection changed — restarting the listener on \(link.rawValue)")
            deviceActiveStage = nil
            battery = nil
            restartMonitor()
        }
    }

    func startMonitor() {
        guard !monitorRunning else { return }
        monitor.onEvent = { [weak self] event, raw in
            guard let self else { return }
            switch event.code {
            case StatusEvent.Code.dpiStage.rawValue:
                // The device numbers stages from 1; the editor indexes from 0.
                let reported = Int(event.value)
                guard reported >= 1 else { break }
                self.deviceActiveStage = reported - 1
                if self.activeStage != reported - 1 {
                    self.activeStage = reported - 1
                    // Move the baseline with it. The device pressing its own
                    // DPI button is the mouse *reporting* its state, not the
                    // user editing anything — treating it as an unapplied edit
                    // marked the panel dirty for a change that had already
                    // happened on the hardware.
                    self.baseline.activeStage = reported - 1
                    self.note("device switched to DPI stage \(reported)")
                }
            case StatusEvent.Code.writeAck.rawValue:
                break  // already logged by the send path
            default:
                self.note("event \(Hex.encode(raw)) — \(event.description)")
            }
        }
        monitor.onBattery = { [weak self] level, raw, name in
            self?.recordBattery(level, raw: "\(name) 2A19=\(Hex.encode(raw))", name: name)
        }
        monitor.onRetry = { [weak self] attempt, delay in
            guard let self else { return }
            // Only mention the first couple, or a mouse that is simply switched
            // off fills the log with retries.
            if attempt <= 2 {
                self.note(String(
                    format: "listener could not reach the mouse — retrying in %.0fs",
                    delay))
            }
        }
        monitor.onConnectionChange = { [weak self] up in
            guard let self else { return }
            self.monitorConnected = up
            self.note(up ? "listener connected" : "listener disconnected")
            // If the listener could not take the link, fall back to a one-shot
            // read so the gauge still gets a value.
            if !up && self.batteryAvailable && self.battery == nil {
                self.oneShotBattery()
            }
        }
        monitor.start(link: link)
        monitorRunning = true
    }

    func stopMonitor() {
        monitor.stop()
        monitorRunning = false
        monitorConnected = false
    }

    func restartMonitor() {
        stopMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.startMonitor() }
    }

    // MARK: Scroll direction

    /// The one feature here that writes nothing to the mouse.
    ///
    /// macOS applies a single "Natural scrolling" preference to the trackpad
    /// *and* every mouse, with no way to separate them, and the X3 has no
    /// device-side scroll setting — nothing in the vendor UI or any config
    /// report touches it. So the wheel is corrected on the host by intercepting
    /// discrete scroll events, leaving the trackpad's continuous ones alone.
    @Published var scrollMode: ScrollDirection = .follow
    @Published var scrollRunning = false
    @Published var scrollAgentInstalled = ScrollController.agentInstalled

    var macOSNaturalScrolling: Bool { ScrollController.macOSNaturalScrolling }

    var scrollAccessibilityGranted: Bool {
        ScrollController.ensureAccessibility(prompt: false)
    }

    func applyScrollMode() {
        ScrollController.stop()
        scrollRunning = false

        guard scrollMode != .follow else {
            note("scroll: following the macOS setting — nothing intercepted")
            return
        }
        guard ScrollController.ensureAccessibility(prompt: true) else {
            note("scroll: Accessibility permission needed — a system dialog "
                + "should have appeared. Grant it to asctl, then try again.")
            return
        }
        guard ScrollController.start(scrollMode) else {
            note("scroll: the event tap could not be created even with "
                + "permission held. Toggle asctl off and on in Accessibility.")
            return
        }
        scrollRunning = true
        note("scroll: \(scrollMode.short) — "
            + (ScrollController.shouldInvert(scrollMode)
               ? "inverting the wheel, trackpad untouched"
               : "no inversion needed while macOS already matches"))
    }

    func stopScroll() {
        ScrollController.stop()
        scrollRunning = false
        note("scroll: stopped intercepting")
    }

    /// Superseded by the app's own login item, which keeps everything running.
    /// Kept for the CLI, where there is no app to stay resident.
    func installScrollAgent() {
        guard scrollMode != .follow else {
            note("scroll: nothing to install for `follow`")
            return
        }
        do {
            try ScrollController.install(scrollMode)
            scrollAgentInstalled = true
            note("scroll: login agent installed — load it now with")
            note("        launchctl load \(ScrollController.agentURL.path)")
        } catch {
            note("scroll: could not install — \(error.localizedDescription)")
        }
    }

    func uninstallScrollAgent() {
        do {
            try ScrollController.uninstall()
            scrollAgentInstalled = false
            note("scroll: login agent removed")
        } catch {
            note("scroll: could not remove — \(error.localizedDescription)")
        }
    }

    // MARK: Uncommitted changes

    /// The configuration as last written to the mouse — or, before anything has
    /// been written, the defaults the editor started from.
    ///
    /// Needed because the protocol is write-only: nothing can be read back, so
    /// "has this changed?" can only be answered against a record we keep
    /// ourselves. Without it every panel looks identical whether or not its
    /// values have reached the device.
    @Published var baseline: Profile = Profile()

    func captureBaseline() { baseline = currentProfile() }

    var dpiDirty: Bool {
        let now = currentProfile()
        return now.dpiStages != baseline.dpiStages
            || now.stageEnabled != baseline.stageEnabled
            || now.activeStage != baseline.activeStage
            || now.colours != baseline.colours
    }

    var sensorDirty: Bool {
        let now = currentProfile()
        return now.liftOff2mm != baseline.liftOff2mm
            || now.rippleControl != baseline.rippleControl
            || now.angleSnap != baseline.angleSnap
            || now.motionSync != baseline.motionSync
    }

    var pollingDirty: Bool { pollingRate != baseline.pollingRateHz }

    var powerDirty: Bool {
        sleepMinutes != baseline.sleepMinutes
            || deepSleepMinutes != baseline.deepSleepMinutes
            || debounceMs != baseline.debounceMs
    }

    var buttonsDirty: Bool { buttonActions != baseline.buttons }

    var anyDirty: Bool {
        dpiDirty || sensorDirty || pollingDirty || powerDirty || buttonsDirty
    }

    func discardDPI() {
        guard let values = baseline.dpiStages else { return }
        let enabled = baseline.stageEnabled
        let colours = baseline.colours
        stages = (0..<8).map { index in
            let dpi = index < values.count ? values[index] : 0
            let on = enabled.flatMap { index < $0.count ? $0[index] : false } ?? false
            var colour = Color.white
            if let colours, index < colours.count, colours[index].count == 3 {
                let c = colours[index]
                colour = Color(.sRGB, red: Double(c[0]) / 255,
                               green: Double(c[1]) / 255, blue: Double(c[2]) / 255)
            }
            return Stage(dpi: dpi, enabled: on, colour: colour)
        }
        activeStage = baseline.activeStage ?? 0
        note("discarded DPI changes")
    }

    func discardSensor() {
        liftOff2mm = baseline.liftOff2mm ?? false
        rippleControl = baseline.rippleControl ?? false
        angleSnap = baseline.angleSnap ?? false
        motionSync = baseline.motionSync ?? false
        note("discarded sensor changes")
    }

    func discardPolling() {
        pollingRate = baseline.pollingRateHz ?? 1000
        note("discarded polling rate change")
    }

    func discardPower() {
        sleepMinutes = baseline.sleepMinutes ?? 10
        deepSleepMinutes = baseline.deepSleepMinutes ?? 10
        debounceMs = baseline.debounceMs ?? 10
        note("discarded power changes")
    }

    func discardButtons() {
        buttonActions = baseline.buttons ?? AppState.factoryActionNames
        note("discarded button changes")
    }

    // MARK: Launching at login

    @Published var launchAtLogin = ScrollController.AppLogin.installed

    /// Whether this is the bundle rather than a bare binary.
    ///
    /// Only the bundle is worth launching at login: it keeps its Accessibility
    /// and Bluetooth grants across rebuilds, where a loose executable is
    /// identified by path and loses them.
    var canLaunchAtLogin: Bool { ScrollController.AppLogin.launcher != nil }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try ScrollController.AppLogin.install()
                note("will open at login, and keep running in the menu bar")
            } else {
                try ScrollController.AppLogin.uninstall()
                note("will no longer open at login")
            }
            launchAtLogin = ScrollController.AppLogin.installed
        } catch {
            note("login item: \(error.localizedDescription)")
            launchAtLogin = ScrollController.AppLogin.installed
        }
    }

    // MARK: Profiles

    @Published var profileNames: [String] = []
    @Published var newProfileName = ""

    func refreshProfiles() { profileNames = Profile.names() }

    /// Snapshot the whole editable state.
    ///
    /// This matters more here than in most apps: the protocol is **write-only**,
    /// so the device can never be asked what it is set to. A saved profile is
    /// the only record of a configuration that exists anywhere.
    func currentProfile() -> Profile {
        var profile = Profile()
        profile.dpiStages = stages.map { $0.dpi }
        profile.stageEnabled = stages.map { $0.enabled }
        profile.activeStage = activeStage
        profile.colours = stages.map {
            let c = rgb($0.colour)
            return [Int(c.r), Int(c.g), Int(c.b)]
        }
        profile.pollingRateHz = pollingRate
        profile.buttons = buttonActions
        profile.liftOff2mm = liftOff2mm
        profile.rippleControl = rippleControl
        profile.angleSnap = angleSnap
        profile.motionSync = motionSync
        profile.sleepMinutes = sleepMinutes
        profile.deepSleepMinutes = deepSleepMinutes
        profile.debounceMs = debounceMs
        return profile
    }

    func saveProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try currentProfile().save(as: trimmed)
            note("saved profile \"\(trimmed)\"")
            newProfileName = ""
            refreshProfiles()
        } catch {
            note("error: could not save profile — \(error.localizedDescription)")
        }
    }

    /// Load a profile into the editor **without** writing to the device, so the
    /// change can be reviewed before it is applied.
    func loadProfile(named name: String) {
        guard let profile = try? Profile.load(name) else {
            note("error: could not read profile \"\(name)\"")
            return
        }
        apply(profile: profile)
        provenance = .edited
        note("loaded profile \"\(name)\" into the editor — not yet written")
    }

    func apply(profile: Profile) {
        if let values = profile.dpiStages {
            let enabled = profile.stageEnabled
            let colours = profile.colours
            stages = (0..<8).map { index in
                let dpi = index < values.count ? values[index] : 0
                let on = enabled.flatMap { index < $0.count ? $0[index] : false }
                    ?? (index < values.count && dpi > 0)
                var colour = Color.white
                if let colours, index < colours.count, colours[index].count == 3 {
                    let c = colours[index]
                    colour = Color(.sRGB,
                                   red: Double(c[0]) / 255,
                                   green: Double(c[1]) / 255,
                                   blue: Double(c[2]) / 255)
                }
                return Stage(dpi: dpi, enabled: on, colour: colour)
            }
        }
        if let value = profile.activeStage { activeStage = value }
        if let value = profile.pollingRateHz { pollingRate = value }
        if let value = profile.buttons, value.count == 18 { buttonActions = value }
        if let value = profile.liftOff2mm { liftOff2mm = value }
        if let value = profile.rippleControl { rippleControl = value }
        if let value = profile.angleSnap { angleSnap = value }
        if let value = profile.motionSync { motionSync = value }
        if let value = profile.sleepMinutes { sleepMinutes = value }
        if let value = profile.deepSleepMinutes { deepSleepMinutes = value }
        if let value = profile.debounceMs { debounceMs = value }
    }

    func deleteProfile(named name: String) {
        try? FileManager.default.removeItem(at: Profile.url(name))
        note("deleted profile \"\(name)\"")
        refreshProfiles()
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

    /// Build report 0x04 from the eight slots as they stand.
    ///
    /// Slots are passed through by index — never compacted to the enabled ones.
    /// Compacting was the original bug here: switching off a middle stage moved
    /// every stage above it down, and the device accepted the result without
    /// complaint because it was still a well-formed report.
    func dpiReport() -> [UInt8] {
        DpiReport.buildSlots(
            stages.map {
                DpiReport.Slot(dpi: $0.dpi, enabled: $0.enabled, colour: rgb($0.colour))
            },
            activeSlot: activeStage,
            toggles: DpiReport.Toggles(
                liftOffDistance2mm: liftOff2mm,
                rippleControl: rippleControl,
                angleSnap: angleSnap,
                motionSync: motionSync
            ).bytes)
    }

    /// The active slot must be one that is switched on, or the mouse lands on a
    /// stage the user cannot cycle back to.
    var activeStageIsEnabled: Bool {
        stages.indices.contains(activeStage) && stages[activeStage].enabled
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
                if result.ok && !dryRun {
                    self.recordApplied()
                    self.captureBaseline()
                }
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
