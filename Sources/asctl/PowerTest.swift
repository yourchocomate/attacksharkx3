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
        // Three points, not two. A/B confirms *that* a floor exists; a sweep
        // shows how it scales, which is what says whether the wire unit is a
        // millisecond or something else. One measured floor cannot tell those
        // apart, and this protocol has already produced several confident
        // conclusions from a single observation that did not survive.
        let settings = options.colours?
            .split(separator: ",").compactMap { Int($0) } ?? [5, 15, 25]

        print("""
            Key debounce — sweep over \(settings.map(String.init).joined(separator: ", ")) ms

            \(Int(seconds)) seconds per setting. Click the LEFT button as fast
            and as briefly as you can — flick it, do not hold it. You do not need
            superhuman speed: what matters is whether your fastest taps hit a
            wall, not how fast they are.

            Keep the mouse moving very slightly while you click. It only reports
            when something changes, and continuous reporting is what gives the
            measurement its resolution.

            """)

        var rows: [(ms: Int, floor: Double, spread: Double, gapFloor: Double, n: Int)] = []
        var worstSampling = 0.0

        for ms in settings {
            print("── setting debounce to \(ms) ms")
            let payload = LightReport.build(
                mode: .off,
                sleepMinutes: UInt8(clamping: options.sleepMinutes ?? 10),
                deepSleepMinutes: UInt8(clamping: options.deepSleepMinutes ?? 10),
                keyDebounceMs: UInt8(clamping: ms))
            guard sendReports([payload], options) else {
                print("could not write the setting — stopping")
                return
            }
            print("   settled. Click now, fast and brief, for \(Int(seconds))s…")
            Thread.sleep(forTimeInterval: 1.5)

            let (durations, gaps, minGap, medianGap) = collectClicks(
                seconds: seconds, options: options)
            printClickStats(
                durations: durations, gaps: gaps, minGap: minGap, medianGap: medianGap)
            worstSampling = max(worstSampling, minGap)

            let sorted = durations.sorted()
            guard let floor = sorted.first else {
                print("   no clicks captured — cannot use this point\n")
                continue
            }
            let head = sorted.prefix(5)
            rows.append((
                ms, floor, (head.last ?? floor) - floor, gaps.min() ?? 0, sorted.count))
            if ms != settings.last { print("\n   pausing 3s\n"); Thread.sleep(forTimeInterval: 3) }
        }

        print("\n── results")
        print("  setting   shortest press   spread of 5   shortest gap   presses")
        for row in rows {
            print(String(format: "  %5d ms   %11.1f ms   %9.1f ms   %10.1f ms   %7d",
                         row.ms, row.floor, row.spread, row.gapFloor, row.n))
        }
        print(String(format: "\n  coarsest sampling seen: %.2f ms", worstSampling))

        guard rows.count >= 2 else {
            print("  not enough usable points")
            return
        }

        // A floor only counts as measured if the fastest presses pile up
        // against it. Where the setting is below what a hand can produce, the
        // limit is the tester, not the device — those points say nothing and
        // must be excluded rather than fitted.
        let walled = rows.filter { $0.spread < 6 }
        guard !walled.isEmpty else {
            print("""

                  INCONCLUSIVE — no setting produced a wall. Every distribution
                  is as wide at the bottom as human clicking makes it, so no
                  floor was ever reached.
                """)
            return
        }

        print("\n  points where the fastest presses hit a wall:")
        var ratios: [Double] = []
        for row in walled {
            let ratio = row.floor / Double(row.ms)
            ratios.append(ratio)
            print(String(format: "    %2d ms setting -> %.1f ms floor   (%.2fx)",
                         row.ms, row.floor, ratio))
        }

        let mean = ratios.reduce(0, +) / Double(ratios.count)
        let spread = (ratios.max() ?? mean) - (ratios.min() ?? mean)

        print(String(format: """

              CONFIRMED — key debounce is applied. The fastest presses truncate
              against a limit instead of spreading out, which is what a floor
              does and what merely clicking slower does not.

              Floor = %.2f x the configured value%@.
            """, mean, spread < 0.25 ? ", consistently across settings"
                                     : String(format: " (varying %.2f between points)", spread)))

        if abs(mean - 2) < 0.25 && ratios.count >= 2 {
            print("""

                  A consistent 2x says the wire value is not milliseconds: the
                  field counts 2 ms units, so the vendor's "2-25 ms" slider is
                  really 4-50 ms. Treat the label as the vendor's, not the
                  device's.
                """)
        } else if ratios.count < 2 {
            print("""

                  Only one setting produced a wall, so the scaling is a single
                  point. Re-run including a lower setting you can still out-click
                  to confirm it holds.
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
