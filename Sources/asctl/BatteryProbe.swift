import Foundation

/// Wait for the mouse to volunteer its battery level.
///
/// GATT 2A19 was a dead end and is settled: it sits at the Battery Level UUID
/// but is a read counter. It rose by exactly one on every read, by nothing over
/// thirty idle seconds, carried across disconnects, and went past 100 and kept
/// climbing. macOS shows "100%" for this mouse by reading that same value and
/// clamping it, so the system readout is not independent confirmation.
///
/// The vendor software does display a battery — a 0–100 progress bar — and it
/// fills it from a status event rather than a read: code 0x4010 carries a level
/// of 1…10 in its high byte, which the vendor multiplies by ten. So the level
/// cannot be fetched at all. It arrives when the device chooses to send it, and
/// the only question left is *when* that is.
///
/// This listens on whichever link is up and prints every status event, so an
/// hour of silence and a battery event thirty seconds in are told apart by
/// evidence rather than by waiting and guessing.
enum BatteryProbe {
    static func run(seconds: TimeInterval) -> Int32 {
        let hid = HID.attackSharkDevices().filter { $0.canConfigure }
        if !hid.isEmpty {
            print("listening on the 2.4 GHz / USB link for \(Int(seconds))s\n")
            return listenHID(devices: hid, seconds: seconds)
        }
        print("no wired or receiver link — trying Bluetooth\n")
        return listenBLE(seconds: seconds)
    }

    // MARK: Transports

    private static func listenHID(devices: [HIDDeviceRef], seconds: TimeInterval) -> Int32 {
        var found: [Report] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let watcher = InputWatcher(devices: devices, keepSamples: 256, quiet: true)
            for channel in watcher.run(seconds: 2) {
                for sample in channel.samples {
                    guard let event = StatusEvent.parse(sample) else { continue }
                    note(event, sample, into: &found)
                }
            }
        }
        return verdict(found)
    }

    private static func listenBLE(seconds: TimeInterval) -> Int32 {
        let ble = BLEConnection()
        defer { ble.disconnect() }

        guard ble.discover() else {
            print(ble.lastError ?? "no peripheral found")
            return 1
        }
        guard let target = ble.foundPeripherals.map({ $0.0 }).first(where: GUITransport.isX3) else {
            let seen = ble.foundPeripherals.map { $0.0.name ?? "(unnamed)" }
            print("the mouse was not among: \(seen.joined(separator: ", "))")
            return 1
        }
        guard ble.connect(target), ble.subscribe() else {
            print(ble.lastError ?? "could not open the GATT link")
            return 1
        }
        print("connected — \(ble.connectedName ?? "?"), listening \(Int(seconds))s")
        print("(click, scroll, press the DPI button, then leave it alone)\n")

        var found: [Report] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            ble.pump(seconds: 1.0)
            for packet in ble.takeNotifications() {
                guard let event = StatusEvent.parseBLE(packet) else { continue }
                note(event, packet, into: &found)
            }
            if ble.isDisconnected {
                print("the link dropped")
                break
            }
        }
        return verdict(found)
    }

    // MARK: Reporting

    private struct Report {
        let event: StatusEvent.Event
        let raw: [UInt8]
        let at: Date
    }

    private static func note(
        _ event: StatusEvent.Event, _ raw: [UInt8], into found: inout [Report]
    ) {
        let report = Report(event: event, raw: raw, at: Date())
        found.append(report)
        let marker = event.batteryPercent != nil ? "  ← BATTERY" : ""
        print("  \(Hex.encode(raw))  \(event.description)\(marker)")
    }

    private static func verdict(_ found: [Report]) -> Int32 {
        print("\n── verdict ──")
        guard !found.isEmpty else {
            print("no status events at all. Either the mouse sent nothing, or")
            print("this link does not carry them.")
            return 0
        }

        let battery = found.filter { $0.event.batteryPercent != nil }
        guard !battery.isEmpty else {
            let kinds = Set(found.map { $0.event.description })
            print("\(found.count) status event(s) arrived, none of them battery.")
            print("Kinds seen: \(kinds.sorted().joined(separator: ", ")).")
            print("So the link does carry events — the device simply did not")
            print("send a level in this window.")
            return 0
        }

        let levels = battery.compactMap { $0.event.batteryPercent }
        print("\(battery.count) battery event(s): "
            + levels.map { "\($0)%" }.joined(separator: ", "))
        if let first = battery.first, let start = found.first {
            let delay = first.at.timeIntervalSince(start.at)
            print(String(format: "first one %.0fs into the listen.", delay))
        }
        print("These are pushed, not fetched, so the app should cache the last")
        print("one and wait for the next rather than asking.")
        return 0
    }
}
