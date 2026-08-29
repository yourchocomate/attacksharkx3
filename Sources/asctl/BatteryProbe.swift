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
        // Pick the transport on every pass, not once at the start.
        //
        // Flipping the mode switch mid-listen drops the Bluetooth link, and the
        // first version kept listening to the dead one while the mouse was busy
        // reporting on the other. Switching modes during the test is a
        // reasonable thing to do, so follow the mouse instead.
        var found: [Report] = []
        var announced = ""
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            let hid = HID.attackSharkDevices()
            let usable = hid.filter { $0.canConfigure }

            if !usable.isEmpty {
                if announced != "hid" {
                    announced = "hid"
                    print("── listening on the 2.4 GHz / USB link ──")
                }
                listenHID(devices: usable, seconds: min(4, remaining), into: &found)
                continue
            }

            if announced != "ble" {
                announced = "ble"
                if hid.isEmpty {
                    print("── no wired or receiver link — trying Bluetooth ──")
                } else {
                    // Seen but unusable is a different problem from absent, and
                    // it is the one worth naming: the interface exists and the
                    // configuration usage page is missing or not permitted.
                    print("── \(hid.count) Attack Shark interface(s) present but none "
                        + "configurable — trying Bluetooth ──")
                    for device in hid {
                        print(String(
                            format: "     %@ — usage %04X:%02X, %@, feature %d bytes",
                            device.product, device.usagePage, device.usage,
                            device.transport, device.maxFeatureReportSize))
                    }
                }
            }
            if !listenBLE(seconds: min(30, remaining), into: &found) {
                // Could not hold a Bluetooth link either. Wait a moment before
                // going round again so a mouse mid-switch is not hammered.
                Thread.sleep(forTimeInterval: 2)
                announced = ""
            }
        }
        return verdict(found)
    }

    // MARK: Transports

    private static func listenHID(
        devices: [HIDDeviceRef], seconds: TimeInterval, into found: inout [Report]
    ) {
        let watcher = InputWatcher(devices: devices, keepSamples: 256, quiet: true)
        for channel in watcher.run(seconds: max(1, min(2, seconds))) {
            for sample in channel.samples {
                guard let event = StatusEvent.parse(sample) else { continue }
                note(event, sample, into: &found)
            }
        }
    }

    /// Returns false if the link could not be opened or was lost, so the
    /// caller can re-examine which transport the mouse is actually on.
    @discardableResult
    private static func listenBLE(seconds: TimeInterval, into found: inout [Report]) -> Bool {
        let ble = BLEConnection()
        defer { ble.disconnect() }

        guard ble.discover() else {
            print("   \(ble.lastError ?? "no peripheral found")")
            return false
        }
        guard let target = ble.foundPeripherals.map({ $0.0 }).first(where: GUITransport.isX3) else {
            let seen = ble.foundPeripherals.map { $0.0.name ?? "(unnamed)" }
            print("   the mouse was not among: \(seen.joined(separator: ", "))")
            return false
        }
        guard ble.connect(target), ble.subscribe() else {
            print("   \(ble.lastError ?? "could not open the GATT link")")
            return false
        }
        print("   connected — \(ble.connectedName ?? "?")")

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            ble.pump(seconds: 1.0)
            for packet in ble.takeNotifications() {
                guard let event = StatusEvent.parseBLE(packet) else { continue }
                note(event, packet, into: &found)
            }
            if ble.isDisconnected {
                print("   the link dropped — re-checking which link the mouse is on")
                return false
            }
        }
        return true
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

/// Does macOS get its battery figure from GATT 2A19, or from somewhere else?
///
/// It reports this mouse at 100% while 2A19 reads back as 190, which has two
/// explanations that look identical from the outside: macOS reads 2A19 and
/// clamps the result to 100, or macOS has a genuine level from a source we have
/// not found. Replicating the wrong one would put a fabricated 100% in the UI.
///
/// The counter itself distinguishes them. It advances by exactly one per read
/// *by anybody*, so it doubles as a counter of who is reading. Take a reading,
/// let macOS report the battery several times while we read nothing, then take
/// another. If the gap is bigger than our own two reads, the extra reads were
/// macOS's — and its 100% is this counter, clamped.
enum MacOSBatterySource {
    static func run() -> Int32 {
        let probes = 5

        guard let before = readCounter() else { return 1 }
        print("2A19 before: \(before)")

        print("\nasking macOS \(probes) times, reading nothing ourselves:")
        for index in 1...probes {
            let reported = macOSBatteryLine() ?? "no reading"
            print("  \(index). system_profiler says \(reported)")
        }

        guard let after = readCounter() else { return 1 }
        print("\n2A19 after:  \(after)")

        // Our own two reads accounted for; anything beyond them came from
        // somewhere else on this machine, and bluetoothd is the only candidate.
        let moved = after - before
        let ours = 1
        let others = moved - ours

        print("\n── verdict ──")
        print("the counter moved \(moved); \(ours) of that is our own second read")
        if others <= 0 {
            print("• nothing else read 2A19 while macOS reported \(probes) times")
            print("  → macOS is NOT using this characteristic. Its figure comes")
            print("    from a source we have not found, and clamping is not the")
            print("    explanation.")
        } else {
            print("• \(others) extra read(s) happened while only macOS was asking")
            print("  → macOS reads 2A19 too. It reported 100% throughout while the")
            print("    counter sat near \(after), so its number is this counter")
            print("    clamped to 100 — not a battery level, and not worth copying.")
        }
        return 0
    }

    private static func readCounter() -> Int? {
        let ble = BLEConnection()
        defer { ble.disconnect() }
        guard ble.discover(),
              let target = ble.foundPeripherals.map({ $0.0 }).first(where: GUITransport.isX3),
              ble.connect(target)
        else {
            print(ble.lastError ?? "could not reach the mouse over Bluetooth")
            return nil
        }
        return ble.readBattery(timeout: 4)
    }

    private static func macOSBatteryLine() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var withinMouse = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("Mouse:") { withinMouse = trimmed.contains("X3") }
            if withinMouse, trimmed.hasPrefix("Battery Level:") {
                return trimmed.replacingOccurrences(of: "Battery Level:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
