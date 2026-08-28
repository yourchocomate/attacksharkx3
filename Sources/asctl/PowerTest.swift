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
            it. You do not need superhuman speed: what matters is whether your
            fastest taps hit a wall, not how fast they are.

            Keep the mouse moving very slightly while you click. It only reports
            when something changes, and continuous reporting is what gives the
            measurement its resolution.

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

            let (durations, gaps, minGap, medianGap) = collectClicks(
                seconds: seconds, options: options)
            results.append((ms, durations, gaps))
            resolutions.append(minGap)
            printClickStats(
                durations: durations, gaps: gaps, minGap: minGap, medianGap: medianGap)
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

        print(String(format: "  coarsest sampling seen:          %6.1f ms", resolution))

        if resolution > separation / 3 {
            print(String(format: """

                  UNRESOLVABLE. Even at its fastest, this run sampled every
                  %.1f ms, and the two settings differ by %.0f ms. Re-run over
                  the 2.4 GHz receiver after `asctl pollrate 1000`, and keep the
                  mouse moving slightly so it reports continuously.
                """, resolution, separation))
            return
        }

        // A debounce floor does not shift the distribution, it truncates it:
        // the fastest presses pile up against the limit instead of spreading
        // out. Comparing the *shape* near the minimum separates that from a
        // user who simply clicked more slowly the second time.
        func spread(_ values: [Double]) -> Double {
            let head = values.sorted().prefix(5)
            guard let low = head.first, let high = head.last else { return 0 }
            return high - low
        }
        let lowSpread = spread(results[0].durations)
        let highSpread = spread(results[1].durations)

        print(String(format: "  spread of the five shortest:     %6.1f ms at %d ms, "
                     + "%.1f ms at %d ms",
                     lowSpread, results[0].ms, highSpread, results[1].ms))

        let ratio = highMin / Double(results[1].ms)
        let walled = highSpread < lowSpread / 2 && highMin > lowMin * 1.5

        if walled {
            print(String(format: """

                  CONFIRMED — key debounce is applied.

                  At %d ms the fastest presses pile up at %.1f ms within a
                  %.1f ms spread, while at %d ms they spread over %.1f ms and
                  reach %.1f ms. A setting that merely changed nothing would
                  leave both distributions the same shape; truncation at the
                  bottom is what a floor looks like.

                  The floor sits at %.2f times the configured value, which
                  suggests the debounce is applied to both edges — the release
                  cannot register until one interval after the press, and the
                  next press not until one after the release.
                """, results[1].ms, highMin, highSpread,
                     results[0].ms, lowSpread, lowMin, ratio))
        } else if lowMin >= Double(results[1].ms) {
            print("""

                  INCONCLUSIVE — no press was faster than the high setting even
                  at the low one, so the floor was never reached.
                """)
        } else {
            print("""

                  NO EFFECT MEASURED. The two distributions have the same shape
                  near the minimum, so nothing suggests the value is applied.
                """)
        }
    }

    /// Watch the input reports and turn button edges into press durations and
    /// the gaps between presses.
    private static func collectClicks(
        seconds: Double, options: Options
    ) -> (durations: [Double], gaps: [Double], minGapMs: Double, medianGapMs: Double) {
        let devices = candidateDevices(options).filter { $0.maxInputReportSize > 0 }
        guard !devices.isEmpty else { return ([], [], 0, 0) }

        let watcher = InputWatcher(devices: devices, keepSamples: 0, quiet: true)
        let channels = watcher.run(seconds: seconds)

        // A press duration cannot be measured more finely than the interval
        // between input reports. The statistic that matters is the **minimum**
        // gap, not the median: the median is dominated by how much the mouse
        // happened to be moved during the window, so a run with less movement
        // looks like a slower device. Using the median here produced a false
        // "unresolvable" on a run that was sampling at 1 ms.
        var minGap = Double.greatestFiniteMagnitude
        var medianGap = 0.0
        for channel in channels {
            let gaps = zip(channel.arrivalsNs.dropFirst(), channel.arrivalsNs)
                .map { Double($0 - $1) / 1_000_000 }
                .filter { $0 > 0.05 && $0 < 500 }
                .sorted()
            guard !gaps.isEmpty else { continue }
            minGap = min(minGap, gaps[0])
            medianGap = max(medianGap, gaps[gaps.count / 2])
        }
        if minGap == .greatestFiniteMagnitude { minGap = 0 }

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
        return (durations, gaps, minGap, medianGap)
    }

    private static func printClickStats(
        durations: [Double], gaps: [Double], minGap: Double, medianGap: Double
    ) {
        guard !durations.isEmpty else {
            print("   no clicks captured")
            return
        }
        print(String(
            format: "   report interval: fastest %.1f ms, typical %.1f ms "
                + "(the fastest is what limits resolution)",
            minGap, medianGap))
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
