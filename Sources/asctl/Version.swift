import Foundation

/// The version this build reports, and how to compare two of them.
///
/// One source of truth: `CFBundleShortVersionString` in `Sources/asctl/Info.plist`.
/// The release workflow stamps it from the git tag before building, so a tagged
/// build and its tag cannot disagree — they used to, and v0.2.0 shipped a file
/// called `asctl-0.1.0.dmg` because the plist was edited by hand and drifted.
///
/// The same plist reaches both products. The app bundle gets a copy at
/// `Contents/Info.plist`, and the CLI has it linked into `__TEXT,__info_plist`
/// by the linker (see Package.swift), which is why a bare binary can still
/// answer `asctl --version`.
enum AppVersion {
    static var current: String { string(forKey: "CFBundleShortVersionString") ?? "0.0.0" }
    static var build: String { string(forKey: "CFBundleVersion") ?? "0" }

    private static func string(forKey key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }

    /// Compare two dotted versions numerically, so 0.10.0 beats 0.9.0.
    ///
    /// A string comparison gets that backwards, and an updater that thinks the
    /// newest release is older than what is installed simply never offers it.
    /// Anything after the numbers — `-beta`, `+build` — is ignored: it does not
    /// change which release is newer for our purposes, and pretending to
    /// implement the full semver precedence rules would be inventing behaviour
    /// nothing here relies on.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numbers(lhs)
        let right = numbers(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    /// Leading numeric components. `v0.2.0` and `0.2.0-beta.1` both give [0,2,0].
    private static func numbers(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let core = trimmed.prefix { $0.isNumber || $0 == "." }
        return core.split(separator: ".").compactMap { Int($0) }
    }
}
