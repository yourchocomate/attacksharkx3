import CoreBluetooth
import Foundation

/// Sending reports on behalf of the GUI.
///
/// The CLI's `sendReports` prints to stdout and resolves a device per call.
/// The GUI needs the same wire behaviour with two differences: every line of
/// progress has to reach a log the window can show, and a Bluetooth session
/// should be opened once rather than per report.
enum GUITransport {
    enum Link: String, CaseIterable, Identifiable {
        case receiver = "2.4 GHz / USB"
        case bluetooth = "Bluetooth"
        var id: String { rawValue }
    }

    struct Result {
        var ok: Bool
        var lines: [String]
        var acknowledgements: [[UInt8]]
    }

    /// Send `reports`, each preceded by the mandatory preamble.
    ///
    /// The preamble goes before *every* report rather than once per session:
    /// a report that arrives without it is acknowledged and then silently
    /// dropped, which is the single easiest way to produce a write that looks
    /// like it worked and did nothing.
    static func send(_ reports: [[UInt8]], over link: Link, dryRun: Bool) -> Result {
        var lines: [String] = []
        for report in reports {
            lines.append("→ \(Hex.encode(report))")
        }
        if dryRun {
            lines.append("dry run — nothing was written")
            return Result(ok: true, lines: lines, acknowledgements: [])
        }
        switch link {
        case .receiver: return sendOverHID(reports, lines: lines)
        case .bluetooth: return sendOverBLE(reports, lines: lines)
        }
    }

    private static func sendOverHID(_ reports: [[UInt8]], lines: [String]) -> Result {
        var lines = lines
        let candidates = HID.attackSharkDevices().filter { $0.canConfigure }
        guard let info = candidates.first else {
            lines.append("no configurable interface found — connect the receiver or the USB cable")
            return Result(ok: false, lines: lines, acknowledgements: [])
        }
        let connection = HIDConnection(info)
        do {
            try connection.open()
            for report in reports {
                try connection.setFeatureRetrying(PollingRate.preamble)
                usleep(120_000)
                try connection.setFeatureRetrying(report)
                usleep(120_000)
            }
            lines.append("ok — \(reports.count) report(s) written over \(info.transport)")
            return Result(ok: true, lines: lines, acknowledgements: [])
        } catch {
            lines.append("error: \(error)")
            return Result(ok: false, lines: lines, acknowledgements: [])
        }
    }

    private static func sendOverBLE(_ reports: [[UInt8]], lines: [String]) -> Result {
        var lines = lines
        let ble = BLEConnection()
        guard ble.discover() else {
            lines.append("error: \(ble.lastError ?? "no Bluetooth peripheral found")")
            return Result(ok: false, lines: lines, acknowledgements: [])
        }
        guard let target = ble.foundPeripherals.map({ $0.0 }).first(where: isX3) else {
            lines.append("error: the mouse was not among the peripherals found")
            return Result(ok: false, lines: lines, acknowledgements: [])
        }
        guard ble.connect(target) else {
            lines.append("error: \(ble.lastError ?? "no FEE3 characteristic")")
            return Result(ok: false, lines: lines, acknowledgements: [])
        }
        // Without this the device accepts FEE3 writes and discards them.
        guard ble.subscribe() else {
            lines.append("error: could not subscribe to FEE4 notifications")
            return Result(ok: false, lines: lines, acknowledgements: [])
        }
        for report in reports {
            guard ble.write(PollingRate.preamble), ble.write(report) else {
                lines.append("error: \(ble.lastError ?? "GATT write failed")")
                return Result(ok: false, lines: lines, acknowledgements: ble.notifications)
            }
        }
        ble.listen(seconds: 1.5)
        if ble.notifications.isEmpty {
            lines.append("warning: no acknowledgements — the device may have ignored this")
        } else {
            for packet in ble.notifications {
                lines.append("← ack \(Hex.encode(packet))")
            }
        }
        lines.append("ok — \(reports.count) report(s) written over Bluetooth")
        return Result(ok: true, lines: lines, acknowledgements: ble.notifications)
    }

    /// Is this peripheral actually the mouse?
    ///
    /// The scan is unfiltered, so it turns up every nearby BLE device. Falling
    /// back to "whatever answered first" was a real bug: it read GATT 2A19 off
    /// a stranger's device, which is why the level jumped around between reads
    /// and could exceed 100. Match the X3 by name or return nothing.
    static func isX3(_ peripheral: CBPeripheral) -> Bool {
        let name = (peripheral.name ?? "").lowercased()
        return name.contains("x3") || name.contains("attack shark")
    }

    /// Battery level, which is only reachable over Bluetooth GATT.
    ///
    /// Returns the level plus a diagnostic line naming the peripheral it came
    /// from and the raw bytes, because a level that looks wrong is almost
    /// always the wrong device rather than a decoding error, and only the raw
    /// read distinguishes the two.
    static func readBattery() -> (Int?, String) {
        let ble = BLEConnection()
        defer { ble.disconnect() }

        guard ble.discover() else { return (nil, ble.lastError ?? "no peripheral found") }
        let seen = ble.foundPeripherals.map { $0.0.name ?? "(unnamed)" }
        guard let target = ble.foundPeripherals.map({ $0.0 }).first(where: isX3) else {
            return (nil, "the mouse was not among: \(seen.joined(separator: ", "))")
        }
        guard ble.connect(target) else { return (nil, ble.lastError ?? "connect failed") }
        guard let level = ble.readBattery() else { return (nil, "no battery characteristic") }

        let source = "\(ble.connectedName ?? "?") 2A19=\(Hex.encode(ble.batteryRaw))"
        guard (0...100).contains(level) else {
            return (nil, "implausible reading from \(source) — ignored")
        }
        return (level, "battery \(level)% from \(source)")
    }
}
