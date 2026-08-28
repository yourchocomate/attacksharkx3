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
    /// Called when an attempt fails and another is scheduled.
    var onRetry: ((Int, TimeInterval) -> Void)?

    private var running = false
    private var wantsBatteryRead = false
    private(set) var connected = false
    private let queue = DispatchQueue(label: "asctl.status", qos: .utility)

    func stop() { running = false }

    /// Ask the live connection for a battery level. Bluetooth only.
    ///
    /// Deliberately serviced **once per connection**. Re-reading 2A19 on an
    /// open link returns a value one greater every time — measured as
    /// `4B 4C 4D 4E 4F` over five reads — so a second read on the same link is
    /// not a fresh sample of anything.
    func requestBattery() { wantsBatteryRead = true }

    func start(link: GUITransport.Link) {
        guard !running else { return }
        running = true
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
            while self.running {
                switch link {
                case .receiver: self.runHID()
                case .bluetooth: self.runBLE()
                }
                self.setConnected(false)
                guard self.running else { break }
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

    private func runHID() {
        while running {
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
    private func runBLE() {
        let ble = BLEConnection()
        defer { ble.disconnect() }

        guard ble.discover(),
              let target = ble.foundPeripherals.map({ $0.0 }).first(where: GUITransport.isX3),
              ble.connect(target),
              ble.subscribe()
        else {
            setConnected(false)
            return
        }
        setConnected(true)

        // One read, as soon as the link is up. Never again on this connection.
        wantsBatteryRead = true
        var batteryRead = false

        while running {
            ble.pump(seconds: 1.0)
            for packet in ble.takeNotifications() {
                guard let event = StatusEvent.parseBLE(packet) else { continue }
                emit(event, packet)
            }
            if wantsBatteryRead && !batteryRead {
                wantsBatteryRead = false
                batteryRead = true
                if let level = ble.readBattery(), (0...100).contains(level) {
                    let raw = ble.batteryRaw
                    let name = ble.connectedName ?? "?"
                    DispatchQueue.main.async { self.onBattery?(level, raw, name) }
                }
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
