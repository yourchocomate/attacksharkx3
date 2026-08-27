import Foundation
import IOKit
import IOKit.hid

// MARK: - Errors

enum HIDError: Error, CustomStringConvertible {
    case noDeviceFound
    case openFailed(IOReturn)
    case setReportFailed(IOReturn)
    case getReportFailed(IOReturn)

    var description: String {
        switch self {
        case .noDeviceFound:
            return "no matching HID device found"
        case .openFailed(let r):
            return "IOHIDDeviceOpen failed: \(ioReturnDescription(r))"
        case .setReportFailed(let r):
            return "IOHIDDeviceSetReport failed: \(ioReturnDescription(r))"
        case .getReportFailed(let r):
            return "IOHIDDeviceGetReport failed: \(ioReturnDescription(r))"
        }
    }
}

/// `kUSBHostReturnPipeStalled` — the device STALLed the control transfer.
/// Not exposed by the IOKit HID headers, so it is spelled out here.
let kUSBHostReturnPipeStalled: IOReturn = IOReturn(bitPattern: 0xE000_5000)

/// Translate the IOReturn codes we actually hit into something actionable.
/// `kIOReturnNotPermitted` in particular is the one users will meet first: macOS
/// gates HID access behind Input Monitoring for anything that looks like a
/// keyboard or mouse.
func ioReturnDescription(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: return "success"
    case kIOReturnNotPermitted:
        return "not permitted (0xE00002E2) — grant Input Monitoring to your terminal in "
            + "System Settings ▸ Privacy & Security ▸ Input Monitoring, or run with sudo"
    case kIOReturnExclusiveAccess:
        return "exclusive access (0xE00002C5) — another process holds the device"
    case kIOReturnUnsupported:
        return "unsupported (0xE00002C7) — this interface has no such report"
    case kIOReturnNoDevice: return "no device (0xE00002C0)"
    case kIOReturnNotOpen: return "not open (0xE00002CD)"
    case kIOReturnBadArgument: return "bad argument (0xE00002C2)"
    case kIOReturnTimeout: return "timeout (0xE00002D6)"
    case kIOReturnAborted: return "aborted (0xE00002EB)"
    case kIOReturnNotFound:
        return "not found (0xE00002F0) - this interface has no such report ID; "
            + "the Bluetooth interface exposes no configuration reports at all"
    case kUSBHostReturnPipeStalled:
        return "pipe stalled (0xE0005000) — the device rejected the transfer; "
            + "often transient on the first write after idle"
    default: return String(format: "0x%08X", UInt32(bitPattern: r))
    }
}

// MARK: - Device info

struct HIDDeviceRef {
    let device: IOHIDDevice
    let vendorID: Int
    let productID: Int
    let product: String
    let manufacturer: String
    let serialNumber: String
    let usagePage: Int
    let usage: Int
    let transport: String
    let locationID: Int
    let maxInputReportSize: Int
    let maxOutputReportSize: Int
    let maxFeatureReportSize: Int
    let reportDescriptor: Data?

    /// Vendor-defined usage pages (0xFF00–0xFFFF) are where configuration
    /// collections live. The mouse's own Generic Desktop collection is the
    /// boring one that just reports movement.
    var isVendorCollection: Bool { usagePage >= 0xFF00 }

    /// Whether this interface can actually carry configuration reports.
    ///
    /// The 2.4GHz receiver's config collection reports 262 bytes; the Bluetooth
    /// interface reports 1, which cannot hold even the smallest config report.
    /// Checking this up front turns a bare `kIOReturnNotFound` into an
    /// explanation the user can act on.
    var canConfigure: Bool { maxFeatureReportSize >= 16 }

    var descriptorText: String {
        let vendorTag = isVendorCollection ? "  [vendor-defined]" : ""
        return String(
            format: "%04X:%04X  usage %02X:%02X  %@  feat=%d in=%d  %@%@",
            vendorID, productID, usagePage, usage,
            transport.isEmpty ? "?" : transport,
            maxFeatureReportSize, maxInputReportSize,
            product.isEmpty ? "(unnamed)" : product,
            vendorTag
        )
    }
}

// MARK: - Enumeration

enum HID {
    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }

    /// Every HID device currently attached, wrapped with the properties we care about.
    static func allDevices() -> [HIDDeviceRef] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        return set.map { device in
            HIDDeviceRef(
                device: device,
                vendorID: intProperty(device, kIOHIDVendorIDKey),
                productID: intProperty(device, kIOHIDProductIDKey),
                product: stringProperty(device, kIOHIDProductKey),
                manufacturer: stringProperty(device, kIOHIDManufacturerKey),
                serialNumber: stringProperty(device, kIOHIDSerialNumberKey),
                usagePage: intProperty(device, kIOHIDPrimaryUsagePageKey),
                usage: intProperty(device, kIOHIDPrimaryUsageKey),
                transport: stringProperty(device, kIOHIDTransportKey),
                locationID: intProperty(device, kIOHIDLocationIDKey),
                maxInputReportSize: intProperty(device, kIOHIDMaxInputReportSizeKey),
                maxOutputReportSize: intProperty(device, kIOHIDMaxOutputReportSizeKey),
                maxFeatureReportSize: intProperty(device, kIOHIDMaxFeatureReportSizeKey),
                reportDescriptor: IOHIDDeviceGetProperty(
                    device, kIOHIDReportDescriptorKey as CFString) as? Data
            )
        }
        .sorted {
            ($0.vendorID, $0.productID, $0.usagePage, $0.usage)
                < ($1.vendorID, $1.productID, $1.usagePage, $1.usage)
        }
    }

    /// Devices whose VID/PID match a known Attack Shark X3 identity.
    static func attackSharkDevices() -> [HIDDeviceRef] {
        allDevices().filter { KnownDevices.matches(vendorID: $0.vendorID, productID: $0.productID) }
    }

    /// Pick the interface that the Windows software talks to.
    ///
    /// X3.exe drives configuration over HID *feature* reports, so we want the
    /// collection that actually exposes them, preferring a vendor-defined
    /// collection over the plain mouse one.
    static func selectConfigInterface(_ candidates: [HIDDeviceRef]) -> HIDDeviceRef? {
        let usable = candidates.filter { $0.maxFeatureReportSize > 0 }
        let pool = usable.isEmpty ? candidates : usable
        return pool.sorted { lhs, rhs in
            if lhs.isVendorCollection != rhs.isVendorCollection { return lhs.isVendorCollection }
            return lhs.maxFeatureReportSize > rhs.maxFeatureReportSize
        }.first
    }
}

// MARK: - An opened device

/// A handle you can actually exchange feature reports over.
final class HIDConnection {
    let info: HIDDeviceRef
    private var opened = false

    init(_ info: HIDDeviceRef) { self.info = info }

    deinit {
        if opened { IOHIDDeviceClose(info.device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    func open() throws {
        let r = IOHIDDeviceOpen(info.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw HIDError.openFailed(r) }
        opened = true
    }

    /// Send a feature report.
    ///
    /// `payload[0]` is the report ID, matching the Windows `HidD_SetFeature`
    /// convention the original driver uses — and matching what hidapi's macOS
    /// backend does, so byte layouts carry over from the Windows software
    /// unchanged.
    func setFeature(_ payload: [UInt8]) throws {
        guard let reportID = payload.first else { return }
        let r = IOHIDDeviceSetReport(
            info.device,
            kIOHIDReportTypeFeature,
            CFIndex(reportID),
            payload,
            payload.count
        )
        guard r == kIOReturnSuccess else { throw HIDError.setReportFailed(r) }
    }

    /// Send a feature report, retrying once past the transient stall the device
    /// issues on the first control transfer after it has been idle.
    ///
    /// This matters for correctness, not just tidiness: the preamble and the
    /// command that follows it must *both* land, and a silently-stalled
    /// preamble leaves the command to be ignored.
    func setFeatureRetrying(_ payload: [UInt8], attempts: Int = 3) throws {
        var lastError: Error?
        for _ in 0..<max(1, attempts) {
            do {
                try setFeature(payload)
                return
            } catch HIDError.setReportFailed(let code) where code == kUSBHostReturnPipeStalled {
                lastError = HIDError.setReportFailed(code)
                continue
            }
        }
        throw lastError ?? HIDError.setReportFailed(kIOReturnError)
    }

    /// Read a feature report. Returns the bytes the device actually produced,
    /// including the leading report ID.
    func getFeature(reportID: UInt8, length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        buffer[0] = reportID
        var actual = length
        let r = IOHIDDeviceGetReport(
            info.device,
            kIOHIDReportTypeFeature,
            CFIndex(reportID),
            &buffer,
            &actual
        )
        guard r == kIOReturnSuccess else { throw HIDError.getReportFailed(r) }
        return Array(buffer.prefix(max(0, min(actual, length))))
    }
}
