import Foundation

/// Where asctl keeps things on disk.
///
/// Collected in one place because the uninstaller has to know all of it, and a
/// path duplicated between the app and a shell script is a path that will
/// eventually disagree with itself.
enum AppPaths {
    /// Profiles and the record of the last configuration written.
    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/asctl", isDirectory: true)
    }

    static var profilesDirectory: URL {
        configDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    static var lastAppliedFile: URL {
        configDirectory.appendingPathComponent("last-applied.json")
    }

    /// Window position and similar, written by macOS on our behalf.
    static var preferencesFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Preferences/io.github.yourchocomate.asctl.plist")
    }

    static var configDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: configDirectory.path)
    }

    /// Rough size of the stored data, for telling the user what they would lose.
    static var storedProfileCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }
}
