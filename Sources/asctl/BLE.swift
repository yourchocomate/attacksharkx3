import CoreBluetooth
import Foundation

/// Bluetooth configuration over GATT.
///
/// Over Bluetooth the X3 exposes **no HID feature reports at all** (max feature
/// report size 1), so configuration cannot use the same path as the 2.4GHz
/// receiver. The vendor software bypasses HID entirely and writes to a GATT
/// characteristic instead — the vendor software uses the Windows GATT API,
/// `BluetoothGATTGetServices` → `BluetoothGATTGetCharacteristics` →
/// `BluetoothGATTBeginReliableWrite` → `BluetoothGATTSetCharacteristicValue` →
/// `BluetoothGATTEndReliableWrite`.
///
/// The characteristic it selects is filtered by UUID
/// (`cmp dword [ebx-0x16], 0xfee3`), and a second path matches
/// `0xfee4` for notifications:
///
///     0xFEE3   write   host → device configuration
///     0xFEE4   notify  device → host status
///
/// The payload is the same logical report buffer used over USB: the vendor
/// copies `n` bytes into a `{DataSize, Data[]}` structure and writes it whole.
final class BLEConnection: NSObject {
    static let writeUUID = CBUUID(string: "FEE3")
    static let notifyUUID = CBUUID(string: "FEE4")
    /// Standard Bluetooth SIG Battery Service / Battery Level. The X3 exposes
    /// these over BLE even though it reports battery nowhere on the 2.4GHz
    /// path, and macOS does not surface it in `system_profiler`.
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelUUID = CBUUID(string: "2A19")
    /// Services worth asking the system about when looking for an already
    /// connected mouse. 0x1812 is HID over GATT; the FEEx range is where these
    /// vendor services live.
    static let candidateServices = [
        CBUUID(string: "1812"), CBUUID(string: "FEE0"),
        CBUUID(string: "FEE1"), CBUUID(string: "FEE7"),
    ]

    /// Guards every property below that is touched from more than one queue.
    ///
    /// This is not defensive tidying. `CBCentralManager` is created with
    /// `queue: nil`, so all delegate callbacks arrive on the **main** queue,
    /// while the GUI's status listener drains `notifications` and reads the
    /// battery from a **background** queue. Appending to a Swift array on one
    /// thread while another clears it is undefined behaviour — it drops
    /// packets and returns torn values, which is exactly what a listener that
    /// misses events and a battery level that will not settle look like.
    private let lock = NSLock()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var _batteryPercent: Int?
    var batteryPercent: Int? { locked { _batteryPercent } }
    /// The raw bytes 2A19 returned, kept for diagnosis. A battery level that
    /// looks wrong is almost always the wrong characteristic on the wrong
    /// device, and the only way to tell is to look at what actually arrived.
    private var _batteryRaw: [UInt8] = []
    var batteryRaw: [UInt8] { locked { _batteryRaw } }
    private(set) var connectedName: String?

    private var _poweredOn = false
    private var poweredOn: Bool {
        get { locked { _poweredOn } }
        set { locked { _poweredOn = newValue } }
    }
    private var _discovered = false
    private var discovered: Bool {
        get { locked { _discovered } }
        set { locked { _discovered = newValue } }
    }
    private var _servicesPending = 0
    private var servicesPending: Int {
        get { locked { _servicesPending } }
        set { locked { _servicesPending = newValue } }
    }

    /// Everything found, for reporting.
    private var _foundPeripherals: [(CBPeripheral, [CBUUID])] = []
    var foundPeripherals: [(CBPeripheral, [CBUUID])] { locked { _foundPeripherals } }
    private var _notifications: [[UInt8]] = []
    var notifications: [[UInt8]] { locked { _notifications } }
    private var _lastError: String?
    var lastError: String? {
        get { locked { _lastError } }
        set { locked { _lastError = newValue } }
    }
    private var _writeError: String?
    private var writeError: String? {
        get { locked { _writeError } }
        set { locked { _writeError = newValue } }
    }
    private var _writeCompleted = false
    private var writeCompleted: Bool {
        get { locked { _writeCompleted } }
        set { locked { _writeCompleted = newValue } }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Pump the run loop until `condition` holds or the timeout expires.
    @discardableResult
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Find the mouse: prefer peripherals the system already has connected,
    /// then fall back to scanning.
    /// Whether Bluetooth is usable before we touch CoreBluetooth.
    ///
    /// Creating a CBCentralManager when TCC will refuse does not fail — it
    /// terminates the process with SIGABRT. Checking the authorization first
    /// turns a crash into a message for the cases it can see.
    ///
    /// It cannot see every case: TCC attributes a request to the *responsible*
    /// process, so an app launched from another program is judged by that
    /// program's Info.plist, and the crash happens before any of our code runs.
    /// Launching the app normally is the only fix for that one.
    static var authorizationProblem: String? {
        switch CBManager.authorization {
        case .denied:
            return "Bluetooth access was denied — grant it to asctl in "
                + "System Settings ▸ Privacy & Security ▸ Bluetooth"
        case .restricted:
            return "Bluetooth access is restricted on this Mac"
        default:
            return nil
        }
    }

    func discover(timeout: TimeInterval = 8) -> Bool {
        if let problem = BLEConnection.authorizationProblem {
            lastError = problem
            return false
        }
        guard wait(5, until: { self.poweredOn }) else {
            lastError = "Bluetooth is not powered on or not permitted"
            return false
        }

        for peripheral in central.retrieveConnectedPeripherals(
            withServices: Self.candidateServices)
        {
            locked { _foundPeripherals.append((peripheral, [])) }
        }

        if foundPeripherals.isEmpty {
            central.scanForPeripherals(withServices: nil)
            wait(timeout) { !self.foundPeripherals.isEmpty }
            central.stopScan()
        }
        return !foundPeripherals.isEmpty
    }

    /// Connect and walk the GATT table looking for FEE3 / FEE4.
    func connect(_ target: CBPeripheral, timeout: TimeInterval = 10) -> Bool {
        peripheral = target
        target.delegate = self
        central.connect(target)

        guard wait(timeout, until: { target.state == .connected }) else {
            lastError = "could not connect to \(target.name ?? "peripheral")"
            return false
        }
        connectedName = target.name
        target.discoverServices(nil)
        wait(timeout) { self.discovered && self.servicesPending == 0 }
        return writeCharacteristic != nil
    }

    /// Enable notifications on FEE4.
    ///
    /// Many BLE peripherals ignore commands until the host has subscribed to
    /// the matching notify characteristic — the vendor app registers for
    /// events (`BluetoothGATTRegisterEvent`) as part of its setup, so this
    /// mirrors that.
    func subscribe(timeout: TimeInterval = 3) -> Bool {
        guard let peripheral, let characteristic = notifyCharacteristic else {
            return false
        }
        peripheral.setNotifyValue(true, for: characteristic)
        return wait(timeout) { characteristic.isNotifying }
    }

    /// Write one config buffer to the FEE3 characteristic.
    ///
    /// Returns false and sets `lastError` if the peripheral reports a GATT
    /// error, rather than assuming success the way an unchecked write does.
    func write(_ bytes: [UInt8]) -> Bool {
        guard let peripheral, let characteristic = writeCharacteristic else {
            lastError = "no FEE3 write characteristic on this device"
            return false
        }
        let maxLength = peripheral.maximumWriteValueLength(for: .withResponse)
        if bytes.count > maxLength {
            lastError = "payload \(bytes.count) bytes exceeds the negotiated "
                + "maximum of \(maxLength)"
        }

        writeError = nil
        writeCompleted = false
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)

        if type == .withResponse {
            guard wait(4, until: { self.writeCompleted }) else {
                lastError = "no write response from the device"
                return false
            }
            if let writeError {
                lastError = writeError
                return false
            }
        } else {
            wait(0.4) { false }
        }
        return true
    }

    /// Largest single write the connection will carry.
    var maximumWriteLength: Int {
        peripheral?.maximumWriteValueLength(for: .withResponse) ?? 0
    }

    /// Read the standard Battery Level characteristic (0-100 percent).
    func readBattery(timeout: TimeInterval = 5) -> Int? {
        guard let peripheral, let characteristic = batteryCharacteristic else {
            lastError = "this device exposes no 2A19 Battery Level characteristic"
            return nil
        }
        // Clear first. Without this the wait below is satisfied immediately by
        // the previous reading and every read after the first returns a stale
        // value that never updates.
        locked {
            _batteryPercent = nil
            _batteryRaw = []
        }
        peripheral.readValue(for: characteristic)
        wait(timeout) { self.batteryPercent != nil }
        return batteryPercent
    }

    /// Whether the link has dropped underneath us.
    var isDisconnected: Bool {
        guard let peripheral else { return true }
        return peripheral.state != .connected
    }

    /// Take everything received since the last call, clearing the buffer.
    func takeNotifications() -> [[UInt8]] {
        locked {
            let batch = _notifications
            _notifications.removeAll()
            return batch
        }
    }

    /// Pump the run loop briefly so queued notifications are delivered.
    func pump(seconds: TimeInterval) {
        wait(seconds) { false }
    }

    /// Drop the link. Without this the connection lingers until the central
    /// manager is deallocated, which makes repeated reads unpredictable.
    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func listen(seconds: TimeInterval) {
        if let peripheral, let characteristic = notifyCharacteristic {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        wait(seconds) { false }
    }

    /// Human-readable dump of the GATT table, for diagnosis.
    func describeServices() -> [String] {
        guard let peripheral, let services = peripheral.services else { return [] }
        var lines: [String] = []
        for service in services {
            lines.append("service \(service.uuid.uuidString)")
            for characteristic in service.characteristics ?? [] {
                var props: [String] = []
                if characteristic.properties.contains(.read) { props.append("read") }
                if characteristic.properties.contains(.write) { props.append("write") }
                if characteristic.properties.contains(.writeWithoutResponse) {
                    props.append("writeNoResp")
                }
                if characteristic.properties.contains(.notify) { props.append("notify") }
                let mark = characteristic.uuid == Self.writeUUID ? "  <- config write"
                    : (characteristic.uuid == Self.notifyUUID ? "  <- status notify" : "")
                lines.append(
                    "  char \(characteristic.uuid.uuidString)  [\(props.joined(separator: ","))]\(mark)")
            }
        }
        return lines
    }
}

extension BLEConnection: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        poweredOn = central.state == .poweredOn
        if central.state == .unauthorized {
            lastError = "Bluetooth permission denied for this process"
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        locked {
            guard !_foundPeripherals.contains(where: {
                $0.0.identifier == peripheral.identifier
            }) else { return }
            _foundPeripherals.append((peripheral, services))
        }
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        lastError = error?.localizedDescription ?? "connection failed"
    }
}

extension BLEConnection: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        servicesPending = services.count
        discovered = true
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if services.isEmpty { servicesPending = 0 }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.writeUUID { writeCharacteristic = characteristic }
            if characteristic.uuid == Self.notifyUUID { notifyCharacteristic = characteristic }
            if characteristic.uuid == Self.batteryLevelUUID {
                batteryCharacteristic = characteristic
            }
        }
        servicesPending = max(0, servicesPending - 1)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == Self.batteryLevelUUID {
            // Battery Level is a single unsigned byte, 0-100 percent.
            locked {
                _batteryRaw = [UInt8](data)
                _batteryPercent = data.first.map(Int.init)
            }
            return
        }
        locked { _notifications.append([UInt8](data)) }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        writeCompleted = true
        if let error {
            writeError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }
}
