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

            let (durations, gaps) = collectClicks(seconds: seconds, options: options)
            results.append((ms, durations, gaps))
            printClickStats(durations: durations, gaps: gaps)
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
    ) -> (durations: [Double], gaps: [Double]) {
        let devices = candidateDevices(options).filter { $0.maxInputReportSize > 0 }
        guard !devices.isEmpty else { return ([], []) }

        let watcher = InputWatcher(devices: devices, keepSamples: 0, quiet: true)
        let channels = watcher.run(seconds: seconds)

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
        return (durations, gaps)
    }

    private static func printClickStats(durations: [Double], gaps: [Double]) {
        guard !durations.isEmpty else {
            print("   no clicks captured")
            return
        }
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

    /// Sleep is a timeout on inactivity, so the observable is when the device
    /// stops reporting after being left alone.
    ///
    /// Over Bluetooth the link drops, which is unambiguous. Over the receiver
    /// the interface stays enumerated and simply goes quiet, so what is
    /// measured there is the silence itself.
    static func sleep(_ options: Options) {
        let minutes = options.positionals[safe: 1].flatMap(Int.init) ?? 1
        let patience = Double(minutes) * 60 * 2.5 + 120

        print("""
            Sleep timer — measurement

            Setting sleep to \(minutes) minute(s), then watching for the device
            to go quiet. Give it a nudge to start, then DO NOT TOUCH the mouse.

            Expect this to take up to \(Int(patience / 60)) minutes. A result
            close to \(minutes) minute(s) confirms the setting is applied; a
            device that never goes quiet means it is not.

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
        print("watching \(devices[0].descriptorText)")
        print("move the mouse once to start the clock, then leave it alone.\n")

        var lastActivity = Date()
        var sawAnything = false
        let deadline = Date().addingTimeInterval(patience)
        var quietSince: Date?

        while Date() < deadline {
            let watcher = InputWatcher(devices: devices, keepSamples: 0, quiet: true)
            let channels = watcher.run(seconds: 5)
            let count = channels.reduce(0) { $0 + $1.count }

            if count > 0 {
                if !sawAnything {
                    sawAnything = true
                    print("  clock started")
                }
                lastActivity = Date()
                quietSince = nil
            } else if sawAnything {
                if quietSince == nil { quietSince = Date() }
                let idle = Date().timeIntervalSince(lastActivity)
                print(String(format: "  quiet for %.0fs (idle %.1f min)",
                             Date().timeIntervalSince(quietSince!), idle / 60))
                // Two minutes of complete silence is the device asleep rather
                // than a still hand: an awake mouse emits reports on the
                // slightest movement, and a desk is never perfectly still.
                if Date().timeIntervalSince(quietSince!) > 120 {
                    let total = quietSince!.timeIntervalSince(lastActivity) + 120
                    print(String(format: """

                        RESULT: the device went quiet %.1f minutes after the last
                        activity, against a %d minute setting.
                        """, total / 60, minutes))
                    return
                }
            }
        }
        print("""

            RESULT: the device never went quiet within \(Int(patience / 60)) minutes.
            Either the sleep setting is not being applied, or something kept
            waking it. Check that nothing was touching the mouse or the desk.
            """)
    }
}
