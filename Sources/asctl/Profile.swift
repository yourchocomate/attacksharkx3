import Foundation

/// Application-side profiles.
///
/// The device has firmware support for five profile slots — the status channel
/// emits `0x8000` "profile changed" events and `profile_cycle` (action 0x34) is
/// a real button action — but **this product never populates them**. Two pieces
/// of evidence, together conclusive:
///
/// 1. Every report builder hardcodes byte 2 to `1`. Nothing ever selects
///    another slot.
/// 2. The sender has exactly six callers — the 0x0C preamble and
///    reports 0x04, 0x05, 0x06, 0x08, 0x09. None of the profile buttons (add,
///    delete, rename, import, export, reset) is among them.
///
/// Confirmed on hardware: writing report 0x04 with byte 2 = 2 is acknowledged
/// but changes nothing, and `profile_cycle` reports profile 0 indefinitely
/// without switching configuration.
///
/// So the vendor's "profiles" are files on the host that get replayed to the
/// device through the same six reports. This does the same thing.
struct Profile: Codable {
    var dpiStages: [Int]?
    /// **Zero-based** index of the active slot.
    ///
    /// Stated because it was ambiguous: `asctl profile save --active` takes a
    /// 1-based number from the user, and the GUI holds a 0-based index. Storing
    /// whichever the caller happened to have meant the same file meant
    /// different things depending on who wrote it. The file format is 0-based;
    /// the CLI converts at its boundary.
    var activeStage: Int?
    /// Per-slot enablement. Report 0x04 addresses eight slots by index and
    /// carries enablement as a bitmask, so a profile that stored only the
    /// enabled stages would not round-trip a gap in the middle.
    var stageEnabled: [Bool]?
    var colours: [[Int]]?
    var pollingRateHz: Int?
    var buttons: [String]?
    var liftOff2mm: Bool?
    var rippleControl: Bool?
    var angleSnap: Bool?
    var motionSync: Bool?
    var sleepMinutes: Int?
    var deepSleepMinutes: Int?
    var debounceMs: Int?

    static var directory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/asctl/profiles", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    static func load(_ name: String) throws -> Profile {
        let data = try Data(contentsOf: url(name))
        return try JSONDecoder().decode(Profile.self, from: data)
    }

    func save(as name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Profile.url(name))
    }

    static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    var summary: [String] {
        var lines: [String] = []
        if let stages = dpiStages {
            lines.append("DPI: \(stages.map(String.init).joined(separator: ", "))"
                + (activeStage.map { " (stage \($0) active)" } ?? ""))
        }
        if let hz = pollingRateHz { lines.append("polling rate: \(hz) Hz") }
        if let buttons { lines.append("buttons: \(buttons.joined(separator: ", "))") }
        var toggles: [String] = []
        if liftOff2mm == true { toggles.append("lift-off 2mm") }
        if rippleControl == true { toggles.append("ripple") }
        if angleSnap == true { toggles.append("angle snap") }
        if motionSync == true { toggles.append("motion sync") }
        if !toggles.isEmpty { lines.append("toggles: \(toggles.joined(separator: ", "))") }
        if let sleepMinutes { lines.append("sleep: \(sleepMinutes) min") }
        if let deepSleepMinutes { lines.append("deep sleep: \(deepSleepMinutes) min") }
        if let debounceMs { lines.append("debounce: \(debounceMs) ms") }
        return lines
    }
}
