import Foundation
import IOKit
import IOKit.hid

/// Listening to input reports.
///
/// The vendor software never calls `GetFeature` — configuration is write-only,
/// and everything the device has to say comes back as HID *input* reports
/// (`Open_DevMonitor` in `hiddriver.dll` reads them and posts window messages).
/// So this is the only readback channel that exists.
///
/// It also gives us an objective way to verify a polling-rate change: at 125 Hz
/// a moving mouse emits roughly an eighth as many reports per second as it does
/// at 1000 Hz. No readback required — just count.
final class InputWatcher {

    struct Channel {
        let info: HIDDeviceRef
        var count = 0
        var firstSeen: Date?
        var lastSeen: Date?
        var samples: [[UInt8]] = []
        /// Monotonic arrival times, nanoseconds. Gaps between consecutive
        /// reports are what actually reveal the polling rate.
        var arrivalsNs: [UInt64] = []
        /// Accumulated absolute sensor counts. Over a *fixed physical
        /// distance* these are directly proportional to DPI, which is the only
        /// way to measure DPI on a device that cannot be read back.
        var countsX = 0
        var countsY = 0
        /// Angle snap forces small off-axis motion to exactly zero, so the
        /// fraction of moving reports that are perfectly axis-locked is a much
        /// sharper signal than the y/x ratio -- and unlike the ratio, it does
        /// not depend on how the user happened to move.
        var movingReports = 0
        var axisLockedReports = 0
        /// Reports during *fast* horizontal motion (|dx| >= 5), and how many of
        /// those had dy exactly 0. Restricting to fast motion controls for the
        /// fact that slow motion produces zero-deltas on its own.
        var fastHorizontal = 0
        var fastHorizontalFlat = 0
        /// Angle snap hard-zeroes the minor axis rather than merely reducing
        /// it, so the sharpest signature is a long *unbroken* run of dy == 0
        /// while x is still moving. Natural hand tremor breaks such a run
        /// within a few reports; snapping sustains it for as long as the
        /// stroke stays near-axis. This is far more robust than any average,
        /// which gets swamped by how the user happened to move.
        var longestFlatRun = 0
        var currentFlatRun = 0
        var maxAbsDy = 0
        /// Ripple control is a smoothing filter, so its signature is that
        /// consecutive deltas become more similar. We track the mean absolute
        /// first difference of dx alongside the mean absolute dx; the ratio is
        /// dimensionless and speed-normalised, which is what makes it usable
        /// against freehand motion.
        var sumAbsDx = 0
        var sumAbsDeltaDx = 0
        var deltaSamples = 0
        var previousDx: Int16?
        /// Jitter also shows up as dy flipping sign; smoothing suppresses that.
        var dySignReversals = 0
        var previousDySign = 0
        /// Motion sync aligns sensor sampling to the polling interval, so its
        /// signature is *uniformity of the sampling window*: at a steady hand
        /// speed each report should carry a similar displacement, and few polls
        /// should come back empty. Neither is what roughness measures, so these
        /// will not simply re-detect ripple control.
        var totalReports = 0
        var zeroMotionReports = 0
        var magnitudeSum = 0.0
        var magnitudeSquaredSum = 0.0
        var magnitudeCount = 0
        /// Magnitudes kept for lag-1 autocorrelation. Aliasing between the
        /// sensor's sample clock and the poll clock produces an alternating
        /// large/small beat, i.e. *negative* lag-1 autocorrelation. Motion sync
        /// is supposed to remove exactly that, so this targets the mechanism
        /// rather than generic smoothness.
        var magnitudes: [Double] = []
    }

    private var channels: [Channel] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var opened: [IOHIDDevice] = []
    private let keepSamples: Int
    private let quiet: Bool
    private let dumpAll: Bool

    init(devices: [HIDDeviceRef], keepSamples: Int = 4, quiet: Bool = false, dumpAll: Bool = false) {
        self.dumpAll = dumpAll
        self.channels = devices.map { Channel(info: $0) }
        self.keepSamples = keepSamples
        self.quiet = quiet
    }

    deinit {
        for device in opened {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for buffer in buffers { buffer.deallocate() }
    }

    /// Listen for `seconds`, then return the per-interface tallies.
    func run(seconds: TimeInterval) -> [Channel] {
        guard let runLoop = CFRunLoopGetCurrent() else { return channels }

        for index in channels.indices {
            let info = channels[index].info
            let device = info.device

            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            else {
                if !quiet {
                    print("  (could not open \(info.descriptorText) — skipping)")
                }
                continue
            }
            opened.append(device)

            let size = max(info.maxInputReportSize, 8)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buffer.initialize(repeating: 0, count: size)
            buffers.append(buffer)

            // `self` outlives the run loop below, so an unretained pointer is safe.
            let context = Unmanaged.passUnretained(self).toOpaque()

            IOHIDDeviceRegisterInputReportCallback(
                device, buffer, size,
                { context, result, sender, _, reportID, report, reportLength in
                    guard result == kIOReturnSuccess, let context, let sender else { return }
                    let watcher = Unmanaged<InputWatcher>.fromOpaque(context)
                        .takeUnretainedValue()
                    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                    // macOS already includes the report ID as byte 0 for
                    // numbered reports -- prepending it again corrupts every
                    // offset and made the status reports unparseable.
                    let bytes = [UInt8](
                        UnsafeBufferPointer(start: report, count: max(0, reportLength)))
                    watcher.record(device: device, bytes: bytes)
                },
                context
            )

            IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }

        guard !opened.isEmpty else { return channels }

        CFRunLoopRunInMode(.defaultMode, seconds, false)

        for device in opened {
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        return channels
    }

    fileprivate func record(device: IOHIDDevice, bytes: [UInt8]) {
        guard let index = channels.firstIndex(where: { $0.info.device === device }) else { return }
        let now = Date()
        if channels[index].firstSeen == nil { channels[index].firstSeen = now }
        channels[index].lastSeen = now
        channels[index].count += 1
        channels[index].arrivalsNs.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        // Two layouts. The 2.4GHz boot-mouse report has no report ID and is
        // 7 bytes: buttons, int16 dx, int16 dy, wheel. The Bluetooth report is
        // 8 bytes and *does* carry a leading report ID (0x02), shifting every
        // field by one. Reading the BLE form with the USB offsets makes the
        // button byte look like movement.
        let base = (bytes.count >= 8 && bytes[0] == 0x02) ? 1 : 0
        if bytes.count >= base + 5 { channels[index].totalReports += 1 }
        if bytes.count >= base + 5 {
            let dx = Int16(
                bitPattern: UInt16(bytes[base + 1]) | UInt16(bytes[base + 2]) << 8)
            let dy = Int16(
                bitPattern: UInt16(bytes[base + 3]) | UInt16(bytes[base + 4]) << 8)
            channels[index].countsX += abs(Int(dx))
            channels[index].countsY += abs(Int(dy))
            if dx == 0 && dy == 0 {
                channels[index].zeroMotionReports += 1
            } else {
                let magnitude = (Double(Int(dx) * Int(dx) + Int(dy) * Int(dy))).squareRoot()
                channels[index].magnitudeSum += magnitude
                channels[index].magnitudeSquaredSum += magnitude * magnitude
                channels[index].magnitudeCount += 1
                if channels[index].magnitudes.count < 20000 {
                    channels[index].magnitudes.append(magnitude)
                }
            }
            if dx != 0 || dy != 0 {
                channels[index].movingReports += 1
                if dx == 0 || dy == 0 { channels[index].axisLockedReports += 1 }
            }
            if abs(Int(dx)) >= 5 {
                channels[index].fastHorizontal += 1
                if dy == 0 { channels[index].fastHorizontalFlat += 1 }
            }
            if dx != 0 {
                channels[index].sumAbsDx += abs(Int(dx))
                if let previous = channels[index].previousDx {
                    channels[index].sumAbsDeltaDx += abs(Int(dx) - Int(previous))
                    channels[index].deltaSamples += 1
                }
                channels[index].previousDx = dx
            }
            if dy != 0 {
                let sign = dy > 0 ? 1 : -1
                if channels[index].previousDySign != 0,
                    sign != channels[index].previousDySign {
                    channels[index].dySignReversals += 1
                }
                channels[index].previousDySign = sign
            }
            if dx != 0 {
                if dy == 0 {
                    channels[index].currentFlatRun += 1
                    channels[index].longestFlatRun = max(
                        channels[index].longestFlatRun, channels[index].currentFlatRun)
                } else {
                    channels[index].currentFlatRun = 0
                }
                channels[index].maxAbsDy = max(channels[index].maxAbsDy, abs(Int(dy)))
            }
        }
        if channels[index].samples.count < keepSamples {
            channels[index].samples.append(bytes)
        }
        // Non-movement interfaces are low-traffic, so dumping every report is
        // how status events (battery, DPI-stage change) get identified.
        if dumpAll {
            print("  \(Hex.encode(bytes))")
        }
    }
}

extension InputWatcher.Channel {
    /// Naive average over the whole capture. This conflates polling rate with
    /// how much the mouse was actually moved, so it is only useful as a rough
    /// activity indicator -- prefer `pollingRateHz`.
    var ratePerSecond: Double? {
        guard let first = firstSeen, let last = lastSeen, count > 1 else { return nil }
        let span = last.timeIntervalSince(first)
        guard span > 0.05 else { return nil }
        return Double(count - 1) / span
    }

    /// Gaps between consecutive reports, in milliseconds.
    var gapsMs: [Double] {
        guard arrivalsNs.count > 1 else { return [] }
        return zip(arrivalsNs.dropFirst(), arrivalsNs).map {
            Double($0 &- $1) / 1_000_000.0
        }
    }

    /// The polling rate, measured robustly.
    ///
    /// A mouse only reports while it is moving, so the average rate over a
    /// capture mostly measures how much the user moved it. The *interval
    /// between consecutive reports during motion* is the real signal: it sits
    /// at 1/rate (8 ms at 125 Hz, 1 ms at 1000 Hz) and is unaffected by idle
    /// stretches. We take the median of the sub-50 ms gaps, which ignores the
    /// pauses while staying robust to jitter.
    var pollingRateHz: Double? {
        let active = gapsMs.filter { $0 > 0.05 && $0 < 50 }.sorted()
        guard active.count >= 10 else { return nil }
        let median = active[active.count / 2]
        guard median > 0 else { return nil }
        return 1000.0 / median
    }

    /// Mean |dx[i] - dx[i-1]| divided by mean |dx|. Lower means a smoother
    /// stream. Dimensionless, so it survives differences in how fast the mouse
    /// was moved.
    var roughness: Double? {
        guard deltaSamples > 50, sumAbsDx > 0 else { return nil }
        let meanDelta = Double(sumAbsDeltaDx) / Double(deltaSamples)
        let meanDx = Double(sumAbsDx) / Double(deltaSamples)
        guard meanDx > 0 else { return nil }
        return meanDelta / meanDx
    }

    /// Fraction of moving reports where dy flips sign -- raw jitter.
    var dyReversalRate: Double? {
        guard movingReports > 50 else { return nil }
        return Double(dySignReversals) / Double(movingReports)
    }

    /// Coefficient of variation of per-report displacement. Lower means more
    /// uniform sampling windows.
    var displacementCV: Double? {
        guard magnitudeCount > 100 else { return nil }
        let n = Double(magnitudeCount)
        let mean = magnitudeSum / n
        guard mean > 0 else { return nil }
        let variance = max(0, magnitudeSquaredSum / n - mean * mean)
        return variance.squareRoot() / mean
    }

    /// Lag-1 autocorrelation of per-report displacement.
    ///
    /// Negative values indicate an alternating beat -- the signature of the
    /// sensor sample clock aliasing against the poll clock. Motion sync should
    /// push this toward zero or positive.
    var lag1Autocorrelation: Double? {
        guard magnitudes.count > 200 else { return nil }
        let n = Double(magnitudes.count)
        let mean = magnitudes.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for index in magnitudes.indices {
            let centred = magnitudes[index] - mean
            denominator += centred * centred
            if index > 0 { numerator += centred * (magnitudes[index - 1] - mean) }
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// Fraction of reports that carried no motion at all.
    var zeroMotionRate: Double? {
        guard totalReports > 100 else { return nil }
        return Double(zeroMotionReports) / Double(totalReports)
    }

    var medianGapMs: Double? {
        let active = gapsMs.filter { $0 > 0.05 && $0 < 50 }.sorted()
        guard active.count >= 10 else { return nil }
        return active[active.count / 2]
    }
}
