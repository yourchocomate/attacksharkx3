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
            // Explicit loop: the chained zip/map/filter form exceeded the
            // compiler's type-checking budget on another toolchain.
            var gaps: [Double] = []
            let arrivals = channel.arrivalsNs
            if arrivals.count > 1 {
                gaps.reserveCapacity(arrivals.count - 1)
                for index in 1..<arrivals.count {
                    let delta = Double(arrivals[index] - arrivals[index - 1]) / 1_000_000
                    if delta > 0.05 && delta < 500 { gaps.append(delta) }
                }
                gaps.sort()
            }
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

    private static func finish(elapsed: TimeInterval, minutes: Int, how: String) {
        print(String(format: """

            RESULT: %@ %.1f minutes after the last activity, against a %d minute
            setting.
            """, how, elapsed / 60, minutes))
        if abs(elapsed / 60 - Double(minutes)) < max(0.5, Double(minutes) * 0.3) {
            print("\n  CONFIRMED — that matches the setting.")
        } else {
            print("""

              That does not match the setting. Re-run with a different value: if
              the same time comes back regardless, the sleep field is not being
              applied and the device is using a fixed timeout of its own.
            """)
        }
    }

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
        let patience = options.autoSeconds ?? (Double(minutes) * 60 * 3 + 180)

        func mousePresent() -> Bool {
            HID.attackSharkDevices().contains {
                $0.transport.lowercased().contains("bluetooth")
            }
        }

        let onBluetooth = mousePresent()
        if !onBluetooth {
            print("""
                On the 2.4 GHz receiver, so watching the status channel.

                The device carries an awake flag: status event 0x4010 is
                `03 10 40 <awake> <level>`, where an awake byte of zero is the
                state the vendor app labels "Device Sleep!". That event has
                never been observed firing in this project, so this run tests
                two things at once — whether the sleep setting is applied, and
                whether 0x4010 exists at all.

                """)
        }

        print("""
            Sleep timer — measurement

            Setting sleep to \(minutes) minute(s), then waiting for the mouse to
            say or show that it has slept.

            The clock starts NOW and resets on any movement. Just stop touching
            the mouse and the desk. There is nothing to do to begin.

            Watching for: \(onBluetooth
                ? "the Bluetooth link dropping"
                : "status event 0x4010 with its awake byte at zero").

            Up to \(Int(patience / 60)) minutes. A result close to \(minutes)
            minute(s) confirms the setting is applied.

            """)

        // Set **both** timers. Report 0x05 carries a sleep timer and a deep
        // sleep timer, and an earlier version of this test pinned deep sleep at
        // 60 minutes while sweeping sleep — so if the device only powers down on
        // the deeper timer, nothing could ever have been observed. Testing one
        // timer while holding the other wide open measures nothing.
        let report = LightReport.build(
            mode: .off,
            sleepMinutes: UInt8(clamping: minutes),
            deepSleepMinutes: UInt8(clamping: options.deepSleepMinutes ?? minutes),
            keyDebounceMs: UInt8(clamping: options.debounceMs ?? 10))
        guard sendReports([report], options) else {
            print("could not write the setting — stopping")
            return
        }
        print("   sleep = \(minutes) min, deep sleep = "
            + "\(options.deepSleepMinutes ?? minutes) min")

        let devices = candidateDevices(options).filter { $0.maxInputReportSize > 0 }
        guard !devices.isEmpty else {
            print("no input interface to watch")
            return
        }

        print("watching \(devices.count) interface(s):")
        for device in devices { print("   \(device.descriptorText)") }
        print("\nclock running — stop touching the mouse.\n")

        // The clock starts now and resets on movement, rather than waiting for
        // the user to start it. A first version required a nudge *after* the
        // prompt appeared; the tester, having been told firmly not to touch the
        // mouse, did not provide one, and the run spent six minutes waiting for
        // a start signal and then reported the silence as a device finding.
        var lastActivity: Date? = Date()
        let deadline = Date().addingTimeInterval(patience)
        var lastNote = Date.distantPast

        while Date() < deadline {
            // Over Bluetooth the link dropping is the signal; the interface
            // disappears from the system.
            if onBluetooth && !mousePresent() {
                guard let started = lastActivity else { return }
                finish(elapsed: Date().timeIntervalSince(started),
                       minutes: minutes, how: "the Bluetooth link dropped")
                return
            }

            let watcher = InputWatcher(devices: devices, keepSamples: 256, quiet: true)
            let channels = watcher.run(seconds: 5)

            // A status event is a statement by the device about its own state,
            // which is far better evidence than silence.
            for channel in channels {
                for sample in channel.samples {
                    guard let event = StatusEvent.parse(sample) else { continue }
                    if event.code == 0x4010 {
                        let awake = event.value & 0xFF
                        print("  \(Hex.encode(sample))   0x4010 awake=\(awake) "
                            + "level=\(event.value >> 8)")
                        if awake == 0, let started = lastActivity {
                            finish(elapsed: Date().timeIntervalSince(started),
                                   minutes: minutes,
                                   how: "the device reported itself asleep (0x4010)")
                            return
                        }
                    } else {
                        print("  \(Hex.encode(sample))   \(event.description)")
                    }
                }
            }

            let motion = channels.reduce(0) { $0 + $1.count }
            if motion > 0 {
                if let started = lastActivity,
                   Date().timeIntervalSince(started) > 20 {
                    print(String(format: "  movement after %.1f min idle — clock reset",
                                 Date().timeIntervalSince(started) / 60))
                }
                lastActivity = Date()
            } else if let started = lastActivity, Date().timeIntervalSince(lastNote) > 25 {
                lastNote = Date()
                print(String(format: "  idle %.1f min — still awake",
                             Date().timeIntervalSince(started) / 60))
            }
        }

        print("""

            RESULT: nothing observable happened in \(Int(patience / 60)) minutes.

            No 0x4010 event arrived and, on Bluetooth, the link stayed up.

            Check the idle lines above first: if the clock kept resetting, the
            mouse was being disturbed and this measured nothing. If it counted
            cleanly past \(minutes) minute(s), then either the sleep field is not
            applied, or the device sleeps without announcing it and without
            dropping its link — in which case sleep is real but invisible to
            this method, and wake latency is the next thing to try.
            """)
    }

    // MARK: Wake latency

    /// Whether the device was asleep, measured by how it *starts* reporting.
    ///
    /// The link-drop test came back clean-null: six idle minutes with sleep set
    /// to 1 and the Bluetooth link never dropped, no 0x4010 event. That leaves
    /// two readings it cannot separate — the field is not applied, or the device
    /// sleeps silently and keeps its link.
    ///
    /// This separates them without needing the device to announce anything. A
    /// radio coming out of a low-power state does not resume at full rate
    /// instantly: the first reports after a wake are spaced more widely than the
    /// steady-state interval, and they tighten up over the first few tens of
    /// milliseconds. A device that never slept reports at its normal interval
    /// from the very first packet.
    ///
    /// So the observable is the **shape of the first twenty inter-report gaps**,
    /// which needs no timestamp from the tester and therefore carries none of
    /// their reaction time.
    static func wake(_ options: Options) {
        let minutes = options.positionals[safe: 1].flatMap(Int.init) ?? 1

        print("""
            Wake latency — is the device sleeping at all?

            Two captures of how the mouse *starts* reporting: once when it has
            been active all along, and once after \(minutes) idle minute(s). A
            radio resuming from low power spaces its first packets more widely
            than its steady state; one that never slept reports normally from the
            first packet.

            Nothing to time by hand — the measurement is the gap pattern itself.

            """)

        // Both timers, for the reason given in sleep(): holding deep sleep at
        // 60 while sweeping sleep tests nothing if the deeper timer is the one
        // that actually powers the radio down.
        let payload = LightReport.build(
            mode: .off,
            sleepMinutes: UInt8(clamping: minutes),
            deepSleepMinutes: UInt8(clamping: options.deepSleepMinutes ?? minutes),
            keyDebounceMs: UInt8(clamping: options.debounceMs ?? 10))
        guard sendReports([payload], options) else {
            print("could not write the setting — stopping")
            return
        }
        print("   sleep = \(minutes) min, deep sleep = "
            + "\(options.deepSleepMinutes ?? minutes) min")

        print("\n── control: mouse already awake")
        print("   move the mouse continuously for a few seconds…")
        Thread.sleep(forTimeInterval: 2)
        guard let control = firstGaps(options: options, seconds: 12) else {
            print("   no motion captured — move the mouse when asked")
            return
        }
        describe("control", control)

        print("\n── now leave the mouse completely alone for \(minutes + 1) minute(s)")
        let idleUntil = Date().addingTimeInterval(Double(minutes + 1) * 60)
        while Date() < idleUntil {
            Thread.sleep(forTimeInterval: 15)
            let left = idleUntil.timeIntervalSinceNow
            if left > 0 { print(String(format: "   %.1f min left…", left / 60)) }
        }

        print("\n   NOW move the mouse — one smooth continuous movement.")
        guard let woken = firstGaps(options: options, seconds: 20) else {
            print("   no motion captured")
            return
        }
        describe("after idle", woken)

        print("\n── comparison")
        let controlHead = control.prefix(5).reduce(0, +) / 5
        let wokenHead = woken.prefix(5).reduce(0, +) / 5
        print(String(format: "  mean of the first five gaps: %.2f ms awake, %.2f ms after idle",
                     controlHead, wokenHead))

        if wokenHead > controlHead * 2.5 && wokenHead > 20 {
            print("""

                  SLEPT. The first packets after idling are spaced far more
                  widely than when the mouse was already active, which is a
                  radio resuming from a low-power state. Sleep is real on this
                  device — it simply neither announces it nor drops the link.
                """)
        } else {
            print("""

                  NO WAKE SIGNATURE. The mouse starts reporting the same way
                  after idling as when it was already active, so nothing here
                  suggests it slept at all.

                  Combined with the link staying up and no 0x4010, the weight of
                  evidence is that the sleep field is not applied — or that its
                  unit is not minutes, which the debounce field's 2 ms units
                  make a live possibility. Re-run with a much larger value
                  before concluding.
                """)
        }
    }

    /// The first inter-report gaps once motion starts.
    private static func firstGaps(options: Options, seconds: Double) -> [Double]? {
        let devices = candidateDevices(options).filter { $0.maxInputReportSize > 0 }
        guard !devices.isEmpty else { return nil }
        let watcher = InputWatcher(devices: devices, keepSamples: 0, quiet: true)
        let channels = watcher.run(seconds: seconds)

        for channel in channels where channel.arrivalsNs.count > 6 {
            var gaps: [Double] = []
            let arrivals = channel.arrivalsNs
            gaps.reserveCapacity(arrivals.count - 1)
            for index in 1..<arrivals.count {
                gaps.append(Double(arrivals[index] - arrivals[index - 1]) / 1_000_000)
            }
            return Array(gaps.prefix(20))
        }
        return nil
    }

    private static func describe(_ label: String, _ gaps: [Double]) {
        let shown = gaps.prefix(10).map { String(format: "%.1f", $0) }
        print("   \(label): first gaps \(shown.joined(separator: ", ")) ms")
    }
}
