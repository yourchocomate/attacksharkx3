import Foundation

/// Device identities recovered from the vendor software.
///
/// The vendor software hands two VID/PID pairs to its two HID wrapper
/// instances, and probes separately for a third identity over Bluetooth.
enum KnownDevices {
    struct Identity {
        let vendorID: Int
        let productID: Int
        let label: String
    }

    /// 0x1D57 is the dongle's VID. The two PIDs correspond to the two driver
    /// wrapper instances the Windows app loads: the first takes 0xFA60, the
    /// second 0xFA61.
    static let dongle = [
        Identity(vendorID: 0x1D57, productID: 0xFA60, label: "X3 2.4GHz receiver (driver 1)"),
        Identity(vendorID: 0x1D57, productID: 0xFA61, label: "X3 2.4GHz receiver (driver 2)"),
    ]

    /// The Bluetooth identity — **confirmed on hardware**: it enumerates as
    /// `Bluetooth Low Energy` with the product string `X3-5.2 Mouse`, and it is
    /// the same VID/PID the vendor software probes for.
    ///
    /// Note it is Microsoft's VID with the generic "Wheel Mouse Optical" PID,
    /// which the X3 clones — so a genuine Microsoft mouse would also match.
    ///
    /// Over Bluetooth the mouse exposes a maximum feature report size of **one
    /// byte**, so configuration cannot go through HID feature reports on this
    /// path — but it is *not* unconfigurable. The same reports work over GATT
    /// with `--ble`: write to FEE3, acknowledgements arrive on FEE4.
    static let bluetooth = [
        Identity(
            vendorID: 0x045E, productID: 0x0040,
            label: "X3 over Bluetooth (cloned Microsoft ID)")
    ]

    static var all: [Identity] { dongle + bluetooth }

    static func matches(vendorID: Int, productID: Int) -> Bool {
        all.contains { $0.vendorID == vendorID && $0.productID == productID }
    }

    static func label(vendorID: Int, productID: Int) -> String? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }?.label
    }

    static func isAmbiguous(vendorID: Int, productID: Int) -> Bool {
        bluetooth.contains { $0.vendorID == vendorID && $0.productID == productID }
    }
}

/// Report framing recovered from the vendor software.
///
/// Every configuration exchange is a HID **feature** report. The logical buffer
/// the application builds has a three-byte header:
///
///     byte 0      report ID   (0x04, 0x08, 0x09, 0x0C, …)
///     byte 1      total length of the logical buffer, in bytes
///     byte 2      command / profile / index
///     bytes 3…    payload
///
/// The length byte is not a guess: the app writes the header
/// `0C 0A 01 FE` and then passes literal length `10` (`0x0A`) to the sender, and
/// the device's own report descriptor independently reports report 0x08 as 59
/// bytes against a `0x3B` header byte, and report 0x09 as 64 against `0x40`.
///
/// When a logical buffer is longer than one report, the wireless path in
/// the sender fragments it into report-0x09 packets that carry a fourth
/// header byte:
///
///     byte 0      0x09
///     byte 1      meaningful bytes in *this* packet (0x40 full, remainder last)
///     byte 2      the original header's command byte
///     byte 3      chunk sequence, 0…2
///     bytes 4-63  60-byte slice of the payload
///
/// A 131-byte macro upload (`09 83 <index> …`) therefore becomes
/// 60 + 60 + 8 payload bytes across three packets, the last one tagged `0x0C`
/// = 4 header + 8 payload. The wired path skips fragmentation entirely and
/// hands the logical buffer straight to `HidD_SetFeature`.
enum X3Report {
    static let configReportID: UInt8 = 0x09
    static let configReportLength = 64

    /// Logical buffers carry a 3-byte header; fragmented 0x09 packets add the
    /// sequence byte for 4.
    static let logicalHeaderLength = 3
    static let chunkHeaderLength = 4
    static let maxChunkPayload = configReportLength - chunkHeaderLength  // 60

    /// Report IDs the Windows software is known to build, with the length it
    /// declares for each. Purposes are inferred from the surrounding UI code and
    /// are marked where they are not yet confirmed against hardware.
    struct KnownReport {
        let reportID: UInt8
        let totalLength: Int
        let purpose: String
        let confirmed: Bool
    }

    static let knownReports: [KnownReport] = [
        .init(reportID: 0x04, totalLength: 56, purpose: "mouse attributes / feature toggles", confirmed: false),
        .init(reportID: 0x05, totalLength: 15, purpose: "unknown", confirmed: false),
        .init(reportID: 0x06, totalLength: 9, purpose: "unknown", confirmed: false),
        .init(reportID: 0x08, totalLength: 59, purpose: "settings block", confirmed: false),
        .init(reportID: 0x09, totalLength: 64, purpose: "config channel / chunked transfers", confirmed: true),
        .init(reportID: 0x0C, totalLength: 10, purpose: "short command, sent first in the apply sequence", confirmed: false),
        .init(reportID: 0xA0, totalLength: 8, purpose: "status — readable without a preceding write", confirmed: true),
    ]

    /// Build a logical command buffer, filling in the length byte.
    static func command(reportID: UInt8, command: UInt8, payload: [UInt8] = []) -> [UInt8] {
        var buffer: [UInt8] = [reportID, 0, command]
        buffer += payload
        buffer[1] = UInt8(truncatingIfNeeded: buffer.count)
        return buffer
    }

    /// The 16-bit checksum the device expects on the larger reports.
    ///
    /// It is a plain sum of every payload byte — that is, from offset 3 up to
    /// but not including the checksum itself — stored **big-endian** (high byte
    /// first) immediately after the payload, with the remainder of the declared
    /// length left as zero padding.
    ///
    /// Verified against two independent implementations in the vendor software: the
    /// scalar version for report 0x05 (summing bytes
    /// 3…10 into bytes 11–12) and the SSE version for report 0x04
    /// (summing bytes 3…49 into bytes 50–51).
    ///
    /// Note report 0x06 does *not* use this: it validates its single payload
    /// byte with a one's complement instead.
    static func checksum(payload: ArraySlice<UInt8>) -> (high: UInt8, low: UInt8) {
        let sum = payload.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        return (high: UInt8(truncatingIfNeeded: sum >> 8), low: UInt8(truncatingIfNeeded: sum))
    }

    /// Build a report of `totalLength` bytes: header, payload, checksum, padding.
    static func checksummed(
        reportID: UInt8, command: UInt8, payload: [UInt8], totalLength: Int
    ) -> [UInt8] {
        precondition(
            logicalHeaderLength + payload.count + 2 <= totalLength,
            "payload + checksum exceeds the report's declared length")

        var report = [UInt8](repeating: 0, count: totalLength)
        report[0] = reportID
        report[1] = UInt8(truncatingIfNeeded: totalLength)
        report[2] = command
        report.replaceSubrange(
            logicalHeaderLength..<(logicalHeaderLength + payload.count), with: payload)

        let sum = checksum(payload: report[logicalHeaderLength..<(logicalHeaderLength + payload.count)])
        report[logicalHeaderLength + payload.count] = sum.high
        report[logicalHeaderLength + payload.count + 1] = sum.low
        return report
    }

    /// Build one fragmented report-0x09 packet.
    static func chunk(command: UInt8, sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= maxChunkPayload, "payload exceeds \(maxChunkPayload) bytes")
        var report = [UInt8](repeating: 0, count: configReportLength)
        report[0] = configReportID
        report[1] = UInt8(chunkHeaderLength + payload.count)
        report[2] = command
        report[3] = sequence
        report.replaceSubrange(
            chunkHeaderLength..<(chunkHeaderLength + payload.count), with: payload)
        return report
    }

    /// Split a payload the way the wireless path does.
    static func fragment(command: UInt8, payload: [UInt8]) -> [[UInt8]] {
        guard !payload.isEmpty else { return [chunk(command: command, sequence: 0, payload: [])] }
        return stride(from: 0, to: payload.count, by: maxChunkPayload).enumerated().map {
            index, start in
            let end = min(start + maxChunkPayload, payload.count)
            return chunk(
                command: command,
                sequence: UInt8(index),
                payload: Array(payload[start..<end])
            )
        }
    }
}

/// Polling rate — report 0x06, decoded in full from the vendor software.
///
/// The wire value is a divider against 1000 Hz, and byte 4 is its one's
/// complement. The UI's four presets (Power Saving / Office / Gaming /
/// E-sports) map to indices 0…3 and thence to dividers 8/4/2/1.
enum PollingRate {
    static let supported = [125, 250, 500, 1000]

    /// The preamble the vendor software sends at the top of every apply.
    ///
    /// It is not optional. Confirmed on hardware: sent on its own, a polling
    /// rate write is acknowledged at the USB level and then silently ignored.
    /// Sent immediately after this preamble, the same bytes take effect.
    static let preamble: [UInt8] = [0x0C, 0x0A, 0x01, 0xFE, 0x01, 0xFE, 0, 0, 0, 0]

    /// 1000 / hz, i.e. the value the device actually stores.
    static func divider(forHz hz: Int) -> UInt8? {
        guard supported.contains(hz) else { return nil }
        return UInt8(1000 / hz)
    }

    static func hz(forDivider divider: UInt8) -> Int? {
        guard divider != 0, 1000 % Int(divider) == 0 else { return nil }
        let value = 1000 / Int(divider)
        return supported.contains(value) ? value : nil
    }

    /// `06 09 01 <divider> <~divider> 00 00 00 00`
    static func report(hz: Int) -> [UInt8]? {
        guard let divider = divider(forHz: hz) else { return nil }
        var report = [UInt8](repeating: 0, count: 9)
        report[0] = 0x06
        report[1] = 0x09  // declared length
        report[2] = 0x01  // command
        report[3] = divider
        report[4] = ~divider
        return report
    }
}

// MARK: - Formatting helpers

enum Hex {
    static func encode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parse "09 40 00" / "0x09,0x40" / "094000" into bytes.
    static func decode(_ text: String) -> [UInt8]? {
        let cleaned =
            text
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ":", with: " ")

        let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        if tokens.count > 1 {
            var out: [UInt8] = []
            for token in tokens {
                guard let value = UInt8(token, radix: 16) else { return nil }
                out.append(value)
            }
            return out
        }

        // One long run of hex digits.
        let digits = Array(cleaned.filter { !$0.isWhitespace })
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let value = UInt8(String(digits[i...(i + 1)]), radix: 16) else { return nil }
            out.append(value)
        }
        return out
    }

    /// Classic offset / hex / ASCII dump.
    static func dump(_ bytes: [UInt8], indent: String = "  ") -> String {
        var lines: [String] = []
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let row = Array(bytes[start..<min(start + 16, bytes.count)])
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(row.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(
                indent + String(format: "%04X  %-47s  |%@|", start, (hex as NSString).utf8String!, ascii)
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// DPI — report `0x04`.
///
/// This one report carries the whole DPI block *and* four sensor toggles *and*
/// the per-stage LED colours. There is no way to read the current values first
/// — the protocol is write-only — so writing it necessarily replaces all of them.
///
/// Layout, 56 bytes:
///
///     0      0x04                report ID
///     1      0x38 (56)           declared length
///     2      0x01                command
///     3      lift-off distance   2-option
///     4      ripple control      2-option
///     5      enabled-stage bitmask, one bit per stage (`bts eax, 0…7`)
///     6      angle snap          2-option
///     7      motion sync         2-option
///     8–15   DPI low  bytes, stages 0…7
///     16–23  DPI high bytes, stages 0…7
///     24     active stage + 1
///     25–48  8 × RGB triplet, per-stage colour
///     49     0x01
///     50–51  checksum, high then low
///     52–55  zero padding
///
/// Bytes 3/4/6/7 are each a two-valued toggle. The naming is not guessed — the
/// vendor software labels each one explicitly:
///
///     byte 3  lift-off distance   0 = 1 mm, 1 = 2 mm
///     byte 4  ripple control      0 = off,  1 = on
///     byte 6  angle snap          0 = off,  1 = on
///     byte 7  motion sync         0 = off,  1 = on
///
/// Note the unusual DPI encoding: each stage is stored as **`value − 1`** as a
/// 16-bit quantity, split across two separate byte *planes* — all eight low
/// bytes, then all eight high bytes — rather than as consecutive pairs.
enum DpiReport {
    /// The four sensor toggles that share report 0x04 with the DPI block.
    ///
    /// They cannot be written independently: the report is atomic and there is
    /// no readback, so every write necessarily sets all four.
    struct Toggles {
        /// false = 1 mm, true = 2 mm
        var liftOffDistance2mm = false
        var rippleControl = false
        var angleSnap = false
        var motionSync = false

        var bytes: (UInt8, UInt8, UInt8, UInt8) {
            (
                liftOffDistance2mm ? 1 : 0,
                rippleControl ? 1 : 0,
                angleSnap ? 1 : 0,
                motionSync ? 1 : 0
            )
        }

        var summary: String {
            "lift-off \(liftOffDistance2mm ? "2mm" : "1mm")"
                + ", ripple \(rippleControl ? "on" : "off")"
                + ", angle-snap \(angleSnap ? "on" : "off")"
                + ", motion-sync \(motionSync ? "on" : "off")"
        }
    }

    static let reportID: UInt8 = 0x04
    static let totalLength = 56
    static let maxStages = 8

    /// DPI is stored in **units of 50**, and then decremented.
    ///
    /// Settled from the vendor software, not guessed: the UI divides a typed DPI by 50
    /// before storing it (`0x51EB851F` / `sar edx, 4` — the
    /// standard divide-by-50 sequence) and multiplies by 50 to display it
    /// (`imul eax, edi, 0x32`). The report builder then subtracts one.
    ///
    ///     wire = (dpi / 50) - 1        dpi = (wire + 1) * 50
    ///
    /// Confirmed on hardware: wire 7 (400 DPI) and wire 63 (3200 DPI) produce
    /// sensor counts differing by roughly the expected factor.
    static let dpiStep = 50

    static func wireValue(forDpi dpi: Int) -> UInt16 {
        UInt16(clamping: max(0, dpi / dpiStep - 1))
    }

    static func dpi(forWireValue wire: UInt16) -> Int {
        (Int(wire) + 1) * dpiStep
    }
    static func build(
        stages: [Int],
        activeStage: Int = 0,
        colours: [(r: UInt8, g: UInt8, b: UInt8)] = [],
        toggles: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0),
        profile: UInt8 = 1,
        length: Int = totalLength,
        declaredLength: Int? = nil
    ) -> [UInt8] {
        precondition(!stages.isEmpty && stages.count <= maxStages)

        var report = [UInt8](repeating: 0, count: length)
        report[0] = reportID
        report[1] = UInt8(declaredLength ?? length)
        // Byte 2 is hardcoded to 1 by every builder in the vendor app. The
        // device advertises five profile slots (status event 0x8000 validates
        // 1...5), so this is the obvious candidate for the profile selector --
        // untested until something is written to a slot other than 1.
        report[2] = profile
        report[3] = toggles.0
        report[4] = toggles.1
        report[6] = toggles.2
        report[7] = toggles.3

        var mask: UInt8 = 0
        for index in stages.indices { mask |= (1 << UInt8(index)) }
        report[5] = mask

        for (index, dpi) in stages.enumerated() {
            let wire = wireValue(forDpi: dpi)
            report[8 + index] = UInt8(truncatingIfNeeded: wire)
            report[16 + index] = UInt8(truncatingIfNeeded: wire >> 8)
        }

        report[24] = UInt8(clamping: activeStage + 1)

        // A default palette, so a write never leaves every stage unlit.
        let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (255, 0, 0), (255, 128, 0), (255, 255, 0), (0, 255, 0),
            (0, 255, 255), (0, 0, 255), (255, 0, 255), (255, 255, 255),
        ]
        for index in 0..<maxStages {
            let colour = index < colours.count ? colours[index] : palette[index]
            report[25 + index * 3] = colour.r
            report[26 + index * 3] = colour.g
            report[27 + index * 3] = colour.b
        }

        report[49] = 0x01

        let sum = X3Report.checksum(payload: report[3...49])
        report[50] = sum.high
        report[51] = sum.low
        return report
    }
}

/// Lighting — report `0x05`, built inline by the vendor software.
///
/// Field names are taken from the vendor's own UI bindings, not guessed: each
/// stored value is wired to a named control — mode, brightness, speed — and
/// three consecutive bytes are composed into a colour swatch as 0xRRGGBB.
///
/// Layout, 15 bytes:
///
///     0      0x05
///     1      0x0F (15)
///     2      0x01
///     3      mode << 4
///     4      (0x92c & 0xF0) | (9 - speed)
///     5      (deep sleep low nibble << 4) | (mode is static ? brightness : 8)
///     6      R
///     7      G
///     8      B
///     9      sleep time, minutes
///     10     key response time, ms
///     11–12  checksum, high then low (sum of bytes 3…10)
///     13–14  zero padding
///
/// `0x92c` is unidentified and assumed zero here; it contributes its high
/// nibble to byte 4 and its low nibble to byte 5.
enum LightReport {
    static let reportID: UInt8 = 0x05
    static let totalLength = 15

    /// Mode indices are 0-based, matching the vendor's twelve-entry mode list.
    ///
    /// The builder branches on `mode == 1 || mode == 9` to decide whether the
    /// brightness slider reaches the wire. Under 0-based indexing
    /// those are exactly Static and Static Mixed Colour — the two non-animated
    /// modes — which is what makes 0-based the right reading.
    enum Mode: UInt8, CaseIterable {
        case off = 0
        case staticColour = 1
        case breathing = 2
        case neon = 3
        case colourBreathing = 4
        case colourStatic = 5
        case mixedBreathing = 6
        case rainbowWave = 7
        case lightning = 8
        case staticMixedColour = 9
        case marquee = 10
        case marquee2 = 11

        /// The vendor's live mode list hides entries 8-12, so only the first
        /// seven are selectable on this model — the rest belong to other
        /// products sharing the same implementation.
        ///
        /// The Bluetooth list is shorter still: six entries, 0…5. Neon is the
        /// first mode Bluetooth cannot select.
        ///
        /// Moot on the X3, which has no user-controllable lighting at all, but
        /// correct for models that do.
        var availableOn24GHz: Bool { rawValue <= 6 }
        var availableOnBluetooth: Bool { rawValue <= 5 }

        var label: String {
            switch self {
            case .off: return "LED Off"
            case .staticColour: return "Static"
            case .breathing: return "Breathing"
            case .neon: return "Neon"
            case .colourBreathing: return "Color Breathing"
            case .colourStatic: return "Color Static"
            case .mixedBreathing: return "Mixed Breathing"
            case .rainbowWave: return "Rainbow Wave"
            case .lightning: return "Lightning"
            case .staticMixedColour: return "Static Mixed Color"
            case .marquee: return "Marquee"
            case .marquee2: return "Marquee 2"
            }
        }

        /// Only these two carry the brightness slider through to the wire.
        var usesBrightness: Bool { self == .staticColour || self == .staticMixedColour }

        static func named(_ text: String) -> Mode? {
            let key = text.lowercased().replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            if let value = UInt8(text), let mode = Mode(rawValue: value) { return mode }
            return allCases.first {
                $0.label.lowercased().replacingOccurrences(of: " ", with: "") == key
                    || "\($0)".lowercased() == key
            }
        }
    }

    /// Report 0x05 is a *mixed* settings report: lighting **and** power
    /// management **and** key debounce travel together.
    ///
    /// Beware the vendor's internal names for these three — they contradict
    /// the labels its own UI displays, and the labels are the truth:
    ///
    /// | Byte | Setting | Range |
    /// |---|---|---|
    /// | 9 | sleep time | 1-60 min |
    /// | 4/5 | deep sleep time | 1-60 min |
    /// | 10 | key response time (debounce) | 2-25 ms |
    ///
    /// Deep sleep is split across two bytes: its high nibble into byte 4 and
    /// its low nibble into byte 5's high nibble.
    ///
    /// | Field | Range |
    /// |---|---|
    /// | brightness | 1…8 |
    /// | speed | **4…8** |
    ///
    /// Slider values reach the wire unscaled.
    /// Speed is inverted on the wire as `9 - speed`, so 4…8 becomes 5…1 in byte
    /// 4's low nibble — it never reaches 0, and never collides with the deep
    /// sleep nibble above it.
    ///
    /// `modeByteOverride` replaces byte 3 outright. It exists for `light-probe`,
    /// which tests alternative encodings of the mode field; normal callers leave
    /// it nil and get the encoding the vendor software uses.
    static func build(
        mode: Mode,
        red: UInt8 = 255, green: UInt8 = 0, blue: UInt8 = 0,
        brightness: UInt8 = 8,
        speed: UInt8 = 4,
        sleepMinutes: UInt8 = 0,
        deepSleepMinutes: UInt8 = 0,
        keyDebounceMs: UInt8 = 0,
        modeByteOverride: UInt8? = nil,
        forceBrightness: Bool = false
    ) -> [UInt8] {
        let clampedBrightness = min(max(brightness, 1), 8)
        let clampedSpeed = min(max(speed, 4), 8)

        var report = [UInt8](repeating: 0, count: totalLength)
        report[0] = reportID
        report[1] = UInt8(totalLength)
        report[2] = 0x01
        report[3] = modeByteOverride ?? (mode.rawValue << 4)
        report[4] = (deepSleepMinutes & 0xF0) | (9 &- clampedSpeed)
        report[5] = ((deepSleepMinutes & 0x0F) << 4)
            | ((mode.usesBrightness || forceBrightness) ? clampedBrightness : 8)
        report[6] = red
        report[7] = green
        report[8] = blue
        report[9] = sleepMinutes
        report[10] = keyDebounceMs

        let sum = X3Report.checksum(payload: report[3...10])
        report[11] = sum.high
        report[12] = sum.low
        return report
    }
}

/// Status events — input report `0x03` on the 2.4GHz config interface.
///
/// The vendor's HID wrapper runs a reader thread that does a blocking
/// `ReadFile` on the HID device and turns each report into a Windows message
/// (0x10001b37–0x10001b8f):
///
///     if (buf[0] != 3) return;
///     wParam = (buf[2] << 8) | buf[1];   // event code
///     lParam = (buf[4] << 8) | buf[3];   // value
///     PostMessageA(hWnd, ButtonMsg, wParam, lParam);
///
/// The vendor software then dispatches on the event code.
///
/// The frame layout is **confirmed on hardware** against two event types: a DPI
/// stage change arrives as `03 00 10 0N 00` (code 0x1000, value N) and a write
/// acknowledgement as `03 10 50 00 RR` (code 0x5010, value RR << 8).
enum StatusEvent {
    static let reportID: UInt8 = 0x03
    static let length = 5

    enum Code: UInt16 {
        case dpiStage = 0x1000
        case pollingRate = 0x2000
        case battery = 0x4010
        case writeAck = 0x5010
        case batteryLevel = 0x6000
        case lightMode = 0x7000
        case profile = 0x8000
    }

    struct Event {
        let code: UInt16
        let value: UInt16

        var known: Code? { Code(rawValue: code) }

        /// Battery percentage, for a 0x4010 event.
        ///
        /// The vendor software takes the high byte as a level in
        /// 1…10, rejects anything outside that range, and multiplies by 10 for
        /// both the progress bar and the "%d%%" label — so the device only ever
        /// reports battery in **10% steps**.
        var batteryPercent: Int? {
            switch code {
            case Code.battery.rawValue:
                let level = Int(value >> 8)
                return (1...10).contains(level) ? level * 10 : nil
            case Code.batteryLevel.rawValue:
                let level = Int(value)
                return (1...10).contains(level) ? level * 10 : nil
            default:
                return nil
            }
        }

        /// For a 0x4010 event: the low byte being zero means the device is
        /// asleep (the app shows its "Device Sleep!" label).
        var isAsleep: Bool? {
            guard code == Code.battery.rawValue else { return nil }
            return (value & 0xFF) == 0
        }

        /// For a 0x5010 event: which report ID the device is acknowledging.
        var acknowledgedReportID: UInt8? {
            guard code == Code.writeAck.rawValue else { return nil }
            return UInt8(truncatingIfNeeded: value >> 8)
        }

        var description: String {
            switch known {
            case .battery:
                let percent = batteryPercent.map { "\($0)%" } ?? "invalid(\(value >> 8))"
                return "battery \(percent), \((isAsleep ?? false) ? "asleep" : "awake")"
            case .writeAck:
                let id = acknowledgedReportID ?? 0
                return String(format: "write acknowledged for report 0x%02X", id)
            case .dpiStage:
                return "DPI stage changed to \(value)"
            case .pollingRate:
                return "polling rate index changed to \(value)"
            case .lightMode:
                return "light mode changed to \(value)"
            case .profile:
                return "profile changed to \(value)"
            case .batteryLevel:
                // Same destination field and same 1..10 validation as the
                // 0x4010 battery handler, so this is a battery level
                // without the awake flag.
                let level = Int(value)
                return (1...10).contains(level)
                    ? "battery level \(level) (\(level * 10)%)"
                    : "event 0x6000, value \(value) (out of the 1-10 battery range)"
            case nil:
                return String(format: "unknown event 0x%04X, value 0x%04X", code, value)
            }
        }
    }

    /// Parse a raw input report. Returns nil if it is not a status report.
    static func parse(_ bytes: [UInt8]) -> Event? {
        guard bytes.count >= length, bytes[0] == reportID else { return nil }
        return Event(
            code: UInt16(bytes[2]) << 8 | UInt16(bytes[1]),
            value: UInt16(bytes[4]) << 8 | UInt16(bytes[3])
        )
    }
}

/// Macros — report `0x09`.
///
/// This is the only report that uses the fragmented path: the logical buffer is
/// 131 bytes (`0x83`), too large for one 64-byte report, so the sender
/// splits bytes 3…130 into three chunks of 60/60/8.
///
/// Layout of the 131-byte logical buffer (base confirmed as `ebp-0x130` from
/// the checksum loop):
///
///     byte 0        0x09
///     byte 1        0x83  (131)
///     byte 2        macro index
///     byte 3        loop mode
///     byte 4-6      unidentified — one source value repeated three times
///     byte 7        repeat count, or 1 if zero
///     byte 8-27     zero — never written by the builder
///     byte 28       event count
///     byte 29-128   event pairs, 2 bytes each → 50 events maximum
///     byte 129-130  checksum, high then low, over bytes 3…128
enum MacroReport {
    static let reportID: UInt8 = 0x09
    static let logicalLength = 131
    static let countOffset = 28
    static let eventsOffset = 29
    static let maxEvents = (129 - eventsOffset) / 2  // 50

    /// One macro step. The app's own record is 4 bytes — key code, a down/up
    /// flag, and a 16-bit delay.
    struct Event {
        var keyCode: UInt8
        var isDown: Bool
        var delayMs: Int
    }

    /// Encode one event to its two wire bytes.
    ///
    /// The delay is divided by 10.0, rounded by
    /// adding 0.5 and truncating, then OR-ed with a flag — `0x01` for key-down,
    /// `0x81` for key-up. So bit 7 marks a key release and bits 0…6 carry the
    /// delay in units of 10 ms. Note the app forces bit 0 set in both cases.
    ///
    /// Delays above 1270 ms take a second path that splits them
    /// into 200-unit blocks; `split(delayMs:)` mirrors that.
    static func encode(_ event: Event) -> [UInt8] {
        let clamped = max(1, event.delayMs)
        let units = Int((Double(clamped) / 10.0) + 0.5)
        let flag: UInt8 = event.isDown ? 0x01 : 0x81
        return [UInt8(truncatingIfNeeded: units) | flag, event.keyCode]
    }

    /// The device cannot express a delay longer than 1270 ms in one event, so
    /// the app emits the remainder first and then repeats 200-unit blocks.
    static func split(delayMs: Int) -> [Int] {
        guard delayMs > 1270 else { return [max(1, delayMs)] }
        var parts = [delayMs % 200]
        var remaining = delayMs / 200
        while remaining > 0 && parts.count < 10 {
            parts.append(200)
            remaining -= 1
        }
        return parts.map { max(1, $0) }
    }

    /// Build the 131-byte logical buffer. Fragment it with
    /// `X3Report.fragment(command: index, payload: buffer[3...])`.
    /// How a macro repeats. Byte 3 of the buffer, from `[macro+0x0c]`.
    ///
    /// **Confirmed on hardware**, one mode at a time, by uploading a slow macro
    /// and pressing a button mapped to it. The three values correspond exactly
    /// to the `repeat_1/2/3` radio buttons in the vendor's UI layout and
    /// the `select_macro_4/5/6` strings in the vendor's string table.
    enum LoopMode: UInt8 {
        /// Play `repeatCount` times, then stop. ("The Number Of Time To Play")
        case times = 0
        /// Repeat until any key is pressed. ("Any Key Press To Stop Playing")
        case untilKeyPress = 1
        /// Repeat while the button is held. ("Press And Hold,Release Stop")
        case whileHeld = 2

        static func named(_ text: String) -> LoopMode? {
            switch text.lowercased().replacingOccurrences(of: "-", with: "") {
            case "times", "count": return .times
            case "untilkey", "untilkeypress", "anykey": return .untilKeyPress
            case "hold", "whileheld": return .whileHeld
            default: return nil
            }
        }

        var label: String {
            switch self {
            case .times: return "play a fixed number of times"
            case .untilKeyPress: return "repeat until any key is pressed"
            case .whileHeld: return "repeat while the button is held"
            }
        }
    }

    /// `repeatCount` is byte 7, read by the vendor software from its macro record
    /// with 1 substituted when that field is zero. Confirmed on
    /// hardware: a count of 3 makes one button press emit the macro 3 times.
    ///
    /// `header456` is bytes 4-6, which the vendor software fills with one
    /// value repeated three times. Still unidentified.
    static func build(
        index: UInt8, events: [Event],
        repeatCount: UInt8 = 1, loopMode: LoopMode = .times, header456: UInt8 = 0
    ) -> [UInt8]? {
        guard events.count <= maxEvents else { return nil }

        var buffer = [UInt8](repeating: 0, count: logicalLength)
        buffer[0] = reportID
        buffer[1] = UInt8(logicalLength)
        buffer[2] = index
        buffer[3] = loopMode.rawValue
        buffer[4] = header456
        buffer[5] = header456
        buffer[6] = header456
        buffer[7] = max(1, repeatCount)
        buffer[countOffset] = UInt8(truncatingIfNeeded: events.count)

        var offset = eventsOffset
        for event in events {
            let pair = encode(event)
            buffer[offset] = pair[0]
            buffer[offset + 1] = pair[1]
            offset += 2
        }

        let sum = X3Report.checksum(payload: buffer[3...128])
        buffer[129] = sum.high
        buffer[130] = sum.low
        return buffer
    }
}

/// USB HID keyboard usage codes.
///
/// Decoding the action table proved these are genuine HID usages
/// rather than a vendor scheme: id 33 emits `11 01 06` and 0x06 is the HID
/// usage for "c", giving Ctrl+C; id 43 emits `11 04 2B`, Alt + Tab.
enum HIDUsage {
    static let names: [String: UInt8] = {
        var map: [String: UInt8] = [
            "enter": 0x28, "esc": 0x29, "escape": 0x29, "backspace": 0x2A,
            "tab": 0x2B, "space": 0x2C, "minus": 0x2D, "equals": 0x2E,
            "capslock": 0x39, "f1": 0x3A, "f2": 0x3B, "f3": 0x3C, "f4": 0x3D,
            "f5": 0x3E, "f6": 0x3F, "f7": 0x40, "f8": 0x41, "f9": 0x42,
            "f10": 0x43, "f11": 0x44, "f12": 0x45, "delete": 0x4C,
            "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
            "printscreen": 0x46, "scrolllock": 0x47, "pause": 0x48,
            "insert": 0x49, "home": 0x4A, "pageup": 0x4B,
            "end": 0x4D, "pagedown": 0x4E,
            "leftbracket": 0x2F, "rightbracket": 0x30, "backslash": 0x31,
            "semicolon": 0x33, "quote": 0x34, "grave": 0x35,
            "comma": 0x36, "period": 0x37, "slash": 0x38,
            "numlock": 0x53, "numslash": 0x54, "numstar": 0x55,
            "numminus": 0x56, "numplus": 0x57, "numenter": 0x58,
            "num1": 0x59, "num2": 0x5A, "num3": 0x5B, "num4": 0x5C,
            "num5": 0x5D, "num6": 0x5E, "num7": 0x5F, "num8": 0x60,
            "num9": 0x61, "num0": 0x62, "numperiod": 0x63,
            "app": 0x65,
            "rctrl": 0xE4, "rshift": 0xE5, "ralt": 0xE6, "rwin": 0xE7,
        ]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[String(letter)] = UInt8(0x04 + index)
        }
        for (index, digit) in "123456789".enumerated() {
            map[String(digit)] = UInt8(0x1E + index)
        }
        map["0"] = 0x27
        return map
    }()

    /// Mouse buttons usable inside a **macro**.
    ///
    /// The macro list renderer discriminates: it computes
    /// `keycode - 0xF1` and treats a result of 4 or less as a mouse event
    /// (drawing `mouse.png` instead of `keyboard_key_action.png`). So codes
    /// 0xF1…0xF5 are the five mouse buttons, matching the `mouse_key_1…5` and
    /// `L_Button`/`R_Button`/`M_Button`/`Forward_Button`/`Backward_Button`
    /// strings in the vendor's string table.
    static let mouseButtons: [String: UInt8] = [
        "mouse_left": 0xF1, "mouse_right": 0xF2, "mouse_middle": 0xF3,
        "mouse_forward": 0xF4, "mouse_backward": 0xF5,
    ]

    static func code(for name: String) -> UInt8? {
        let key = name.lowercased()
        return names[key] ?? mouseButtons[key]
    }
}

/// Button mapping — report `0x08`.
///
///     byte 0      0x08
///     byte 1      0x3B (59)
///     byte 2      0x01
///     byte 3-56   18 entries, 3 bytes each: [action][modifier][key]
///     byte 57-58  checksum over bytes 3…56, high then low
///
/// The loop walks 18 buttons with a stride of 3,
/// starting the write pointer at `buffer[3]` and stopping when its counter
/// reaches 58. The source records are 1272 bytes apart in the settings blob.
///
/// Each UI action id is translated through a 63-entry table
/// (20-byte records: id, then the three output bytes). Decoding that table is
/// what proves the key codes are **standard USB HID usages** and the modifier
/// is a standard HID modifier bitmask — for example id 33 yields `11 01 06`
/// (Ctrl + `0x06` = "c" = Ctrl+C) and id 43 yields `11 04 2B` (Alt + Tab).
///
/// Two action ids are special-cased in the builder rather than taken from the
/// table: id 16 (0x00414 6d7) pulls a user-defined modifier and key from the
/// button's own record, and id 17 emits a macro reference whose
/// slot is the button index plus one.
enum ButtonReport {
    static let reportID: UInt8 = 0x08
    static let totalLength = 59
    static let entriesOffset = 3
    static let buttonCount = 18

    /// HID modifier bits, matching the Ctrl/Shift/Alt/Win checkboxes in
    /// the vendor's shortcut table.
    static let modifiers: [String: UInt8] = [
        "ctrl": 0x01, "shift": 0x02, "alt": 0x04, "win": 0x08, "gui": 0x08,
    ]

    /// A single button's three wire bytes.
    struct Action {
        var code: UInt8
        var modifier: UInt8 = 0
        var key: UInt8 = 0
        var describe: String
    }

    /// Every action the device supports, as its **full three wire bytes**.
    ///
    /// Names come from the vendor software, not from guesswork: the app resolves each
    /// action id to a display string through a 90-case switch, and the
    /// id → wire-byte mapping is a 63-entry table.
    ///
    /// Storing all three bytes matters — `easy_aim` and `led_loop` carry a
    /// third byte of `0x03`, and the predefined shortcuts carry a modifier and
    /// a HID usage. An earlier version kept only the first byte and would have
    /// sent both of those incorrectly.
    static let actionTable: [String: (UInt8, UInt8, UInt8)] = [
        "none": (0x00, 0, 0),
        "button_off": (0x01, 0, 0), "off": (0x01, 0, 0), "disabled": (0x01, 0, 0),
        "left": (0x02, 0, 0), "left_click": (0x02, 0, 0),
        "right": (0x03, 0, 0), "right_click": (0x03, 0, 0),
        "middle": (0x04, 0, 0), "wheel_click": (0x04, 0, 0),
        "backward": (0x05, 0, 0), "back": (0x05, 0, 0),
        "forward": (0x06, 0, 0),
        "double_click": (0x07, 0, 0),
        "fire_button": (0x08, 0, 0), "fire": (0x08, 0, 0),
        "scroll_up": (0x09, 0, 0), "scroll_down": (0x0A, 0, 0),
        "tilt_left": (0x0B, 0, 0), "tilt_right": (0x0C, 0, 0),
        "dpi_cycle": (0x0D, 0, 0), "dpi_up": (0x0E, 0, 0), "dpi_down": (0x0F, 0, 0),
        "easy_aim": (0x10, 0x00, 0x03),
        "led_loop": (0x29, 0x00, 0x03),
        "media_player": (0x15, 0, 0),
        "previous_track": (0x16, 0, 0), "next_track": (0x17, 0, 0),
        "play_pause": (0x18, 0, 0), "media_stop": (0x19, 0, 0),
        "mute": (0x1A, 0, 0), "volume_up": (0x1B, 0, 0), "volume_down": (0x1C, 0, 0),
        "calculator": (0x1D, 0, 0), "email": (0x1E, 0, 0),
        "browser_forward": (0x20, 0, 0), "browser_backward": (0x21, 0, 0),
        "browser_stop": (0x22, 0, 0), "my_computer": (0x23, 0, 0),
        "browser_refresh": (0x24, 0, 0), "browser_home": (0x25, 0, 0),
        "browser_search": (0x26, 0, 0),
        "browser_favorites": (0x11, 0x03, 0x12),
        "profile_cycle": (0x34, 0, 0), "profile_up": (0x35, 0, 0),
        "profile_down": (0x36, 0, 0),
        // The mode button's factory action: cycles the Bluetooth identity
        // (X3-5.2 / X3-5.4). It has no entry in the app's name switch, and
        // probing it over the 2.4GHz link showed nothing because BT-profile
        // switching only applies over Bluetooth.
        "mode_switch": (0x3C, 0, 0),
        // Predefined shortcuts, ids 32-50 -- all keyboard combos.
        "cut": (0x11, 0x01, 0x1B), "copy": (0x11, 0x01, 0x06),
        "paste": (0x11, 0x01, 0x19), "open": (0x11, 0x01, 0x12),
        "save": (0x11, 0x01, 0x16), "find": (0x11, 0x01, 0x09),
        "redo": (0x11, 0x01, 0x1C), "undo": (0x11, 0x01, 0x1D),
        "select_all": (0x11, 0x01, 0x04), "print": (0x11, 0x01, 0x13),
        "close_window": (0x11, 0x04, 0x3D), "swap_windows": (0x11, 0x04, 0x2B),
        "show_desktop": (0x11, 0x08, 0x07), "run_command": (0x11, 0x08, 0x15),
        "lock_pc": (0x11, 0x08, 0x0F), "screen_capture": (0x11, 0x0A, 0x16),
        // Ids 47-49 carry real keyboard combos but the vendor UI never shows
        // them -- their switch cases all fall through to an empty label. They
        // work like any other combo, so they are exposed here under sensible
        // names rather than left inaccessible.
        "new": (0x11, 0x01, 0x11),        // Ctrl+N
        "zoom_in": (0x11, 0x01, 0x2E),    // Ctrl+=
        "zoom_out": (0x11, 0x01, 0x2D),   // Ctrl+-
    ]

    /// The factory default mapping, recovered from the table
    /// (18 dwords of *action ids*, translated here to wire bytes).
    ///
    /// Entry 5 is action id 52 → wire `0x3C`, the mode-switch button. That code
    /// appears nowhere in the app's name switch, which is why it looked like a
    /// dead entry: probing it on the 2.4GHz link produced no visible effect
    /// because BT-profile switching only applies over Bluetooth.
    static let factoryDefault: [UInt8] = [
        0x02,  // 1  left_click
        0x03,  // 2  right_click
        0x04,  // 3  wheel_click
        0x0D,  // 4  dpi_cycle
        0x3C,  // 5  mode switch (BT profile)
        0x0F,  // 6  dpi_down
        0x06,  // 7  forward
        0x05,  // 8  backward
        0x3C,  // 9  mode switch
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,  // 10-16 button_off
        0x0A,  // 17 scroll_down
        0x09,  // 18 scroll_up
    ]

    /// The wire code for a primary click, used by the safety check.
    static let leftClickCode: UInt8 = 0x02

    /// Parse one action spec: `left`, `key:ctrl+c`, `macro:2`, `raw:11.01.06`.
    static func parseAction(_ spec: String) -> Action? {
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return Action(code: 0, describe: "none") }

        if let entry = actionTable[text] {
            return Action(
                code: entry.0, modifier: entry.1, key: entry.2, describe: text)
        }

        if text.hasPrefix("raw:") {
            let parts = text.dropFirst(4).split(separator: ".")
                .compactMap { UInt8($0, radix: 16) }
            guard parts.count == 3 else { return nil }
            return Action(
                code: parts[0], modifier: parts[1], key: parts[2],
                describe: String(format: "raw %02X %02X %02X", parts[0], parts[1], parts[2]))
        }

        if text.hasPrefix("macro:") {
            guard let slot = UInt8(text.dropFirst(6)) else { return nil }
            return Action(code: 0x12, modifier: 0, key: slot, describe: "macro \(slot)")
        }

        if text.hasPrefix("key:") {
            var modifier: UInt8 = 0
            var usage: UInt8?
            for token in text.dropFirst(4).split(separator: "+") {
                let name = String(token)
                if let bit = modifiers[name] {
                    modifier |= bit
                } else if let code = HIDUsage.code(for: name) {
                    usage = code
                } else {
                    return nil
                }
            }
            guard let key = usage else { return nil }
            return Action(
                code: 0x11, modifier: modifier, key: key,
                describe: "key \(text.dropFirst(4))")
        }
        return nil
    }

    /// Build the 59-byte report. Any button not supplied is left as zeros.
    static func build(_ actions: [Action?]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: totalLength)
        report[0] = reportID
        report[1] = UInt8(totalLength)
        report[2] = 0x01

        for index in 0..<buttonCount {
            guard index < actions.count, let action = actions[index] else { continue }
            let offset = entriesOffset + index * 3
            report[offset] = action.code
            report[offset + 1] = action.modifier
            report[offset + 2] = action.key
        }

        let sum = X3Report.checksum(payload: report[3...56])
        report[57] = sum.high
        report[58] = sum.low
        return report
    }
}
