import Foundation

/// Listens to the device→host status channel and reports what changes.
///
/// This is the one direction in which the mouse tells us anything. The
/// configuration protocol is write-only, so the editor can never read a setting
/// back — but the device *volunteers* a small set of events, and a DPI-button
/// press is one of them. That makes the active stage the single piece of live
/// device state the UI can actually track rather than assume.
///
/// Both transports carry it, in slightly different frames:
///
/// - **2.4 GHz / USB** — input report `0x03` on the configuration interface:
///   `03 <code-lo> <code-hi> <value-lo> <value-hi>`. A stage change through a
///   five-stage ladder was observed as `03 00 10 01 00` … `03 00 10 05 00`.
/// - **Bluetooth** — a FEE4 notification carrying the same four payload bytes
///   with no report ID. Confirmed by the write acknowledgements, which arrive
///   as `10 50 00 0C` where 2.4 GHz reports `03 10 50 00 0C`.
///
/// The Bluetooth path for `0x1000` specifically has **not** been seen on
/// hardware yet — the acknowledgement events prove the channel works, and the
/// decoding is shared, but that is an inference until a DPI press is observed
/// over Bluetooth. The monitor logs whatever arrives so it can be checked.
@available(macOS 12.0, *)
final class StatusMonitor {
    /// Called on the main queue for every decoded event.
    var onEvent: ((StatusEvent.Event, [UInt8]) -> Void)?
    /// Called on the main queue when a battery level arrives, so a live
    /// connection can serve it instead of reconnecting per read.
    var onBattery: ((Int, [UInt8], String) -> Void)?
    /// Called on the main queue whenever the listener actually connects or
    /// drops.
    ///
    /// This has to be reported rather than assumed. Setting a "running" flag
    /// optimistically and routing battery reads through it meant that when the
    /// connection failed, every read went to a listener that was not there and
    /// the gauge simply stayed blank.
    var onConnectionChange: ((Bool) -> Void)?
    /// Called when the battery could not be read on this connection.
    var onBatteryFailed: ((String) -> Void)?
    /// Called when an attempt fails and another is scheduled.
    var onRetry: ((Int, TimeInterval) -> Void)?

    private var running = false
    /// Bumped on every start, so a loop from a previous start exits instead of
    /// running forever.
    ///
    /// The queue is serial: a restart used to enqueue a second block behind a
    /// first that was still inside an eight-second scan. When the first block
    /// finished its pass it saw `running` true again — set by the restart — and
    /// looped, so the second block never got the queue and the first never
    /// noticed it had been superseded.
    private var generation = 0
    private(set) var connected = false
    private let queue = DispatchQueue(label: "asctl.status", qos: .utility)

    /// Whether 2A19 has been read since the mouse last powered up.
    ///
    /// This has to outlive a single connection. It was a local inside the BLE
    /// loop, so every reconnect read the characteristic again — and because
    /// reading increments it, a link that re-establishes periodically walks the
    /// level up by one each time. Observed directly: a clean 100 at 1:07,
    /// then 101 at 1:08, with nobody having asked for either.
    ///
    /// Cleared only when the mouse disappears from the device list, which is
    /// the one signal available that it has been switched off — and a power
    /// cycle is exactly when a fresh read is both safe and correct.
    private var batteryCaptured = false

    func allowBatteryRead() { batteryCaptured = false }

    func stop() { running = false }


    func start(link: GUITransport.Link) {
        guard !running else { return }
        running = true
        generation += 1
        let mine = generation
        queue.async { [weak self] in
            guard let self else { return }
            // Retry until told to stop.
            //
            // A single failed attempt used to end the listener for good: the
            // Bluetooth path returns when discovery or connect fails, and
            // nothing tried again. On a cold app launch the mouse is often not
            // discoverable for the first second or two, so the listener died
            // before the device was ready and the battery and DPI stage stayed
            // blank for the whole session.
            var attempt = 0
            while self.running && self.generation == mine {
                switch link {
                case .receiver: self.runHID(mine: mine)
                case .bluetooth: self.runBLE(mine: mine)
                }
                self.setConnected(false)
                guard self.running, self.generation == mine else { break }
                attempt += 1
                // Back off gently, but keep trying — a mouse switched off and
                // on again should be picked up without the user doing anything.
                let delay = min(10.0, 2.0 * Double(min(attempt, 5)))
                DispatchQueue.main.async { self.onRetry?(attempt, delay) }
                Thread.sleep(forTimeInterval: delay)
            }
            self.setConnected(false)
        }
    }

    // MARK: 2.4 GHz / USB

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        DispatchQueue.main.async { self.onConnectionChange?(value) }
    }

    private func runHID(mine: Int) {
        while running && generation == mine {
            let devices = HID.attackSharkDevices().filter { $0.canConfigure }
            guard !devices.isEmpty else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            // Short windows rather than one long one, so stopping is responsive
            // and a re-enumeration (which a polling-rate change causes) is
            // picked up on the next pass.
            setConnected(true)
            let watcher = InputWatcher(devices: devices, keepSamples: 256, quiet: true)
            for channel in watcher.run(seconds: 2) {
                for sample in channel.samples {
                    guard let event = StatusEvent.parse(sample) else { continue }
                    emit(event, sample)
                }
            }
        }
    }

    // MARK: Bluetooth

    /// One long-lived connection, rather than a fresh one per operation.
    ///
    /// Connecting per read was churning the link — and since the battery read
    /// rides the same connection, holding it open removes a whole class of
    /// inconsistent readings.
    private func runBLE(mine: Int) {
        let ble = BLEConnection()
        defer { ble.disconnect() }

        guard ble.discover() else {
            DispatchQueue.main.async {
                self.onBatteryFailed?(ble.lastError ?? "could not scan for the mouse")
            }
            setConnected(false)
            return
        }
        guard let target = ble.foundPeripherals.map({ $0.0 }).first(where: GUITransport.isX3)
        else {
            DispatchQueue.main.async {
                self.onBatteryFailed?("the mouse was not among the peripherals found")
            }
            setConnected(false)
            return
        }
        guard ble.connect(target), ble.subscribe() else {
            DispatchQueue.main.async {
                self.onBatteryFailed?(ble.lastError ?? "could not open the GATT link")
            }
            setConnected(false)
            return
        }
        setConnected(true)

        // One read of GATT 2A19 per link, and never a second.
        //
        // The characteristic holds a real level, but reading it increments it:
        // three reads inside a tenth of a second moved it 186 → 188, while
        // thirty idle seconds moved it not at all. So the first read after the
        // device powers up is the true level and every read after that is
        // damage — the run that began at 75 was a genuine 75% followed by four
        // self-inflicted increments.
        //
        // This is what macOS does, and why its figure stays right while ours
        // climbed: it reads once when the link comes up and caches the result.
        // Measured — asking macOS for the battery five times advanced the
        // counter by nothing at all, while one read of our own advanced it by
        // one.
        //
        // The previous version retried up to eight times and rejected anything
        // over 100, so a spoiled value triggered more reads, which spoiled it
        // further. Retry only when nothing came back: a read that times out
        // was never answered and so consumes nothing.
        var batteryAttempts = 0

        while running && generation == mine {
            if !batteryCaptured && batteryAttempts < 5 {
                batteryAttempts += 1
                if let level = ble.readBattery() {
                    batteryCaptured = true
                    let raw = ble.batteryRaw
                    let name = ble.connectedName ?? "?"
                    DispatchQueue.main.async { self.onBattery?(level, raw, name) }
                } else if batteryAttempts == 5 {
                    let reason = ble.lastError ?? "the read was never answered"
                    DispatchQueue.main.async { self.onBatteryFailed?(reason) }
                }
            }
            ble.pump(seconds: 1.0)
            for packet in ble.takeNotifications() {
                guard let event = StatusEvent.parseBLE(packet) else { continue }
                emit(event, packet)
            }
            if ble.isDisconnected {
                setConnected(false)
                return
            }
        }
    }

    private func emit(_ event: StatusEvent.Event, _ raw: [UInt8]) {
        DispatchQueue.main.async { self.onEvent?(event, raw) }
    }
}
