import Foundation

/// `asctl selftest` — check that the reports we build match what the protocol
/// actually requires, without touching hardware.
///
/// This exists because the GUI made a mistake that the CLI could not: it
/// compacted the enabled DPI stages into the low slots. On the wire the eight
/// slots are addressed by index and enablement is carried only by a bitmask, so
/// switching off a middle stage renumbered every stage above it. Nothing caught
/// it, because a wrong-but-well-formed report is accepted and acknowledged by
/// the device exactly like a correct one.
///
/// Every expectation below is derived from the vendor's own encoder, not from
/// what this code happens to produce.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func expect(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
        checks += 1
        if "\(actual)" == "\(expected)" {
            print("  ok    \(label)")
        } else {
            failures += 1
            print("  FAIL  \(label)\n          expected \(expected)\n          actual   \(actual)")
        }
    }

    static func run() {
        failures = 0
        checks = 0

        print("DPI — report 0x04, factory configuration")
        let factory = DpiReport.buildSlots(
            DpiReport.factorySlots, activeSlot: DpiReport.factoryActiveSlot)

        expect("report id", factory[0], 0x04)
        expect("declared length", factory[1], 56)
        expect("profile byte", factory[2], 1)
        // Six enabled slots, two off → 0b00111111.
        expect("enabled bitmask", String(factory[5], radix: 2), "111111")
        // The vendor writes the active slot one-based.
        expect("active slot byte", factory[24], UInt8(DpiReport.factoryActiveSlot + 1))

        // dpi/50 - 1, split across a low plane at byte 8 and a high plane at 16.
        let expectedWire = [15, 31, 47, 63, 99, 519, 0, 0]
        for (index, wire) in expectedWire.enumerated() {
            let low = Int(factory[8 + index])
            let high = Int(factory[16 + index])
            expect("slot \(index) wire value", low | (high << 8), wire)
        }
        expect("26000 DPI uses the high plane", factory[16 + 5], 2)

        // Colour is three bytes per slot in RGB order, starting at byte 25.
        for (index, slot) in DpiReport.factorySlots.enumerated() {
            let wire = [factory[25 + index * 3], factory[26 + index * 3], factory[27 + index * 3]]
            expect("slot \(index) colour", Hex.encode(wire),
                   Hex.encode([slot.colour.r, slot.colour.g, slot.colour.b]))
        }
        expect("trailing constant", factory[49], 0x01)
        expect("checksum", checksumOK(factory, payload: 3...49, at: 50), true)

        print("\nDPI — a disabled middle slot must not renumber the others")
        var gapped = DpiReport.factorySlots
        gapped[2].enabled = false
        let gappedReport = DpiReport.buildSlots(gapped, activeSlot: 0)
        expect("bitmask has the gap", String(gappedReport[5], radix: 2), "111011")
        expect("slot 3 keeps its own value", Int(gappedReport[8 + 3]), 63)
        expect("slot 3 keeps its own colour", gappedReport[25 + 9], 255)
        expect("disabled slot still carries DPI", Int(gappedReport[8 + 2]), 47)

        print("\nDPI — this unit's stock configuration (the GUI default)")
        // 800/blue, 1600/cyan, 3200/green, 5000/yellow, 26000/red — observed on
        // the hardware. Deliberately not the vendor's reset table, which has six
        // stages and a different palette.
        let stock: [DpiReport.Slot] = [
            .init(dpi: 800, enabled: true, colour: (0, 0, 255)),
            .init(dpi: 1600, enabled: true, colour: (0, 255, 255)),
            .init(dpi: 3200, enabled: true, colour: (0, 255, 0)),
            .init(dpi: 5000, enabled: true, colour: (255, 255, 0)),
            .init(dpi: 26000, enabled: true, colour: (255, 0, 0)),
            .init(dpi: 0, enabled: false, colour: (0, 0, 0)),
            .init(dpi: 0, enabled: false, colour: (0, 0, 0)),
            .init(dpi: 0, enabled: false, colour: (0, 0, 0)),
        ]
        let stockReport = DpiReport.buildSlots(stock, activeSlot: 0)
        expect("five stages enabled", String(stockReport[5], radix: 2), "11111")
        expect("active slot is 1-based", stockReport[24], 1)
        expect("wire values", (0..<5).map { Int(stockReport[8 + $0]) | (Int(stockReport[16 + $0]) << 8) },
               [15, 31, 63, 99, 519])
        expect("800 is blue", Hex.encode(Array(stockReport[25...27])), "00 00 FF")
        expect("26000 is red", Hex.encode(Array(stockReport[37...39])), "FF 00 00")
        expect("checksum", checksumOK(stockReport, payload: 3...49, at: 50), true)

        print("\nDPI — encoding edges")
        expect("50 DPI is the floor", DpiReport.wireValue(forDpi: 50), 0)
        expect("26000 DPI round-trips", DpiReport.dpi(forWireValue: 519), 26000)
        var zeroed = DpiReport.factorySlots
        zeroed[0].dpi = 0
        let zeroedReport = DpiReport.buildSlots(zeroed, activeSlot: 0)
        expect("a zero slot stays zero, not 0xFF", zeroedReport[8], 0)

        print("\nProfiles — round-trip through the file format")
        var round = Profile()
        round.dpiStages = DpiReport.factorySlots.map { $0.dpi }
        round.stageEnabled = DpiReport.factorySlots.map { $0.enabled }
        round.activeStage = DpiReport.factoryActiveSlot   // 0-based, by definition
        round.colours = DpiReport.factorySlots.map {
            [Int($0.colour.r), Int($0.colour.g), Int($0.colour.b)]
        }
        let encoded = try! JSONEncoder().encode(round)
        let decoded = try! JSONDecoder().decode(Profile.self, from: encoded)
        expect("stage count survives", decoded.dpiStages?.count ?? 0, 8)
        expect("enablement survives", decoded.stageEnabled?.filter { $0 }.count ?? 0, 6)
        expect("active slot is 0-based", decoded.activeStage ?? -1, 1)

        let slots = (0..<8).map { index in
            DpiReport.Slot(
                dpi: decoded.dpiStages![index],
                enabled: decoded.stageEnabled![index],
                colour: (UInt8(decoded.colours![index][0]),
                         UInt8(decoded.colours![index][1]),
                         UInt8(decoded.colours![index][2])))
        }
        let rebuilt = DpiReport.buildSlots(slots, activeSlot: decoded.activeStage!)
        let direct = DpiReport.buildSlots(
            DpiReport.factorySlots, activeSlot: DpiReport.factoryActiveSlot)
        expect("rebuilt report is byte-identical", Hex.encode(rebuilt), Hex.encode(direct))

        print("\nPolling rate — report 0x06")
        for (hz, divider) in [(125, 8), (250, 4), (500, 2), (1000, 1)] {
            guard let report = PollingRate.report(hz: hz) else {
                expect("\(hz) Hz builds", false, true)
                continue
            }
            expect("\(hz) Hz divider", report[3], UInt8(divider))
            // Byte 4 is the one's complement of the divider, not a checksum.
            expect("\(hz) Hz complement", report[4], UInt8(~UInt8(divider)))
        }
        expect("an unsupported rate is refused", PollingRate.report(hz: 8000) == nil, true)

        print("\nApply preamble")
        expect(
            "preamble bytes", Hex.encode(PollingRate.preamble),
            "0C 0A 01 FE 01 FE 00 00 00 00")

        print("\nButtons — report 0x08")
        let buttons = ButtonReport.build(
            ButtonReport.factoryDefault.map { ButtonReport.Action(code: $0, describe: "") })
        expect("report id", buttons[0], 0x08)
        expect("declared length", buttons[1], 59)
        expect("18 entries of 3 bytes", 3 + 18 * 3, 57)
        expect("entry 1 is left click", buttons[3], 0x02)
        expect("entry 4 is dpi_cycle", buttons[3 + 3 * 3], 0x0D)
        expect("entry 5 is mode switch", buttons[3 + 4 * 3], 0x3C)
        expect("entry 7 is forward", buttons[3 + 6 * 3], 0x06)
        expect("entry 8 is backward", buttons[3 + 7 * 3], 0x05)
        expect("checksum", checksumOK(buttons, payload: 3...56, at: 57), true)

        print("\nButtons — action parsing")
        expect("ctrl+c is a HID usage, not ASCII",
               Hex.encode(actionBytes("key:ctrl+c")), "11 01 06")
        expect("macro slot lands in byte 3",
               Hex.encode(actionBytes("macro:2")), "12 00 02")
        expect("easy_aim keeps its third byte",
               Hex.encode(actionBytes("easy_aim")), "10 00 03")
        expect("button_off is 0x01, not 0x00",
               actionBytes("button_off").first ?? 0, 0x01)

        print("\nPower — report 0x05")
        let power = LightReport.build(
            mode: .off, sleepMinutes: 10, deepSleepMinutes: 10, keyDebounceMs: 10)
        expect("report id", power[0], 0x05)
        expect("declared length", power[1], 15)
        expect("sleep minutes", power[9], 10)
        expect("debounce ms", power[10], 10)
        // Deep sleep is split: high nibble into byte 4, low nibble into byte 5.
        expect("deep sleep high nibble", power[4] & 0xF0, 0x00)
        expect("deep sleep low nibble", (power[5] & 0xF0) >> 4, 10)
        expect("checksum", checksumOK(power, payload: 3...10, at: 11), true)

        // Battery — status event 0x4010.
        //
        // Expectations taken from X3.exe 0x00413418-0x00413473: the level is the
        // high byte, valid only in 1...10 and multiplied by ten for display; the
        // low byte being zero means asleep.
        print("\nBattery — status event 0x4010")

        let awake = StatusEvent.Event(code: 0x4010, value: 0x0501)
        expect("level 5 reads as 50%", awake.batteryPercent ?? -1, 50)
        expect("non-zero low byte is awake", awake.isAsleep ?? true, false)

        let asleep = StatusEvent.Event(code: 0x4010, value: 0x0A00)
        expect("level 10 reads as 100%", asleep.batteryPercent ?? -1, 100)
        expect("zero low byte is asleep", asleep.isAsleep ?? false, true)

        // The vendor's range check is `level - 1 <= 9` unsigned, so both zero
        // and eleven fall out and leave the gauge untouched.
        expect("level 0 is rejected",
               StatusEvent.Event(code: 0x4010, value: 0x0001).batteryPercent == nil, true)
        expect("level 11 is rejected",
               StatusEvent.Event(code: 0x4010, value: 0x0B01).batteryPercent == nil, true)

        // Ten discrete steps and nothing between them: every reachable level
        // must land on a multiple of ten.
        var offGrid = 0
        for level in 1...10 {
            let event = StatusEvent.Event(code: 0x4010, value: UInt16(level) << 8 | 1)
            if (event.batteryPercent ?? -1) % 10 != 0 { offGrid += 1 }
        }
        expect("every level is a multiple of ten", offGrid, 0)

        expect("the heartbeat window is the vendor's six seconds",
               AppState.batteryHeartbeat, 6.0)

        // Scroll direction — persisted by raw value, so the strings are load
        // bearing. Renaming a case would silently discard a saved choice.
        print("\nScroll direction — persistence")
        for mode in ScrollDirection.allCases {
            expect("\(mode.rawValue) round-trips",
                   ScrollDirection(rawValue: mode.rawValue) == mode, true)
        }
        expect("an unknown value does not decode",
               ScrollDirection(rawValue: "sideways") == nil, true)

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("\(failures) FAILED")
            exit(1)
        }
    }

    private static func actionBytes(_ spec: String) -> [UInt8] {
        guard let action = ButtonReport.parseAction(spec) else { return [] }
        return [action.code, action.modifier, action.key]
    }

    /// The checksum is a 16-bit sum of the payload, stored big-endian.
    private static func checksumOK(
        _ report: [UInt8], payload: ClosedRange<Int>, at offset: Int
    ) -> Bool {
        let sum = X3Report.checksum(payload: report[payload])
        return report[offset] == sum.high && report[offset + 1] == sum.low
    }
}
