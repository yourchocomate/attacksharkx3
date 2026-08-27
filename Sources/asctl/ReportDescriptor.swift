import Foundation

/// A minimal HID report descriptor parser.
///
/// We only need enough of HID 1.11 §6.2.2 to answer one question: which report
/// IDs exist, of which type, and how many bytes does each carry? That tells us
/// exactly which reports are safe to poke at, without guessing.
enum ReportDescriptor {

    enum ReportKind: String {
        case input = "Input"
        case output = "Output"
        case feature = "Feature"
    }

    struct ReportInfo {
        let kind: ReportKind
        let reportID: UInt8
        var bitCount: Int

        /// Byte size on the wire, including the leading report ID byte when the
        /// descriptor uses numbered reports.
        func byteCount(numbered: Bool) -> Int {
            (bitCount + 7) / 8 + (numbered ? 1 : 0)
        }
    }

    struct Parsed {
        var reports: [ReportInfo]
        var usesReportIDs: Bool
        var topLevelUsages: [(page: Int, usage: Int)]
        var items: [String]
    }

    private static let usagePageNames: [Int: String] = [
        0x01: "Generic Desktop",
        0x02: "Simulation",
        0x06: "Generic Device",
        0x07: "Keyboard/Keypad",
        0x08: "LED",
        0x09: "Button",
        0x0C: "Consumer",
        0x0D: "Digitizer",
    ]

    static func usagePageName(_ page: Int) -> String {
        if let name = usagePageNames[page] { return name }
        if page >= 0xFF00 { return "Vendor-defined" }
        return String(format: "0x%04X", page)
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func parse(_ data: Data) -> Parsed {
        let bytes = [UInt8](data)

        var reports: [ReportInfo] = []
        var usesReportIDs = false
        var topLevelUsages: [(page: Int, usage: Int)] = []
        var items: [String] = []

        // Global item state carries across main items.
        var reportSize = 0
        var reportCount = 0
        var currentReportID: UInt8 = 0
        var usagePage = 0
        var pendingUsages: [Int] = []
        var collectionDepth = 0

        var index = 0
        while index < bytes.count {
            let prefix = bytes[index]

            // Long items (0xFE) carry their own size byte; we skip them.
            if prefix == 0xFE {
                guard index + 1 < bytes.count else { break }
                index += Int(bytes[index + 1]) + 3
                continue
            }

            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode
            let type = Int((prefix >> 2) & 0x03)
            let tag = Int((prefix >> 4) & 0x0F)

            guard index + 1 + size <= bytes.count else { break }
            var value = 0
            for offset in 0..<size {
                value |= Int(bytes[index + 1 + offset]) << (8 * offset)
            }
            index += 1 + size

            let indent = String(repeating: "  ", count: collectionDepth)

            switch (type, tag) {
            // ---- Main items ----
            case (0, 8), (0, 9), (0, 11):  // Input / Output / Feature
                let kind: ReportKind = tag == 8 ? .input : (tag == 9 ? .output : .feature)
                let bits = reportSize * reportCount
                if let existing = reports.firstIndex(where: {
                    $0.kind == kind && $0.reportID == currentReportID
                }) {
                    reports[existing].bitCount += bits
                } else {
                    reports.append(
                        ReportInfo(kind: kind, reportID: currentReportID, bitCount: bits))
                }
                items.append(
                    "\(indent)\(kind.rawValue) (\(describeMainItem(value))) "
                        + "size=\(reportSize) count=\(reportCount)")
                pendingUsages.removeAll()

            case (0, 10):  // Collection
                let name =
                    ["Physical", "Application", "Logical", "Report", "Named Array",
                     "Usage Switch", "Usage Modifier"][safe: value] ?? "Vendor"
                if collectionDepth == 0, let usage = pendingUsages.first {
                    topLevelUsages.append((page: usagePage, usage: usage))
                }
                items.append("\(indent)Collection (\(name))")
                collectionDepth += 1
                pendingUsages.removeAll()

            case (0, 12):  // End Collection
                collectionDepth = max(0, collectionDepth - 1)
                items.append("\(String(repeating: "  ", count: collectionDepth))End Collection")

            // ---- Global items ----
            case (1, 0):
                usagePage = value
                items.append(
                    "\(indent)Usage Page (\(usagePageName(value)))")
            case (1, 7):
                reportSize = value
            case (1, 8):
                currentReportID = UInt8(truncatingIfNeeded: value)
                usesReportIDs = true
                items.append("\(indent)Report ID (0x\(String(format: "%02X", value)))")
            case (1, 9):
                reportCount = value

            // ---- Local items ----
            case (2, 0):
                pendingUsages.append(value)

            default:
                break
            }
        }

        return Parsed(
            reports: reports.sorted {
                ($0.kind.rawValue, $0.reportID) < ($1.kind.rawValue, $1.reportID)
            },
            usesReportIDs: usesReportIDs,
            topLevelUsages: topLevelUsages,
            items: items
        )
    }

    private static func describeMainItem(_ value: Int) -> String {
        var flags: [String] = []
        flags.append(value & 0x01 != 0 ? "Const" : "Data")
        flags.append(value & 0x02 != 0 ? "Var" : "Array")
        flags.append(value & 0x04 != 0 ? "Rel" : "Abs")
        return flags.joined(separator: ",")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
