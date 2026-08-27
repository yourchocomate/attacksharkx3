import CoreBluetooth
import Foundation

/// Bluetooth configuration over GATT.
///
/// Over Bluetooth the X3 exposes **no HID feature reports at all** (max feature
/// report size 1), so configuration cannot use the same path as the 2.4GHz
/// receiver. The vendor software bypasses HID entirely and writes to a GATT
/// characteristic instead — `X3.exe` imports `BluetoothApis.dll` and calls
/// `BluetoothGATTGetServices` → `BluetoothGATTGetCharacteristics` →
/// `BluetoothGATTBeginReliableWrite` → `BluetoothGATTSetCharacteristicValue` →
/// `BluetoothGATTEndReliableWrite` (0x00405d40–0x00405fb0).
///
/// The characteristic it selects is filtered by UUID at 0x00405f10
/// (`cmp dword [ebx-0x16], 0xfee3`), and a second path at 0x004067d0 matches
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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private(set) var batteryPercent: Int?

    private var poweredOn = false
    private var discovered = false
    private var servicesPending = 0

    /// Everything found, for reporting.
    private(set) var foundPeripherals: [(CBPeripheral, [CBUUID])] = []
    private(set) var notifications: [[UInt8]] = []
    private(set) var lastError: String?
    private var writeError: String?
    private var writeCompleted = false

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
    func discover(timeout: TimeInterval = 8) -> Bool {
        guard wait(5, until: { self.poweredOn }) else {
            lastError = "Bluetooth is not powered on or not permitted"
            return false
        }

        for peripheral in central.retrieveConnectedPeripherals(
            withServices: Self.candidateServices)
        {
            foundPeripherals.append((peripheral, []))
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
        peripheral.readValue(for: characteristic)
        wait(timeout) { self.batteryPercent != nil }
        return batteryPercent
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
        guard !foundPeripherals.contains(where: { $0.0.identifier == peripheral.identifier })
        else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        foundPeripherals.append((peripheral, services))
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
            batteryPercent = data.first.map(Int.init)
            return
        }
        notifications.append([UInt8](data))
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
