import Foundation

/// `asctl light-probe` — a scripted hardware sweep of the lighting fields.
///
/// ## Why this still exists
///
/// The X3 has no user-controllable lighting: report `0x05`'s mode, brightness,
/// speed and colour fields have no target on this model, and the vendor's own
/// tool does not expose a light panel for it either. Sweeping them on an X3
/// will do nothing, and that is the expected result.
///
/// It is kept because the lighting fields are implemented and correct as far as
/// they can be checked, and other mice in the same family do have lighting. On
/// one of those, this command answers in a single run what would otherwise take
/// a dozen hand-typed writes.
///
/// ## Two confounders, if you run it on a model that does light up
///
/// Both of these own the LED and will mask any result:
///
///   - **Bluetooth.** The mode LED shows the channel — green on X3-5.2, blue on
///     X3-5.4. A status indicator that owns the LED masks anything underneath.
///   - **Charging.** A charge indicator has exactly the same claim on it.
///
/// This is not hypothetical. Three findings in this project were false
/// negatives from testing at the wrong operating point, and the wired lighting
/// sweep became a fourth — it ran while the mouse was charging, which made its
/// six clean "no change" lines worthless. Unplug, and prefer the 2.4 GHz
/// receiver.
enum LightProbe {
    struct Step {
        let title: String
        let expectation: String
        let report: [UInt8]
    }

    /// Report `0x05` is atomic — the same 15 bytes carry the sleep timer, the
    /// deep sleep timer and the key debounce alongside the lighting fields.
    ///
    /// Every previous lighting attempt left those three at **zero**, and zero is
    /// out of range for all three: the vendor's UI layout declares the sleep
    /// sliders as 1–60 and debounce as 2–25, so the vendor software can never
    /// transmit a zero there. A firmware that validates the report as a whole
    /// would checksum it, acknowledge it, and then decline to apply it — which
    /// is exactly the behaviour we have been unable to explain.
    ///
    /// So the probe sends in-range values. These are ordinary settings, not
    /// aggressive ones: a 10 minute sleep timer, a 10 minute deep sleep timer
    /// and a 10 ms debounce.
    static let sleep: UInt8 = 10
    static let deepSleep: UInt8 = 10
    static let debounce: UInt8 = 10

    /// Sweep the mode field through the values that should look most different
    /// from each other. Colour is deliberately saturated and primary — a dim or
    /// mixed colour is exactly the kind of change that gets argued about later.
    static func modeSteps() -> [Step] {
        var steps: [Step] = []

        func add(
            _ title: String, _ expectation: String,
            _ mode: LightReport.Mode,
            red: UInt8 = 255, green: UInt8 = 0, blue: UInt8 = 0,
            brightness: UInt8 = 8, speed: UInt8 = 4
        ) {
            steps.append(Step(
                title: title, expectation: expectation,
                report: LightReport.build(
                    mode: mode, red: red, green: green, blue: blue,
                    brightness: brightness, speed: speed,
                    sleepMinutes: sleep, deepSleepMinutes: deepSleep,
                    keyDebounceMs: debounce)))
        }

        // Every mode here is 0…6. The vendor's live mode list hides entries
        // 8-12, so this model only offers the first seven — probing Rainbow
        // Wave or Marquee would be probing another product's feature.
        add("Static — full red", "a steady red LED", .staticColour)
        add("Static — full green", "the same LED, now green",
            .staticColour, red: 0, green: 255, blue: 0)
        add("Static — full blue, dimmest", "blue, and clearly dimmer than the last two",
            .staticColour, red: 0, green: 0, blue: 255, brightness: 1)
        add("LED Off", "the LED dark", .off)
        add("Breathing — red, speed 4", "red fading in and out", .breathing, speed: 4)
        add("Colour Breathing — speed 8", "colours fading through each other",
            .colourBreathing, speed: 8)

        return steps
    }

    /// Alternative encodings of byte 3, for the case where every mode step is
    /// inert. The vendor software writes `mode << 4`, which is what
    /// `LightReport.build` does — these are the other readings that would be
    /// consistent with it if the combo index were stored differently than
    /// assumed.
    ///
    /// Every one of these is "Static, full red, max brightness". Only byte 3
    /// changes, so anything that lights up identifies the encoding outright.
    static func encodingSteps() -> [Step] {
        func red(_ override: UInt8, zeroTimers: Bool = false) -> [UInt8] {
            LightReport.build(
                mode: .staticColour, red: 255, green: 0, blue: 0, brightness: 8,
                sleepMinutes: zeroTimers ? 0 : sleep,
                deepSleepMinutes: zeroTimers ? 0 : deepSleep,
                keyDebounceMs: zeroTimers ? 0 : debounce,
                modeByteOverride: override)
        }

        return [
            Step(title: "byte 3 = 0x10 — mode << 4 (what the vendor software does)",
                 expectation: "steady red",
                 report: red(0x10)),
            Step(title: "byte 3 = 0x01 — mode unshifted, low nibble",
                 expectation: "steady red",
                 report: red(0x01)),
            Step(title: "byte 3 = 0x11 — mode in both nibbles",
                 expectation: "steady red",
                 report: red(0x11)),
            Step(title: "byte 3 = 0x20 — 1-based mode, shifted",
                 expectation: "steady red",
                 report: red(0x20)),
            Step(title: "byte 3 = 0x02 — 1-based mode, unshifted",
                 expectation: "steady red",
                 report: red(0x02)),
            Step(title: "byte 3 = 0x10, timers zeroed — the old, always-inert form",
                 expectation: "nothing, if the out-of-range-timer theory is right",
                 report: red(0x10, zeroTimers: true)),
        ]
    }

    static func run(_ options: Options) {
        let which = options.positionals[safe: 0]?.lowercased() ?? "modes"
        let steps: [Step]
        switch which {
        case "modes": steps = modeSteps()
        case "encodings", "encoding": steps = encodingSteps()
        default:
            print("usage: asctl light-probe [modes|encodings] [--auto <seconds>]")
            return
        }

        if options.dryRun {
            for (index, step) in steps.enumerated() {
                print("\(index + 1). \(step.title)")
                print("   \(Hex.dump(step.report))")
            }
            return
        }

        if options.useBLE {
            print("""

                Probing over Bluetooth. Two things to keep separate while you
                watch, because a confusion between them is the whole risk here:

                  • the **mode LED**, which shows the channel — green on X3-5.2,
                    blue on X3-5.4. That is a status indicator. It is expected
                    not to respond, and it is not what we are testing.
                  • the **lighting**, which is what these reports address.

                The vendor software cannot do this at all, so a
                positive result here is new ground rather than a reproduction.

                """)
        } else {
            print("""

                Before you start:
                  • the mouse should be on 2.4 GHz (LED red), not Bluetooth
                  • unplug the charging cable — a charge indicator owns the LED

                """)
        }
        print("\(steps.count) steps. After each one, look at the mouse.\n")

        // The Bluetooth path reconnects per step. That is slower than holding
        // one session open, but it reuses `sendReports`, which is the code that
        // is actually known to work over GATT — and the pauses between steps
        // dominate the runtime anyway.
        var connection: HIDConnection?
        if !options.useBLE {
            guard let opened = openDevice(options) else { return }
            connection = opened
        }

        let auto = options.autoSeconds
        var observations: [String] = []

        for (index, step) in steps.enumerated() {
            print("── \(index + 1)/\(steps.count)  \(step.title)")
            print("   \(Hex.dump(step.report))")
            if let connection {
                do {
                    // The preamble is mandatory and goes before every report,
                    // not once per session: a report that arrives without it is
                    // acknowledged at the USB level and then silently dropped.
                    try connection.setFeatureRetrying(PollingRate.preamble)
                    usleep(200_000)
                    try connection.setFeatureRetrying(step.report)
                    usleep(200_000)
                } catch {
                    print("   write failed: \(error)")
                    observations.append("\(index + 1). \(step.title) — WRITE FAILED")
                    continue
                }
            } else if !sendReports([step.report], options) {
                observations.append("\(index + 1). \(step.title) — WRITE FAILED")
                continue
            }
            print("   expect: \(step.expectation)")

            if let auto {
                Thread.sleep(forTimeInterval: auto)
                observations.append("\(index + 1). \(step.title) — not recorded (--auto)")
            } else {
                print("   what do you actually see? (Enter to skip, or type it) ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                observations.append(
                    "\(index + 1). \(step.title) — \(answer.isEmpty ? "no change" : answer)")
            }
            print("")
        }

        print("── summary")
        for line in observations { print("   \(line)") }

        guard which == "modes" else { return }

        if options.useBLE {
            print("""

                If every step read "no change", that is consistent with the
                firmware powering the wheel light down in Bluetooth mode — which
                is what the vendor software's own connection gate implies.
                It is not yet proof: the same null would appear if
                report 0x05 were being rejected for a reason unrelated to the
                transport.

                Those two are separated by running the identical sweep on the
                2.4 GHz receiver:

                    asctl light-probe modes

                If the light responds there, Bluetooth is a firmware power-
                saving decision and there is nothing to fix on our side. If it
                is inert there too, the problem is in the report and
                `asctl light-probe encodings` is the next step.
                """)
        } else {
            print("""

                If every step read "no change", the mode field is not the
                problem — run `asctl light-probe encodings` next, which holds
                everything constant and varies only byte 3.
                """)
        }
    }
}
