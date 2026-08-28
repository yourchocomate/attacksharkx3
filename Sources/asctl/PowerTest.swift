import Foundation

/// `asctl power-test` — measure whether report 0x05's timings actually do
/// anything.
///
/// Sleep, deep sleep and key debounce have been in this project as "mapped with
/// ranges; writes accepted, behaviour unmeasured" for a long time. Accepted is
/// not applied: the whole protocol's defining trap is that a well-formed report
/// is acknowledged whether or not the device acts on it. These are the
/// experiments that settle it.
///
/// Both are A/B tests against the same mouse minutes apart, because there is no
/// readback and therefore no way to confirm a setting except by its effect.
enum PowerTest {

    // MARK: Key debounce

    /// Key debounce is a floor on how quickly a button may change state again.
    ///
    /// So the observable is not an average but a **minimum**: with a 25 ms
    /// debounce, no press should ever register shorter than about 25 ms, while
    /// at 2 ms short presses become possible. Comparing the fastest taps at two
    /// settings is the test; comparing the typical tap is not, because typical
    /// taps are far above either floor.
    ///
    /// The honest caveat: this needs taps *faster* than the setting being
    /// tested. If every tap is 60 ms, a 25 ms floor never binds and the result
    /// is inconclusive rather than negative. The report says which happened.
    static func debounce(_ options: Options) {
        let seconds = options.positionals[safe: 1].flatMap(Double.init) ?? 20
        let settings = [2, 25]
        var results: [(ms: Int, durations: [Double], gaps: [Double])] = []
        var resolutions: [Double] = []

        print("""
            Key debounce — A/B test

            For each setting you will get \(Int(seconds)) seconds. Click the LEFT
            button as fast and as *briefly* as you can — flick it, do not hold
            it. The measurement is the shortest press, not the average one, so a
            few very fast taps matter more than many ordinary ones.

            """)

        for ms in settings {
            print("── setting debounce to \(ms) ms")
            let report = LightReport.build(
                mode: .off,
                sleepMinutes: UInt8(clamping: options.sleepMinutes ?? 10),
                deepSleepMinutes: UInt8(clamping: options.deepSleepMinutes ?? 10),
                keyDebounceMs: UInt8(clamping: ms))
            guard sendReports([report], options) else {
                print("could not write the setting — stopping")
                return
            }
            print("   settled. Click now, fast and brief, for \(Int(seconds))s…")
            Thread.sleep(forTimeInterval: 1.5)

            let (durations, gaps, resolution) = collectClicks(
                seconds: seconds, options: options)
            results.append((ms, durations, gaps))
            resolutions.append(resolution)
            printClickStats(durations: durations, gaps: gaps, resolution: resolution)
            if ms != settings.last { print("\n   pausing 3s\n"); Thread.sleep(forTimeInterval: 3) }
        }

        print("\n── comparison")
        guard results.count == 2,
              let lowMin = results[0].durations.min(),
              let highMin = results[1].durations.min()
        else {
            print("  not enough clicks were captured to compare")
            return
        }

        print(String(format: "  shortest press at %2d ms setting: %6.1f ms",
                     results[0].ms, lowMin))
        print(String(format: "  shortest press at %2d ms setting: %6.1f ms",
                     results[1].ms, highMin))

        let resolution = resolutions.max() ?? 0
        let separation = Double(results[1].ms - results[0].ms)
        if resolution > separation / 2 {
            print(String(format: """

                  UNRESOLVABLE. Input reports arrive every %.1f ms, so press
                  durations are quantised to that step — the observed values
                  land on multiples of it. The two settings differ by %.0f ms,
                  which this sampling rate cannot separate.

                  Re-run over the 2.4 GHz receiver at 1000 Hz, where reports
                  arrive every 1 ms:

                      asctl pollrate 1000
                      asctl power-test debounce

                  Bluetooth samples far too slowly for a millisecond-scale
                  measurement, whatever the debounce setting is doing.
                """, resolution, separation))
            return
        }

        let floor = Double(results[1].ms)
        if lowMin < floor - 3 && highMin >= floor - 3 {
            print("""

              CONFIRMED. Presses shorter than the high setting occurred only at
              the low setting, which is exactly what a debounce floor does.
            """)
        } else if lowMin >= floor - 3 {
            print("""

              INCONCLUSIVE — no tap was faster than \(Int(floor)) ms even at the
              low setting, so the floor was never tested. Try again with
              sharper flicks, or compare 2 ms against 25 ms only if you can
              produce presses under 25 ms.
            """)
        } else {
            print("""

              NO EFFECT MEASURED. Presses shorter than the high setting occurred
              at *both* settings, so the device is not applying the debounce
              value — or is applying it somewhere this cannot see.
            """)
        }
    }

    /// Watch the input reports and turn button edges into press durations and
    /// the gaps between presses.
    private static func collectClicks(
        seconds: Double, options: Options
    ) -> (durations: [Double], gaps: [Double], resolutionMs: Double) {
        let devices = candidateDevices(options).filter { $0.maxInputReportSize > 0 }
        guard !devices.isEmpty else { return ([], [], 0) }

        let watcher = InputWatcher(devices: devices, keepSamples: 0, quiet: true)
        let channels = watcher.run(seconds: seconds)

        // A press duration cannot be measured more finely than the interval
        // between input reports: the button edge is only visible when a report
        // carries it. This is the measurement's resolution, and comparing two
        // settings closer together than this is meaningless.
        var resolution = 0.0
        for channel in channels {
            let gaps = zip(channel.arrivalsNs.dropFirst(), channel.arrivalsNs)
                .map { Double($0 - $1) / 1_000_000 }
                .filter { $0 > 0.05 && $0 < 100 }
                .sorted()
            if !gaps.isEmpty { resolution = max(resolution, gaps[gaps.count / 2]) }
        }

        var durations: [Double] = []
        var gaps: [Double] = []
        for channel in channels {
            var pressedAt: UInt64?
            var releasedAt: UInt64?
            for edge in channel.buttonEdges {
                let anyDown = edge.mask != 0
                if anyDown {
                    if let released = releasedAt {
                        gaps.append(Double(edge.ns - released) / 1_000_000)
                    }
                    pressedAt = edge.ns
                } else if let pressed = pressedAt {
                    durations.append(Double(edge.ns - pressed) / 1_000_000)
                    releasedAt = edge.ns
                    pressedAt = nil
                }
            }
        }
        return (durations, gaps, resolution)
    }

    private static func printClickStats(
        durations: [Double], gaps: [Double], resolution: Double
    ) {
        guard !durations.isEmpty else {
            print("   no clicks captured")
            return
        }
        print(String(format: "   report interval %.1f ms — the finest difference "
                     + "this run can resolve", resolution))
        let sorted = durations.sorted()
        print(String(
            format: "   %d presses   shortest %.1f ms   median %.1f ms   longest %.1f ms",
            sorted.count, sorted.first!, sorted[sorted.count / 2], sorted.last!))
        let shortest = sorted.prefix(5).map { String(format: "%.1f", $0) }
        print("   five shortest: \(shortest.joined(separator: ", ")) ms")
        if let gap = gaps.min() {
            print(String(format: "   shortest gap between presses: %.1f ms", gap))
        }
    }

    // MARK: Sleep timers

    /// Sleep is a timeout on inactivity — but *silence is not sleep*.
    ///
    /// A first version of this measured how long the device stayed quiet after
    /// the user stopped touching it, and reported the answer as the sleep time.
    /// That is meaningless: a mouse nobody is moving sends no reports whether
    /// it is asleep or wide awake. The number it produced was its own timeout,
    /// not the device's.
    ///
    /// What is actually observable is a **state change**. When the X3 sleeps on
    /// Bluetooth it drops the link, and the HID interface disappears from the
    /// system. That is unambiguous, it needs no cooperation from the user, and
    /// it cannot be confused with a still hand.
    ///
    /// Over the 2.4 GHz receiver the dongle stays enumerated no matter what the
    /// mouse does, so this technique does not work there and the command says
    /// so rather than producing a number.
    static func sleep(_ options: Options) {
        let minutes = options.positionals[safe: 1].flatMap(Int.init) ?? 1
        let patience = Double(minutes) * 60 * 3 + 180

        func mousePresent() -> Bool {
            HID.attackSharkDevices().contains {
                $0.transport.lowercased().contains("bluetooth")
            }
        }

        guard mousePresent() else {
            print("""
                This measurement needs the mouse on Bluetooth.

                It works by watching for the link to drop, which is a real state
                change. Over the 2.4 GHz receiver the dongle stays enumerated
                whatever the mouse is doing, so there is nothing to observe —
                and measuring "no reports arriving" instead would just be
                measuring how long you kept your hand still.
                """)
            return
        }

        print("""
            Sleep timer — measurement

            Setting sleep to \(minutes) minute(s), then waiting for the mouse to
            drop its Bluetooth link. Nudge it once to start the clock, then leave
            it completely alone — do not touch the mouse or the desk.

            Up to \(Int(patience / 60)) minutes. A drop close to \(minutes)
            minute(s) confirms the setting is applied.

            """)

        let report = LightReport.build(
            mode: .off,
            sleepMinutes: UInt8(clamping: minutes),
            deepSleepMinutes: UInt8(clamping: options.deepSleepMinutes ?? 60),
            keyDebounceMs: UInt8(clamping: options.debounceMs ?? 10))
        guard sendReports([report], options) else {
            print("could not write the setting — stopping")
            return
        }

        let devices = candidateDevices(options).filter { $0.maxInputReportSize > 0 }
        guard !devices.isEmpty else {
            print("no input interface to watch")
            return
        }

        print("waiting for you to nudge the mouse…")
        var lastActivity: Date?
        let deadline = Date().addingTimeInterval(patience)

        while Date() < deadline {
            // Enumeration is the state signal; input reports only tell us when
            // the user last touched it, which is the clock's starting point.
            if !mousePresent() {
                guard let started = lastActivity else {
                    print("  link dropped before the clock started — nudge it and retry")
                    return
                }
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: """

                    RESULT: the Bluetooth link dropped %.1f minutes after the last
                    activity, against a %d minute setting.
                    """, elapsed / 60, minutes))
                if abs(elapsed / 60 - Double(minutes)) < max(0.5, Double(minutes) * 0.3) {
                    print("\n  CONFIRMED — that matches the setting.")
                } else {
                    print("""

                      That does not match the setting. Re-run with a different
                      value: if the drop happens at the same time regardless,
                      the sleep field is not being applied and the device is
                      using a fixed timeout of its own.
                    """)
                }
                return
            }

            let watcher = InputWatcher(devices: devices, keepSamples: 0, quiet: true)
            let count = watcher.run(seconds: 5).reduce(0) { $0 + $1.count }
            if count > 0 {
                if lastActivity == nil { print("  clock started") }
                lastActivity = Date()
            } else if let started = lastActivity {
                let idle = Date().timeIntervalSince(started)
                print(String(format: "  idle %.1f min — link still up", idle / 60))
            }
        }

        print("""

            RESULT: the link stayed up for the whole \(Int(patience / 60)) minutes.
            Either the sleep setting is not applied, or this mouse does not drop
            the link when it sleeps — in which case sleep is real but invisible
            to this method.
            """)
    }
}
