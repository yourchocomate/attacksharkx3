import CoreBluetooth
import Foundation

// asctl — an open-source macOS controller for the Attack Shark X3 mouse.
//
// The vendor ships Windows-only software, so the device's configuration
// protocol is implemented here from scratch: HID feature reports over the
// 2.4GHz receiver or a USB cable, and GATT over Bluetooth.

let usage = """
asctl — Attack Shark X3 control for macOS

USAGE
  asctl <command> [options]

COMMANDS
  gui                      Open the graphical interface
  selftest                 Verify generated payloads against the protocol (no hardware)
  power-test <what>        Measure whether report 0x05's timings do anything.
                             debounce [seconds]  A/B the key debounce floor by
                                                 timing your fastest clicks
                             sleep <minutes>     Watch for the device to sleep
                             wake <minutes>      Detect sleep from how the mouse
                                                 starts reporting after idling
  list                     List Attack Shark HID interfaces (--all for every HID device)
  descriptor               Dump and decode the HID report descriptor
  probe                    Read-only sweep of feature reports (safe; never writes)
  get <reportID> [length]  Read one feature report        e.g. asctl get 0x09 64
  set <hex bytes>          Write one feature report       e.g. asctl set "09 40 00 00"
  status [seconds]         Decode device status events (battery, DPI stage,
                           write acknowledgements). 2.4GHz receiver only.
  watch [seconds]          Listen to input reports; measures the actual report
                           rate, which is how polling-rate changes are verified
  pollrate <hz>            Set polling rate: 125, 250, 500 or 1000
  dpi <v1[,v2,...]>        Set DPI stages (first is active unless --active)
                           Report 0x04 is atomic: DPI, the four sensor toggles
                           and all eight stage colours are written together, and
                           none of them can be read back first.
                             --lod 1|2          lift-off distance, mm
                             --ripple on|off    ripple control
                             --anglesnap on|off angle snap
                             --motionsync on|off motion sync
                             --colour r,g,b     force every stage colour
                             --colours r,g,b;... one colour per stage
  power [opts]             Power management and key debounce (report 0x05).
                             --sleep 1-60       sleep time, minutes
                             --deepsleep 1-60   deep sleep time, minutes
                             --debounce 2-25    key response time, in 2ms units
                                                (25 = 50ms of real debounce)
                           Report 0x05 is atomic: it also carries the lighting
                           mode/colour/brightness/speed, so those are rewritten
                           too. Pass the light options to control them.
  light <mode> [opts]      Set lighting. Modes: off, static, breathing, neon,
                           colourbreathing, colourstatic, mixedbreathing,
                           rainbowwave, lightning, staticmixedcolour, marquee,
                           marquee2  (or 0-11)
                             --colour r,g,b     colour, 0-255 each
                             --brightness 1-8   only applies to Static
                             --speed 4-8        animation speed
                             --sleep/--deepsleep/--debounce  as for `power`
                           ⚠️ The X3 has NO user-controllable lighting. The
                           report is accepted and acknowledged; the lighting
                           fields do nothing. See README, "Lighting".
  light-probe [what]       Hardware sweep of the lighting fields, kept for
                           re-testing on other models in the vendor's range.
                           what: modes (default) | encodings
                             --auto <seconds>   don't wait for input
  buttons <a1,a2,...>      Map buttons 1-18 (report 0x08). Actions:
                             left right middle backward forward dpi_cycle
                             dpi_up dpi_down scroll_up scroll_down mute
                             volume_up volume_down play_pause next_track
                             profile_cycle button_off none  (and more)
                             key:ctrl+c      keyboard combo (HID usages)
                             macro:2         run macro slot 2
                             raw:11.01.06    explicit three bytes
                           Use `asctl buttons defaults` to restore the factory
                           mapping (including the mode-switch button).
                           Atomic: all 18 entries are written together and
                           cannot be read back, so unlisted buttons become
                           unassigned. At least one must be `left`.
  macro <index> <events>   Upload a macro (report 0x09, fragmented).
                           Events: <key>:<down|up>:<ms> comma-separated, max 50.
                             asctl macro 1 "a:down:20,a:up:20"
                           Keys may be a letter/digit/name, mouse_left/right/
                           middle/forward/backward, or a raw hex usage.
                             --repeat N    times to play (loop mode `times`)
                             --loop times|until-key|hold
  profile save <name> [opts]   Save the given settings as a named profile.
  profile apply <name>         Replay a profile to the device.
  profile list                 List saved profiles.
                           Profiles are host-side files (~/.config/asctl/
                           profiles) replayed through the normal reports —
                           the device's own profile slots are unused by this
                           product. Accepts the same options as dpi/pollrate/
                           power/buttons.
  fix-bluetooth            Cycle the Mac's Bluetooth off and on. Workaround for
                           the mouse reconnecting with a dead cursor — a
                           firmware fault no config write can clear.
  scroll <mode>            Make the wheel ignore macOS "Natural scrolling".
                           Modes: follow (default), standard, natural.
                           `status` shows the current state. Runs until Ctrl-C
                           and needs Accessibility permission. The trackpad is
                           never affected.
                             asctl scroll debug              dump raw scroll events
                             asctl scroll install standard   run it at login
                             asctl scroll uninstall
  ble scan                 Find the mouse over Bluetooth and dump its GATT table
  ble write <hex>          Write a config buffer to the FEE3 characteristic
  ble battery              Read the battery level over Bluetooth (GATT 2A19)
  ble listen [seconds]     Listen on the FEE4 notify characteristic
  version                  Print the version this build reports
  battery-probe [seconds]  Listen for the battery level the device volunteers
  macos-battery            Find out whether macOS reads 2A19 for its figure
  blediag [seconds]        Dump GATT, five battery reads, and every notify
                           packet while you press buttons. Use this rather
                           than guessing at a battery or event problem.
                           Bluetooth configuration goes over GATT, not HID —
                           the vendor app does the same.
  send <reportID> <command> [payload-hex]
                           Write a report using the Windows software's framing,
                           filling in the length byte for you
                           e.g. asctl send 0x0C 0x01 "FE 01 FE"
  help                     Show this message

OPTIONS
  --all                    (list) show every HID device, not just known IDs
  --ble                    Send over Bluetooth GATT instead of the USB receiver
  --peripheral <name>      Target a specific BLE identity, e.g. X3-5.4
  --dry-run                Print the bytes that would be written, write nothing
  --raw                    (descriptor) also print the raw descriptor bytes
  --vid <hex> --pid <hex>  Target a specific device
  --usage-page <hex>       Disambiguate when a device exposes several collections
  --index <n>              Pick the n-th matching HID interface (default: auto)
  --active <n>             (dpi) which DPI stage is active, 1-based
  --profile <n>            (dpi) write to profile slot 1-5 (byte 2). The vendor
                           app only ever writes 1; slots 2-5 are UNTESTED.

NOTES
  Configuration goes over HID feature reports, report ID 0x09, 64 bytes.
  macOS may require Input Monitoring permission for your terminal.
"""

// MARK: - Argument parsing

struct Options {
    var command = "help"
    var positionals: [String] = []
    var all = false
    var raw = false
    var dryRun = false
    var vendorID: Int?
    var productID: Int?
    var usagePage: Int?
    var index: Int?
    var length: Int?
    var declared: Int?
    var colour: String?
    var colours: String?
    var activeStage: Int?
    var profile: Int?
    var buttonSpec: String?
    var useBLE = false
    var peripheralName: String?
    var repeatCount: Int?
    var loopMode: String?
    var header456: Int?
    var toggles = DpiReport.Toggles()
    var brightness: Int?
    var speed: Int?
    var sleepMinutes: Int?
    var deepSleepMinutes: Int?
    var debounceMs: Int?
    var autoSeconds: Double?
}

func isOn(_ text: String?) -> Bool {
    guard let text = text?.lowercased() else { return false }
    return ["on", "1", "true", "yes", "enabled"].contains(text)
}

func parseHexOrDecimal(_ text: String) -> Int? {
    let lowered = text.lowercased()
    if lowered.hasPrefix("0x") { return Int(lowered.dropFirst(2), radix: 16) }
    return Int(text) ?? Int(lowered, radix: 16)
}

func parseArguments(_ argv: [String]) -> Options {
    var options = Options()
    var rest = argv

    if let first = rest.first, !first.hasPrefix("-") {
        options.command = first
        rest.removeFirst()
    }

    var iterator = 0
    while iterator < rest.count {
        let argument = rest[iterator]
        func nextValue() -> String? {
            iterator += 1
            return iterator < rest.count ? rest[iterator] : nil
        }

        switch argument {
        case "--all": options.all = true
        case "--raw": options.raw = true
        case "--dry-run": options.dryRun = true
        case "--vid": options.vendorID = nextValue().flatMap(parseHexOrDecimal)
        case "--pid": options.productID = nextValue().flatMap(parseHexOrDecimal)
        case "--usage-page": options.usagePage = nextValue().flatMap(parseHexOrDecimal)
        case "--index": options.index = nextValue().flatMap { Int($0) }
        case "--active": options.activeStage = nextValue().flatMap { Int($0) }
        case "--profile": options.profile = nextValue().flatMap { Int($0) }
        case "--buttons": options.buttonSpec = nextValue()
        case "--ble": options.useBLE = true
        case "--peripheral": options.peripheralName = nextValue()
        case "--repeat": options.repeatCount = nextValue().flatMap { Int($0) }
        case "--loop": options.loopMode = nextValue()
        case "--m456": options.header456 = nextValue().flatMap { Int($0) }
        case "--len": options.length = nextValue().flatMap { Int($0) }
        case "--colour", "--color": options.colour = nextValue()
        case "--colours", "--colors": options.colours = nextValue()
        case "--lod": options.toggles.liftOffDistance2mm = (nextValue() ?? "1").hasPrefix("2")
        case "--ripple": options.toggles.rippleControl = isOn(nextValue())
        case "--anglesnap": options.toggles.angleSnap = isOn(nextValue())
        case "--motionsync": options.toggles.motionSync = isOn(nextValue())
        case "--brightness": options.brightness = nextValue().flatMap { Int($0) }
        case "--speed": options.speed = nextValue().flatMap { Int($0) }
        case "--auto": options.autoSeconds = nextValue().flatMap { Double($0) } ?? 3.0
        case "--sleep": options.sleepMinutes = nextValue().flatMap { Int($0) }
        case "--deepsleep": options.deepSleepMinutes = nextValue().flatMap { Int($0) }
        case "--debounce": options.debounceMs = nextValue().flatMap { Int($0) }
        case "--declared": options.declared = nextValue().flatMap(parseHexOrDecimal)
        default: options.positionals.append(argument)
        }
        iterator += 1
    }
    return options
}

// MARK: - Device resolution

func candidateDevices(_ options: Options) -> [HIDDeviceRef] {
    var devices: [HIDDeviceRef]

    if let vendorID = options.vendorID {
        devices = HID.allDevices().filter { $0.vendorID == vendorID }
        if let productID = options.productID {
            devices = devices.filter { $0.productID == productID }
        }
    } else {
        devices = HID.attackSharkDevices()
    }

    if let usagePage = options.usagePage {
        devices = devices.filter { $0.usagePage == usagePage }
    }
    return devices
}

func resolveDevice(_ options: Options) -> HIDDeviceRef? {
    // Applying a polling rate makes the receiver re-enumerate, so straight
    // after a write the device is briefly absent from the HID registry. Wait
    // for it rather than reporting a spurious "no device found".
    let deadline = Date().addingTimeInterval(5)
    var devices = candidateDevices(options)
    while devices.isEmpty && Date() < deadline {
        usleep(250_000)
        devices = candidateDevices(options)
    }

    guard !devices.isEmpty else { return nil }
    if let index = options.index {
        return devices[safe: index]
    }
    return HID.selectConfigInterface(devices)
}

func openDevice(_ options: Options) -> HIDConnection? {
    guard let info = resolveDevice(options) else {
        FileHandle.standardError.write(Data("error: no Attack Shark device found.\n".utf8))
        FileHandle.standardError.write(
            Data("Plug in the mouse (or its 2.4GHz dongle) and run `asctl list --all`.\n".utf8))
        return nil
    }

    // Catch the unconfigurable-transport case up front. Over Bluetooth the X3
    // exposes a 1-byte maximum feature report, so every config write fails with
    // a bare kIOReturnNotFound that explains nothing.
    if !info.canConfigure {
        let message = """
            error: \(info.descriptorText)
            This interface cannot carry configuration reports \
            (max feature report size \(info.maxFeatureReportSize)).

            Over Bluetooth the X3 exposes no HID feature reports — but the same
            commands work over GATT. Re-run with --ble.

            Otherwise connect the 2.4GHz receiver, or plug the USB cable in:
            both give an interface with a feature report size of 262.

            """
        FileHandle.standardError.write(Data(message.utf8))
        return nil
    }

    let connection = HIDConnection(info)
    do {
        try connection.open()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return nil
    }
    print("device: \(info.descriptorText)")
    return connection
}

// MARK: - Sending

/// Send the preamble followed by one or more reports, over whichever transport
/// the user asked for.
///
/// The preamble is mandatory on both paths — a config report sent without it is
/// acknowledged and then ignored. Over Bluetooth every buffer must also go over
/// a single connection, and notifications must be subscribed first or the
/// device ignores writes to FEE3 entirely.
func sendReports(_ reports: [[UInt8]], _ options: Options) -> Bool {
    guard !options.useBLE else { return sendReportsOverBLE(reports) }

    guard let connection = openDevice(options) else { return false }
    do {
        try connection.setFeatureRetrying(PollingRate.preamble)
        usleep(200_000)
        for report in reports {
            try connection.setFeatureRetrying(report)
            usleep(200_000)
        }
        return true
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return false
    }
}

func sendReportsOverBLE(_ reports: [[UInt8]]) -> Bool {
    let ble = BLEConnection()
    print("connecting over Bluetooth…")
    guard ble.discover() else {
        print("error: \(ble.lastError ?? "no Bluetooth peripherals found")")
        return false
    }
    let candidates = ble.foundPeripherals.map { $0.0 }
    let target = candidates.first { ($0.name ?? "").lowercased().contains("mouse") }
        ?? candidates.first!
    guard ble.connect(target) else {
        print("error: \(ble.lastError ?? "no FEE3 characteristic")")
        return false
    }
    // Without this the device silently discards FEE3 writes.
    guard ble.subscribe() else {
        print("error: could not subscribe to FEE4 notifications")
        return false
    }

    for report in [PollingRate.preamble] + reports {
        guard ble.write(report) else {
            print("error: \(ble.lastError ?? "GATT write failed")")
            return false
        }
    }
    ble.listen(seconds: 2)
    if ble.notifications.isEmpty {
        print("warning: no FEE4 acknowledgements — the device may have ignored this")
    } else {
        for packet in ble.notifications {
            print("  ack: \(Hex.encode(packet))")
        }
    }
    return true
}

// MARK: - Commands

func commandList(_ options: Options) {
    let devices = options.all ? HID.allDevices() : HID.attackSharkDevices()

    if devices.isEmpty {
        print("No matching HID devices.")
        if !options.all {
            print("Known IDs:")
            for identity in KnownDevices.all {
                print(
                    String(
                        format: "  %04X:%04X  %@", identity.vendorID, identity.productID,
                        identity.label))
            }
            print("\nNothing matched — try `asctl list --all` to see every attached HID device.")
        }
        return
    }

    for (index, device) in devices.enumerated() {
        print("[\(index)] \(device.descriptorText)")
        if let label = KnownDevices.label(vendorID: device.vendorID, productID: device.productID) {
            print("     ↳ \(label)")
            if KnownDevices.isAmbiguous(vendorID: device.vendorID, productID: device.productID) {
                print("     ↳ note: this VID/PID is Microsoft's generic mouse ID; the X3 clones it,")
                print("            so a real Microsoft mouse would also show up here.")
            }
            // Only flag this when *no* interface of this physical device can
            // be configured. The receiver exposes several interfaces and only
            // one of them carries feature reports, so warning per-interface
            // would wrongly imply the whole device is unusable.
            let siblings = devices.filter {
                $0.vendorID == device.vendorID && $0.productID == device.productID
            }
            if !siblings.contains(where: { $0.canConfigure }) {
                print("     ↳ cannot be configured: max feature report size is "
                    + "\(device.maxFeatureReportSize) — configuration needs the 2.4GHz receiver")
            }
        }
    }
}

func commandDescriptor(_ options: Options) {
    guard let info = resolveDevice(options) else {
        print("No matching device. Try `asctl list --all`.")
        return
    }
    print("device: \(info.descriptorText)")

    guard let data = info.reportDescriptor, !data.isEmpty else {
        print("Device exposed no report descriptor.")
        return
    }
    print("descriptor: \(data.count) bytes\n")

    let parsed = ReportDescriptor.parse(data)

    if !parsed.topLevelUsages.isEmpty {
        print("Top-level collections:")
        for entry in parsed.topLevelUsages {
            print(
                String(
                    format: "  usage page 0x%04X (%@), usage 0x%02X", entry.page,
                    ReportDescriptor.usagePageName(entry.page), entry.usage))
        }
        print("")
    }

    print("Reports:")
    if parsed.reports.isEmpty {
        print("  (none)")
    }
    for report in parsed.reports {
        let size = report.byteCount(numbered: parsed.usesReportIDs)
        let marker = (report.kind == .feature && report.reportID == X3Report.configReportID)
            ? "   ← config channel" : ""
        print(
            String(
                format: "  %-8@ id 0x%02X  %2d bytes%@", report.kind.rawValue as NSString,
                report.reportID, size, marker as NSString))
    }

    if options.raw {
        print("\nRaw descriptor:")
        print(Hex.dump([UInt8](data)))
        print("\nDecoded items:")
        for item in parsed.items { print("  \(item)") }
    }
}

func commandProbe(_ options: Options) {
    guard let connection = openDevice(options) else { return }

    // Read-only. We never write during a probe, so this cannot disturb the
    // device's stored configuration.
    let descriptorReports =
        connection.info.reportDescriptor
        .map { ReportDescriptor.parse($0) }
        .map { parsed in
            parsed.reports
                .filter { $0.kind == .feature }
                .map { (id: $0.reportID, size: $0.byteCount(numbered: parsed.usesReportIDs)) }
        } ?? []

    let targets: [(id: UInt8, size: Int)] =
        descriptorReports.isEmpty
        ? (1...0x0F).map { (id: UInt8($0), size: max(connection.info.maxFeatureReportSize, X3Report.configReportLength)) }
        : descriptorReports

    print("probing \(targets.count) feature report(s), read-only\n")

    var found = 0
    for target in targets {
        do {
            let data = try connection.getFeature(reportID: target.id, length: target.size)
            found += 1
            print(String(format: "report 0x%02X  (%d bytes)", target.id, data.count))
            print(Hex.dump(data))
            print("")
        } catch {
            print(String(format: "report 0x%02X  — %@", target.id, "\(error)"))
        }
    }

    if found == 0 {
        print("\nNo feature reports could be read.")
        print("If every attempt says \"not permitted\", grant Input Monitoring to your terminal")
        print("in System Settings ▸ Privacy & Security ▸ Input Monitoring, then retry.")
    }
}

func commandGet(_ options: Options) {
    guard let idText = options.positionals[safe: 0],
        let reportID = parseHexOrDecimal(idText)
    else {
        print("usage: asctl get <reportID> [length]")
        return
    }
    let length =
        options.positionals[safe: 1].flatMap(parseHexOrDecimal) ?? X3Report.configReportLength

    guard let connection = openDevice(options) else { return }
    do {
        let data = try connection.getFeature(reportID: UInt8(reportID), length: length)
        print(String(format: "report 0x%02X — %d bytes", reportID, data.count))
        print(Hex.dump(data))
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func commandSet(_ options: Options) {
    guard !options.positionals.isEmpty,
        var bytes = Hex.decode(options.positionals.joined(separator: " "))
    else {
        print("usage: asctl set \"09 40 00 00 ...\"")
        return
    }

    // The device expects a full 64-byte report; pad short input rather than
    // letting the write fail with a confusing size error.
    if bytes.first == X3Report.configReportID && bytes.count < X3Report.configReportLength {
        print("note: padding \(bytes.count) bytes to the \(X3Report.configReportLength)-byte report size")
        bytes += [UInt8](repeating: 0, count: X3Report.configReportLength - bytes.count)
    }

    guard let connection = openDevice(options) else { return }
    print("writing \(bytes.count) bytes:")
    print(Hex.dump(bytes))
    do {
        // Retry the transient first-write-after-idle stall here too. A silently
        // stalled report -- especially a preamble -- makes everything after it
        // look like a protocol failure when it is really a dropped transfer.
        try connection.setFeatureRetrying(bytes)
        print("ok")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func commandSend(_ options: Options) {
    guard let reportText = options.positionals[safe: 0],
        let reportID = parseHexOrDecimal(reportText),
        let commandText = options.positionals[safe: 1],
        let command = parseHexOrDecimal(commandText)
    else {
        print("usage: asctl send <reportID> <command> [payload-hex]")
        print("       asctl send 0x0C 0x01 \"FE 01 FE\"")
        return
    }
    let payload = options.positionals[safe: 2].flatMap(Hex.decode) ?? []

    // The length byte is filled in for us, matching what the Windows software
    // writes into byte 1 of every logical buffer.
    let report = X3Report.command(
        reportID: UInt8(truncatingIfNeeded: reportID),
        command: UInt8(truncatingIfNeeded: command),
        payload: payload
    )

    guard let connection = openDevice(options) else { return }
    print("writing framed report (\(report.count) bytes, length byte = 0x\(String(format: "%02X", report[1]))):")
    print(Hex.dump(report))
    do {
        try connection.setFeature(report)
        print("ok")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func commandPollRate(_ options: Options) {
    guard let text = options.positionals[safe: 0], let hz = Int(text),
        let report = PollingRate.report(hz: hz)
    else {
        print("usage: asctl pollrate <\(PollingRate.supported.map(String.init).joined(separator: "|"))> [--dry-run]")
        return
    }

    print("polling rate \(hz) Hz → divider \(report[3]) (byte 4 is its one's complement)")
    print(Hex.dump(report))

    if options.dryRun {
        print("\ndry run — nothing was written")
        return
    }

    guard let connection = openDevice(options) else { return }
    do {
        // The preamble is not optional. Sent on its own, the rate report is
        // acknowledged at the USB level and then silently ignored; sent
        // straight after this preamble, the same bytes take effect. The
        // vendor software sleeps between reports, so we do too.
        try connection.setFeatureRetrying(PollingRate.preamble)
        usleep(200_000)
        try connection.setFeatureRetrying(report)
        usleep(200_000)
        print("ok — preamble + \(report.count)-byte rate report written")
        print("verify with: asctl watch 5   (keep the mouse moving)")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func commandDpi(_ options: Options) {
    guard let spec = options.positionals[safe: 0] else {
        print("usage: asctl dpi <v1[,v2,...]> [--active N] [--dry-run]")
        print("       asctl dpi 800")
        print("       asctl dpi 400,800,1600,3200 --active 2")
        return
    }
    let stages = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard !stages.isEmpty, stages.count <= DpiReport.maxStages,
        stages.allSatisfy({ $0 >= 50 && $0 <= 32000 })
    else {
        print("error: give 1–\(DpiReport.maxStages) DPI values between 50 and 32000")
        return
    }
    let misaligned = stages.filter { $0 % DpiReport.dpiStep != 0 }
    if !misaligned.isEmpty {
        print("note: DPI is stored in steps of \(DpiReport.dpiStep); "
            + "\(misaligned.map(String.init).joined(separator: ", ")) will be rounded down")
    }
    let active = max(0, min((options.activeStage ?? 1) - 1, stages.count - 1))

    // A forced colour makes report 0x04 visually verifiable: if the LED
    // changes, the report is being applied and only the DPI encoding is wrong.
    var forced: [(r: UInt8, g: UInt8, b: UInt8)] = []
    if let spec = options.colour {
        let parts = spec.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3 {
            forced = Array(repeating: (r: parts[0], g: parts[1], b: parts[2]), count: DpiReport.maxStages)
            print("forcing every stage colour to rgb(\(parts[0]), \(parts[1]), \(parts[2]))")
        }
    }
    // Per-stage colours: "255,0,0;0,255,0;..." -- one triplet per DPI stage.
    if let spec = options.colours {
        for group in spec.split(separator: ";") {
            let parts = group.split(separator: ",")
                .compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 else {
                print("error: --colours wants semicolon-separated r,g,b triplets")
                return
            }
            forced.append((r: parts[0], g: parts[1], b: parts[2]))
        }
    }

    let report = DpiReport.build(
        stages: stages, activeStage: active, colours: forced,
        toggles: options.toggles.bytes,
        profile: UInt8(clamping: options.profile ?? 1),
        length: options.length ?? DpiReport.totalLength,
        declaredLength: options.declared)
    print("toggles: \(options.toggles.summary)")
    print("DPI stages: \(stages.map(String.init).joined(separator: ", "))")
    print("active stage: \(active + 1) (\(stages[active]) DPI)")
    print("wire values: "
        + stages.map { "\($0)→\(DpiReport.wireValue(forDpi: $0))" }.joined(separator: ", ")
        + "   (wire = dpi/50 - 1)")
    print(Hex.dump(report))

    if options.dryRun {
        print("\ndry run — nothing was written")
        return
    }

    print("\nnote: this report also carries the four sensor toggles and the")
    print("per-stage LED colours; they are being replaced with defaults because")
    print("the device provides no way to read the current values first.")

    guard let connection = openDevice(options) else { return }
    do {
        try connection.setFeatureRetrying(PollingRate.preamble)
        usleep(200_000)
        try connection.setFeatureRetrying(report)
        usleep(200_000)
        print("ok — preamble + \(report.count)-byte DPI report written")
        print("verify with: asctl watch 5   (swipe a fixed distance)")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func commandLight(_ options: Options) {
    guard let name = options.positionals[safe: 0],
        let mode = LightReport.Mode.named(name)
    else {
        print("usage: asctl light <mode> [--colour r,g,b] [--brightness 1-8] [--speed 4-8]")
        print("modes:")
        for mode in LightReport.Mode.allCases {
            let note: String
            if !mode.availableOn24GHz {
                note = "  — not offered on the X3 (another model's mode)"
            } else if !mode.availableOnBluetooth {
                note = "  — 2.4 GHz only"
            } else {
                note = ""
            }
            let label = mode.label.padding(toLength: 20, withPad: " ", startingAt: 0)
            print(String(format: "  %2d  ", mode.rawValue) + label + note)
        }
        return
    }

    var red: UInt8 = 255
    var green: UInt8 = 0
    var blue: UInt8 = 0
    if let spec = options.colour {
        let parts = spec.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3 { (red, green, blue) = (parts[0], parts[1], parts[2]) }
    }
    let brightness = UInt8(clamping: options.brightness ?? 8)
    let speed = UInt8(clamping: options.speed ?? 4)

    let report = LightReport.build(
        mode: mode, red: red, green: green, blue: blue,
        brightness: brightness, speed: speed,
        sleepMinutes: UInt8(clamping: options.sleepMinutes ?? 0),
        deepSleepMinutes: UInt8(clamping: options.deepSleepMinutes ?? 0),
        keyDebounceMs: UInt8(clamping: options.debounceMs ?? 0))

    print("mode: \(mode.rawValue) — \(mode.label)")
    print("colour: rgb(\(red), \(green), \(blue))   speed: \(speed)")
    print(mode.usesBrightness
        ? "brightness: \(brightness) (this mode uses it)"
        : "brightness: not used by this mode — wire byte 5 is fixed at 8")
    print(Hex.dump(report))

    if options.dryRun {
        print("\ndry run — nothing was written")
        return
    }

    print("""

        note: the X3 has no user-controllable lighting. This report is accepted \
        and acknowledged by the device, and the lighting fields in it do nothing \
        — the vendor's own light settings UI is hidden and unreachable on this \
        model. The light beside the wheel is a battery \
        indicator: off on battery, magenta charging, green at full.

        The command is kept because report 0x05 also carries the sleep timers \
        and key debounce, which do work — see `asctl power`.

        """)

    guard sendReports([report], options) else { exit(1) }
    print("ok — preamble + \(report.count)-byte lighting report written")
}

/// `asctl ble diag` — dump what the Bluetooth link actually reports.
///
/// Written because two bugs were guessed at repeatedly instead of measured:
/// a battery level that would not settle, and a status listener that seemed to
/// miss DPI-button events. Both are questions about bytes arriving from the
/// device, and neither is answerable by reading the host code.
///
/// Prints the GATT table, five battery reads on one connection with the raw
/// characteristic bytes, then everything that arrives on the notify
/// characteristic while you use the mouse.
func commandBLEDiag(_ options: Options) {
    let seconds = options.positionals[safe: 1].flatMap(Double.init) ?? 25.0
    let ble = BLEConnection()

    print("scanning…")
    guard ble.discover() else {
        print("error: \(ble.lastError ?? "no peripherals found")")
        return
    }
    for (peripheral, _) in ble.foundPeripherals {
        print("  seen: \(peripheral.name ?? "(unnamed)")  \(peripheral.identifier)")
    }
    guard let target = ble.foundPeripherals.map({ $0.0 }).first(where: GUITransport.isX3) else {
        print("error: none of those is the mouse")
        return
    }
    print("\nconnecting to \(target.name ?? "?")…")
    guard ble.connect(target) else {
        print("error: \(ble.lastError ?? "connect failed")")
        return
    }
    print("GATT table:")
    for line in ble.describeServices() { print("  \(line)") }

    print("\nbattery — five reads on this one connection, 3s apart")
    for attempt in 1...5 {
        let level = ble.readBattery()
        let raw = ble.batteryRaw
        print(String(
            format: "  %d/5  level=%@  raw=%@",
            attempt,
            level.map(String.init) ?? "nil",
            raw.isEmpty ? "(none)" : Hex.encode(raw)))
        if attempt < 5 { ble.pump(seconds: 3) }
    }

    guard ble.subscribe() else {
        print("\nerror: could not subscribe to the notify characteristic")
        return
    }
    print("\nlistening \(Int(seconds))s on FEE4.")
    print("PRESS THE DPI BUTTON a few times, and the mode button too.\n")

    let deadline = Date().addingTimeInterval(seconds)
    var total = 0
    while Date() < deadline {
        ble.pump(seconds: 0.5)
        for packet in ble.takeNotifications() {
            total += 1
            let decoded = StatusEvent.parseBLE(packet)?.description ?? "unrecognised"
            print("  \(Hex.encode(packet))   \(decoded)")
        }
    }
    ble.disconnect()
    print("\n\(total) notification(s). If pressing the DPI button produced none,")
    print("the stage-change event does not reach this transport.")

    // Repeated reads on one connection were shown to climb by exactly one each
    // time. That leaves the question of whether the *first* read on a fresh
    // link is trustworthy — which is the only thing that decides whether this
    // characteristic can be used at all.
    print("\nbattery — three separate connections, one read each, 5s apart")
    for attempt in 1...3 {
        let fresh = BLEConnection()
        defer { fresh.disconnect() }
        guard fresh.discover(),
              let peripheral = fresh.foundPeripherals.map({ $0.0 })
                .first(where: GUITransport.isX3),
              fresh.connect(peripheral)
        else {
            print("  \(attempt)/3  could not connect")
            continue
        }
        let level = fresh.readBattery()
        print(String(
            format: "  %d/3  first read on a new link: level=%@  raw=%@",
            attempt,
            level.map(String.init) ?? "nil",
            fresh.batteryRaw.isEmpty ? "(none)" : Hex.encode(fresh.batteryRaw)))
        fresh.disconnect()
        if attempt < 3 { Thread.sleep(forTimeInterval: 5) }
    }
    print("\nIdentical values here mean the first read on a link is the real")
    print("level and only re-reads drift. Climbing values mean the counter is")
    print("global and 2A19 cannot be trusted as a battery level at all.")
}

func commandStatus(_ options: Options) {
    let seconds = options.positionals[safe: 0].flatMap(Double.init) ?? 15.0
    var devices = candidateDevices(options).filter { $0.canConfigure }
    if let index = options.index, let only = candidateDevices(options)[safe: index] {
        devices = [only]
    }
    guard !devices.isEmpty else {
        print("No configurable interface found.")
        print("Status events come from the 2.4GHz receiver's config interface;")
        print("over Bluetooth the X3 exposes no such channel.")
        return
    }

    print("listening \(seconds)s for status events on \(devices[0].descriptorText)")
    print("(move the mouse / press the DPI button to wake it)\n")

    let watcher = InputWatcher(devices: devices, keepSamples: 512)
    let channels = watcher.run(seconds: seconds)

    var seen = 0
    for channel in channels {
        for sample in channel.samples {
            guard let event = StatusEvent.parse(sample) else { continue }
            seen += 1
            print("  \(Hex.encode(sample))   \(event.description)")
        }
    }
    if seen == 0 {
        print("  no status events seen")
        print("\n  The device emits these on change, not periodically. Try pressing")
        print("  the DPI button, or applying a setting, while this is running.")
    }
}

/// Shared builder for report 0x05, which carries lighting *and* power
/// management *and* key debounce together.
func buildLightReport(_ options: Options, mode: LightReport.Mode) -> [UInt8]? {
    var red: UInt8 = 255
    var green: UInt8 = 0
    var blue: UInt8 = 0
    if let spec = options.colour {
        let parts = spec.split(separator: ",")
            .compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3 { (red, green, blue) = (parts[0], parts[1], parts[2]) }
    }

    // Ranges from the vendor's UI layout.
    if let sleep = options.sleepMinutes, !(1...60).contains(sleep) {
        print("error: --sleep must be 1-60 minutes"); return nil
    }
    if let deep = options.deepSleepMinutes, !(1...60).contains(deep) {
        print("error: --deepsleep must be 1-60 minutes"); return nil
    }
    if let debounce = options.debounceMs, !(2...25).contains(debounce) {
        print("error: --debounce must be 2-25 ms"); return nil
    }

    return LightReport.build(
        mode: mode, red: red, green: green, blue: blue,
        brightness: UInt8(clamping: options.brightness ?? 8),
        speed: UInt8(clamping: options.speed ?? 4),
        sleepMinutes: UInt8(clamping: options.sleepMinutes ?? 0),
        deepSleepMinutes: UInt8(clamping: options.deepSleepMinutes ?? 0),
        keyDebounceMs: UInt8(clamping: options.debounceMs ?? 0))
}

func commandPower(_ options: Options) {
    let mode = options.positionals[safe: 0].flatMap(LightReport.Mode.named) ?? .staticColour
    guard let report = buildLightReport(options, mode: mode) else { return }

    print("sleep time:      \(options.sleepMinutes.map { "\($0) min" } ?? "0 (unset)")")
    print("deep sleep time: \(options.deepSleepMinutes.map { "\($0) min" } ?? "0 (unset)")")
    print("key debounce:    \(options.debounceMs.map { "\($0) ms" } ?? "0 (unset)")")
    print("lighting carried in the same report: mode \(mode.rawValue) — \(mode.label)")
    print(Hex.dump(report))

    if options.dryRun {
        print("\ndry run — nothing was written")
        return
    }

    print("\nnote: report 0x05 is atomic — the lighting mode, colour, brightness")
    print("and speed are written alongside these values and cannot be read first.")

    guard let connection = openDevice(options) else { return }
    do {
        try connection.setFeatureRetrying(PollingRate.preamble)
        usleep(200_000)
        try connection.setFeatureRetrying(report)
        usleep(200_000)
        print("ok — preamble + \(report.count)-byte report written")
        print("confirm the device accepted it with: asctl status 5")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func parseMacroEvents(_ spec: String) -> [MacroReport.Event]? {
    var events: [MacroReport.Event] = []
    for token in spec.split(separator: ",") {
        let parts = token.split(separator: ":").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 3 else {
            print("error: each event must be <key>:<down|up>:<ms>, got \(token)")
            return nil
        }
        let keyText = parts[0].lowercased()
        // A bare "down"/"up" would be ambiguous with the action field, so the
        // name table is consulted before the hex fallback.
        guard let keyCode = HIDUsage.code(for: keyText)
            ?? parseHexOrDecimal(parts[0]).map({ UInt8(truncatingIfNeeded: $0) })
        else {
            print("error: unknown key \(parts[0])")
            return nil
        }
        guard parts[1].lowercased() == "down" || parts[1].lowercased() == "up" else {
            print("error: action must be down or up, got \(parts[1])")
            return nil
        }
        guard let delay = Int(parts[2]), delay >= 0 else {
            print("error: delay must be milliseconds, got \(parts[2])")
            return nil
        }
        // Long delays are split the way the vendor app splits them.
        let isDown = parts[1].lowercased() == "down"
        for piece in MacroReport.split(delayMs: delay) {
            events.append(
                MacroReport.Event(keyCode: keyCode, isDown: isDown, delayMs: piece))
        }
    }
    return events
}

func commandMacro(_ options: Options) {
    guard let indexText = options.positionals[safe: 0],
        let index = parseHexOrDecimal(indexText),
        let spec = options.positionals[safe: 1]
    else {
        print("usage: asctl macro <index> \"<key>:<down|up>:<ms>,...\"")
        print("       asctl macro 1 \"a:down:20,a:up:20,b:down:20,b:up:20\"")
        return
    }
    guard let events = parseMacroEvents(spec) else { return }
    guard let loopMode = options.loopMode.map({ MacroReport.LoopMode.named($0) }) ?? .times
    else {
        print("error: --loop must be times, until-key or hold")
        return
    }
    guard events.count <= MacroReport.maxEvents else {
        print("error: \(events.count) events exceeds the \(MacroReport.maxEvents) the report can hold")
        return
    }
    guard let buffer = MacroReport.build(
        index: UInt8(truncatingIfNeeded: index), events: events,
        repeatCount: UInt8(clamping: options.repeatCount ?? 1),
        loopMode: loopMode,
        header456: UInt8(clamping: options.header456 ?? 0))
    else {
        print("error: could not build the macro report")
        return
    }

    print("macro \(index): \(events.count) event(s)")
    print("loop: \(loopMode.label)"
        + (loopMode == .times ? " (\(options.repeatCount ?? 1)x)" : ""))
    for event in events {
        let pair = MacroReport.encode(event)
        print(String(format: "  key 0x%02X %-4@ %4dms  ->  %02X %02X",
            event.keyCode, (event.isDown ? "down" : "up") as NSString,
            event.delayMs, pair[0], pair[1]))
    }

    // The wireless path fragments bytes 3...130 into 60/60/8.
    let chunks = X3Report.fragment(
        command: UInt8(truncatingIfNeeded: index),
        payload: Array(buffer[3...]))
    print("\n\(buffer.count)-byte logical buffer -> \(chunks.count) chunks")
    for (number, chunk) in chunks.enumerated() {
        print("  chunk \(number): len byte 0x\(String(format: "%02X", chunk[1]))")
    }

    if options.dryRun {
        print("\nlogical buffer:")
        print(Hex.dump(buffer))
        print("\ndry run — nothing was written")
        return
    }

    guard let connection = openDevice(options) else { return }
    do {
        try connection.setFeatureRetrying(PollingRate.preamble)
        usleep(200_000)
        for chunk in chunks {
            try connection.setFeatureRetrying(chunk)
            usleep(200_000)
        }
        print("\nok — preamble + \(chunks.count) chunks written")
        print("confirm with: asctl status 5   (expect an ack for report 0x09)")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func commandButtons(_ options: Options) {
    guard let spec = options.positionals[safe: 0] else {
        print("usage: asctl buttons <a1,a2,...>")
        print("       asctl buttons \"left,right,middle,back,forward\"")
        print("       asctl buttons \"left,right,middle,key:ctrl+c,macro:1\"")
        return
    }

    // `defaults` restores the factory mapping from the table.
    if spec == "defaults" {
        let actions = ButtonReport.factoryDefault.map {
            ButtonReport.Action(code: $0, describe: String(format: "0x%02X", $0))
        }
        let report = ButtonReport.build(actions)
        print("restoring the factory default mapping:")
        print("  1 left  2 right  3 wheel  4 dpi_cycle  5 MODE SWITCH  6 dpi_down")
        print("  7 forward  8 backward  9 mode  10-16 off  17 scroll_dn  18 scroll_up")
        print(Hex.dump(report))
        if options.dryRun {
            print("\ndry run — nothing was written")
            return
        }
        if sendReports([report], options) {
            print("ok — factory mapping restored")
        }
        return
    }

    var actions: [ButtonReport.Action?] = []
    for token in spec.split(separator: ",", omittingEmptySubsequences: false) {
        guard let action = ButtonReport.parseAction(String(token)) else {
            print("error: could not parse action \"\(token)\"")
            return
        }
        actions.append(action)
    }
    guard actions.count <= ButtonReport.buttonCount else {
        print("error: at most \(ButtonReport.buttonCount) buttons")
        return
    }

    // The vendor software enforces this too.
    // Writing a mapping with no left click would leave the mouse without a
    // primary button, so refuse rather than brick the pointer.
    guard actions.contains(where: { $0?.code == ButtonReport.leftClickCode }) else {
        print("error: at least one button must be `left`, or you will be left")
        print("       without a primary click. The vendor software refuses this too.")
        return
    }

    let report = ButtonReport.build(actions)
    print("button mapping (\(actions.count) of \(ButtonReport.buttonCount) assigned):")
    for (index, action) in actions.enumerated() {
        guard let action else { continue }
        print(String(format: "  button %2d  %02X %02X %02X   %@",
            index + 1, action.code, action.modifier, action.key,
            action.describe as NSString))
    }
    if actions.count < ButtonReport.buttonCount {
        print("  buttons \(actions.count + 1)-\(ButtonReport.buttonCount): unassigned (00 00 00)")
    }
    print(Hex.dump(report))

    if options.dryRun {
        print("\ndry run — nothing was written")
        return
    }

    print("\nWARNING: physical button order is NOT verified. Entry 1 is assumed")
    print("to be the left button, but nothing proves the ordering.")

    if sendReports([report], options) {
        print("ok — preamble + \(report.count)-byte report written")
    } else {
        exit(1)
    }
}

func applyProfile(_ profile: Profile, _ options: Options) {
    // Build every report first, then hand the whole set to sendReports so the
    // transport (HID or --ble) is chosen in one place. An earlier version
    // opened a HID connection directly here, which silently ignored --ble.
    var reports: [[UInt8]] = []
    var labels: [String] = []

    if let hz = profile.pollingRateHz, let report = PollingRate.report(hz: hz) {
        reports.append(report)
        labels.append("polling rate \(hz) Hz")
    }
    if let stages = profile.dpiStages, !stages.isEmpty {
        let colours: [(r: UInt8, g: UInt8, b: UInt8)] = (profile.colours ?? []).compactMap {
            $0.count == 3
                ? (r: UInt8(clamping: $0[0]), g: UInt8(clamping: $0[1]),
                   b: UInt8(clamping: $0[2]))
                : nil
        }
        var toggles = DpiReport.Toggles()
        toggles.liftOffDistance2mm = profile.liftOff2mm ?? false
        toggles.rippleControl = profile.rippleControl ?? false
        toggles.angleSnap = profile.angleSnap ?? false
        toggles.motionSync = profile.motionSync ?? false
        // Prefer the slot-accurate builder when the profile records which
        // slots are enabled: report 0x04 addresses eight slots by index, and
        // compacting them renumbers every stage above a disabled one.
        if let enabled = profile.stageEnabled, enabled.count == DpiReport.maxStages,
            stages.count == DpiReport.maxStages
        {
            let slots = (0..<DpiReport.maxStages).map { index -> DpiReport.Slot in
                let colour = index < colours.count ? colours[index] : (r: 255, g: 255, b: 255)
                return DpiReport.Slot(
                    dpi: stages[index], enabled: enabled[index], colour: colour)
            }
            reports.append(DpiReport.buildSlots(
                slots, activeSlot: profile.activeStage ?? 0, toggles: toggles.bytes))
        } else {
            reports.append(DpiReport.build(
                stages: stages,
                activeStage: profile.activeStage ?? 0,
                colours: colours, toggles: toggles.bytes))
        }
        labels.append("DPI + toggles")
    }
    if profile.sleepMinutes != nil || profile.deepSleepMinutes != nil
        || profile.debounceMs != nil
    {
        reports.append(LightReport.build(
            mode: .staticColour,
            sleepMinutes: UInt8(clamping: profile.sleepMinutes ?? 0),
            deepSleepMinutes: UInt8(clamping: profile.deepSleepMinutes ?? 0),
            keyDebounceMs: UInt8(clamping: profile.debounceMs ?? 0)))
        labels.append("power")
    }
    if let names = profile.buttons {
        let actions = names.map { ButtonReport.parseAction($0) }
        if actions.contains(where: { $0?.code == ButtonReport.leftClickCode }) {
            reports.append(ButtonReport.build(actions))
            labels.append("buttons")
        } else {
            print("  buttons: skipped — no `left` action")
        }
    }

    print("  sending: \(labels.joined(separator: ", "))")
    if sendReports(reports, options) {
        print("  ok")
    }
}

func commandProfile(_ options: Options) {
    guard let action = options.positionals[safe: 0] else {
        print("usage: asctl profile save <name> [options]")
        print("       asctl profile apply <name>")
        print("       asctl profile list")
        return
    }

    switch action {
    case "list":
        let names = Profile.names()
        if names.isEmpty {
            print("no saved profiles (\(Profile.directory.path))")
            return
        }
        for name in names {
            print("\(name):")
            if let profile = try? Profile.load(name) {
                for line in profile.summary { print("  \(line)") }
            }
        }

    case "save":
        guard let name = options.positionals[safe: 1] else {
            print("usage: asctl profile save <name> [options]")
            return
        }
        var profile = Profile()
        profile.dpiStages = options.positionals[safe: 2]?
            .split(separator: ",").compactMap { Int($0) }
        // --active is 1-based for the user; the file format is 0-based.
        profile.activeStage = options.activeStage.map { max(0, $0 - 1) }
        profile.pollingRateHz = options.positionals[safe: 3].flatMap { Int($0) }
        if let colours = options.colours {
            profile.colours = colours.split(separator: ";").map {
                $0.split(separator: ",").compactMap { Int($0) }
            }
        }
        if let buttons = options.buttonSpec {
            profile.buttons = buttons.split(separator: ",").map(String.init)
        }
        profile.liftOff2mm = options.toggles.liftOffDistance2mm
        profile.rippleControl = options.toggles.rippleControl
        profile.angleSnap = options.toggles.angleSnap
        profile.motionSync = options.toggles.motionSync
        profile.sleepMinutes = options.sleepMinutes
        profile.deepSleepMinutes = options.deepSleepMinutes
        profile.debounceMs = options.debounceMs
        do {
            try profile.save(as: name)
            print("saved \(name):")
            for line in profile.summary { print("  \(line)") }
            print("\n\(Profile.url(name).path)")
        } catch {
            print("error: could not save — \(error)")
        }

    case "apply":
        guard let name = options.positionals[safe: 1] else {
            print("usage: asctl profile apply <name>")
            return
        }
        guard let profile = try? Profile.load(name) else {
            print("error: no profile named \(name)")
            print("available: \(Profile.names().joined(separator: ", "))")
            return
        }
        print("applying \(name):")
        for line in profile.summary { print("  \(line)") }
        print("")
        applyProfile(profile, options)

    default:
        print("unknown profile action: \(action)")
    }
}

func commandBLE(_ options: Options) {
    let action = options.positionals[safe: 0] ?? "scan"
    let ble = BLEConnection()

    print("searching for the mouse over Bluetooth…")
    guard ble.discover() else {
        print("error: \(ble.lastError ?? "no Bluetooth peripherals found")")
        print("\nMake sure the mouse is switched to Bluetooth mode and connected.")
        print("macOS may also need to grant this terminal Bluetooth access.")
        return
    }

    // List everything found. The X3 has two Bluetooth identities (X3-5.2 and
    // X3-5.4, switched by the mode button) and macOS can hold bindings to both,
    // so which one is being addressed matters.
    let candidates = ble.foundPeripherals.map { $0.0 }
    print("found \(candidates.count) peripheral(s):")
    for peripheral in candidates {
        print("  \(peripheral.name ?? "(unnamed)")   state=\(peripheral.state.rawValue)  \(peripheral.identifier.uuidString)")
    }
    let target: CBPeripheral
    if let wanted = options.peripheralName?.lowercased() {
        guard let match = candidates.first(where: {
            ($0.name ?? "").lowercased().contains(wanted)
        }) else {
            print("\nerror: no peripheral matching \"\(wanted)\"")
            return
        }
        target = match
    } else {
        target = candidates.first { ($0.name ?? "").lowercased().contains("mouse") }
            ?? candidates.first!
    }
    print("using \(target.name ?? target.identifier.uuidString)")

    guard ble.connect(target) else {
        print("error: \(ble.lastError ?? "no FEE3 characteristic found")")
        print("\nGATT table:")
        for line in ble.describeServices() { print("  \(line)") }
        return
    }

    print("\nGATT table:")
    for line in ble.describeServices() { print("  \(line)") }
    let subscribed = ble.subscribe()
    print("FEE4 notifications: \(subscribed ? "subscribed" : "not available")")
    print("max single write: \(ble.maximumWriteLength) bytes")

    switch action {
    case "scan":
        print("\nFEE3 write characteristic found — `asctl ble write <hex>` can be used.")

    case "write":
        // Every buffer goes over ONE connection, with the preamble first.
        // The USB path proved a config report is silently ignored unless the
        // preamble immediately precedes it; sending them from separate
        // invocations would reconnect in between and break that.
        let specs = Array(options.positionals.dropFirst())
        guard !specs.isEmpty else {
            print("usage: asctl ble write \"06 09 01 08 F7\" [more buffers…]")
            return
        }
        var buffers: [[UInt8]] = [PollingRate.preamble]
        for spec in specs {
            guard var bytes = Hex.decode(spec) else {
                print("error: could not parse \"\(spec)\" as hex")
                return
            }
            if bytes.first == X3Report.configReportID
                && bytes.count < X3Report.configReportLength
            {
                bytes += [UInt8](
                    repeating: 0, count: X3Report.configReportLength - bytes.count)
            }
            buffers.append(bytes)
        }
        print("")
        for (index, bytes) in buffers.enumerated() {
            let label = index == 0 ? "preamble" : "buffer \(index)"
            print("\(label): \(Hex.encode(bytes))")
            if !ble.write(bytes) {
                print("  error: \(ble.lastError ?? "write failed")")
                return
            }
        }
        print("\nok — \(buffers.count) buffer(s) written over one connection")
        // Any reply on FEE4 is the device acknowledging, mirroring the 0x5010
        // acks seen on the USB path.
        ble.listen(seconds: 3)
        if ble.notifications.isEmpty {
            print("no FEE4 notifications — the device did not reply")
        } else {
            print("FEE4 replies:")
            for packet in ble.notifications { print("  \(Hex.encode(packet))") }
        }

    case "listen":
        let seconds = options.positionals[safe: 1].flatMap(Double.init) ?? 15
        print("\nlistening on FEE4 for \(seconds)s…")
        ble.listen(seconds: seconds)
        if ble.notifications.isEmpty {
            print("  no notifications received")
        }
        for packet in ble.notifications { print("  \(Hex.encode(packet))") }

    default:
        print("unknown ble action: \(action)")
    }
}

func commandFixBluetooth(_ options: Options) {
    print("The mouse sometimes reconnects over Bluetooth with working buttons")
    print("and a dead cursor. Every config report — including the DPI report")
    print("that programs the sensor — is acknowledged in that state and none")
    print("of them revives it, so only a link teardown clears it.\n")
    _ = BluetoothPower.cycle()
}

func commandScroll(_ options: Options) {
    let requested = options.positionals[safe: 0] ?? "status"

    if requested == "status" {
        print("macOS natural scrolling: \(ScrollController.macOSNaturalScrolling ? "on" : "off")")
        print("")
        for mode in [ScrollDirection.follow, .standard, .natural] {
            let action = ScrollController.shouldInvert(mode)
                ? "would invert wheel events" : "no interception needed"
            print("  \(mode.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(mode.label)")
            print("            → \(action)")
        }
        print("\nrun e.g.  asctl scroll standard")
        return
    }

    if requested == "debug" {
        // With a mode, run the real inverting tap and log what it does to each
        // event — a listen-only tap cannot show whether a modification lands.
        if options.positionals[safe: 1] == "block" {
            ScrollController.block()
            return
        }
        if let name = options.positionals[safe: 1],
           let mode = ScrollDirection(rawValue: name) {
            ScrollController.run(mode, verbose: true)
        } else {
            ScrollController.debug()
        }
        return
    }

    if requested == "install" {
        guard let name = options.positionals[safe: 1],
            let mode = ScrollDirection(rawValue: name)
        else {
            print("usage: asctl scroll install <standard|natural>")
            return
        }
        do {
            try ScrollController.install(mode)
            print("installed \(ScrollController.agentURL.path)")
            print("")
            print("start it now with:")
            print("  launchctl load \(ScrollController.agentURL.path)")
            print("")
            print("it will then run at every login until `asctl scroll uninstall`.")
        } catch {
            print("error: \(error)")
        }
        return
    }

    if requested == "uninstall" {
        do {
            try ScrollController.uninstall()
            print("removed the LaunchAgent. Stop the running one with:")
            print("  launchctl unload \(ScrollController.agentURL.path)")
        } catch {
            print("error: \(error)")
        }
        return
    }

    guard let mode = ScrollDirection(rawValue: requested) else {
        print("usage: asctl scroll <status|follow|standard|natural>")
        print("       asctl scroll install <standard|natural>")
        print("       asctl scroll uninstall")
        return
    }
    ScrollController.run(mode)
}

func commandWatch(_ options: Options) {
    let seconds = options.positionals[safe: 0].flatMap(Double.init) ?? 5.0
    var devices = candidateDevices(options)
    // Honour --index here too, so a single interface can be isolated when
    // hunting for status reports.
    if let index = options.index, let only = devices[safe: index] {
        devices = [only]
    }
    guard !devices.isEmpty else {
        print("No matching device. Try `asctl list --all`.")
        return
    }

    print("listening on \(devices.count) interface(s) for \(seconds)s — move the mouse now\n")
    let watcher = InputWatcher(devices: devices, dumpAll: options.raw)
    let channels = watcher.run(seconds: seconds)

    var total = 0
    for channel in channels where channel.count > 0 {
        total += channel.count
        let avg = channel.ratePerSecond.map { String(format: "%.0f/s", $0) } ?? "—"
        print("\(channel.info.descriptorText)")
        print("   reports: \(channel.count)   average incl. idle: \(avg)")
        if let gap = channel.medianGapMs, let hz = channel.pollingRateHz {
            print(String(format: "   median gap while moving: %.2f ms  →  %.0f Hz", gap, hz))
            let gaps = channel.gapsMs.filter { $0 < 50 }
            if let smallest = gaps.min() {
                print(String(format: "   smallest gap seen: %.3f ms", smallest))
            }
            // A histogram settles whether the rate is the mouse's choice or a
            // USB ceiling: if literally no gap falls below the median, the host
            // endpoint interval is the limit, not the device setting.
            var buckets: [String: Int] = [:]
            for g in gaps {
                let key = String(format: "%.0f", (g * 2).rounded() / 2)
                buckets[key, default: 0] += 1
            }
            let top = buckets.sorted { $0.value > $1.value }.prefix(6)
            print("   gap histogram (ms → count): "
                + top.map { "\($0.key)→\($0.value)" }.joined(separator: "  "))
        } else {
            print("   not enough continuous movement to measure the rate")
        }
        if channel.countsX > 0 || channel.countsY > 0 {
            let distance = (Double(channel.countsX * channel.countsX
                + channel.countsY * channel.countsY)).squareRoot()
            print("   sensor counts: x=\(channel.countsX) y=\(channel.countsY)"
                + String(format: "  (vector %.0f)", distance))
            if channel.movingReports > 0 {
                let locked = Double(channel.axisLockedReports) / Double(channel.movingReports)
                print(String(
                    format: "   axis-locked reports: %d/%d = %.1f%%",
                    channel.axisLockedReports, channel.movingReports, locked * 100))
            }
            if channel.fastHorizontal > 20 {
                let flat = Double(channel.fastHorizontalFlat) / Double(channel.fastHorizontal)
                print(String(
                    format: "   dy==0 during fast |dx|>=5: %d/%d = %.1f%%",
                    channel.fastHorizontalFlat, channel.fastHorizontal, flat * 100))
                print("   longest unbroken dy==0 run: \(channel.longestFlatRun) reports"
                    + "   <- angle-snap indicator")
            }
            if let roughness = channel.roughness, let reversals = channel.dyReversalRate {
                print(String(
                    format: "   roughness (mean|dx-dx'| / mean|dx|): %.3f   <- ripple-control indicator",
                    roughness))
                print(String(format: "   dy sign-reversal rate: %.3f", reversals))
            }
            if let cv = channel.displacementCV, let zero = channel.zeroMotionRate {
                print(String(
                    format: "   displacement CV: %.3f   zero-motion reports: %.3f", cv, zero))
                if let autocorrelation = channel.lag1Autocorrelation {
                    print(String(
                        format: "   lag-1 autocorrelation: %+.3f   <- motion-sync indicator",
                        autocorrelation))
                }
            }
        }
        for sample in channel.samples {
            print("   \(Hex.encode(sample))")
        }
        print("")
    }

    if total == 0 {
        print("No input reports seen.")
        print("Either the mouse is asleep/not paired to the dongle, or macOS is")
        print("withholding input: grant Input Monitoring in System Settings ▸")
        print("Privacy & Security ▸ Input Monitoring, then retry.")
    } else if let measured = channels.compactMap({ $0.pollingRateHz }).max() {
        let nearest = PollingRate.supported.min {
            abs(Double($0) - measured) < abs(Double($1) - measured)
        }
        print(String(format: "measured polling rate: %.0f Hz", measured))
        if let nearest { print("nearest supported setting: \(nearest) Hz") }
    } else {
        print("Saw reports, but not enough continuous motion to measure the rate.")
        print("Re-run and keep the mouse moving for the whole window.")
    }
}

// MARK: - Entry point

/// Launched from inside an .app with no arguments? Open the GUI.
///
/// The bundle used to point CFBundleExecutable at a wrapper script that ran
/// `asctl gui`, but a process whose name does not match CFBundleExecutable is
/// not treated as the bundle's main executable — macOS then never reads
/// Contents/Info.plist, so the Bluetooth usage description went unseen and TCC
/// terminated the app the moment it used CoreBluetooth.
func launchedAsBundledApp() -> Bool {
    guard CommandLine.arguments.count == 1 else { return false }
    return Bundle.main.bundleURL.pathExtension == "app"
        || Bundle.main.bundleIdentifier == "io.github.yourchocomate.asctl"
}

if launchedAsBundledApp() { runGUI() }

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))

switch options.command {
case "list": commandList(options)
case "descriptor", "desc": commandDescriptor(options)
case "probe": commandProbe(options)
case "get": commandGet(options)
case "set": commandSet(options)
case "send": commandSend(options)
case "pollrate": commandPollRate(options)
case "dpi": commandDpi(options)
case "gui": runGUI()
case "selftest": SelfTest.run()
case "power-test":
    switch options.positionals[safe: 0]?.lowercased() {
    case "debounce": PowerTest.debounce(options)
    case "sleep": PowerTest.sleep(options)
    case "wake": PowerTest.wake(options)
    default:
        print("usage: asctl power-test debounce [seconds]")
        print("       asctl power-test sleep <minutes>")
        print("       asctl power-test wake <minutes>")
    }
case "blediag": commandBLEDiag(options)
case "macos-battery": exit(MacOSBatterySource.run())
case "version", "--version", "-v":
  print("asctl \(AppVersion.current) (build \(AppVersion.build))")
  exit(0)
case "battery-probe":
  exit(BatteryProbe.run(seconds: TimeInterval(options.positionals.first.flatMap(Int.init) ?? 120)))
case "light": commandLight(options)
case "light-probe": LightProbe.run(options)
case "power": commandPower(options)
case "macro": commandMacro(options)
case "buttons": commandButtons(options)
case "profile": commandProfile(options)
case "ble": commandBLE(options)
case "scroll": commandScroll(options)
case "fix-bluetooth": commandFixBluetooth(options)
case "status": commandStatus(options)
case "watch": commandWatch(options)
case "help", "--help", "-h": print(usage)
default:
    print("unknown command: \(options.command)\n")
    print(usage)
    exit(1)
}
