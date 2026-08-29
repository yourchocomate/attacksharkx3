import CryptoKit
import Foundation

/// Check GitHub for a newer release, and install it.
///
/// These builds are ad-hoc signed rather than notarised, so macOS will not
/// vouch for a download and neither can this. What it can do is check the
/// bytes: every release ships `SHA256SUMS.txt`, and the disk image is verified
/// against it before anything is mounted. That catches corruption and a
/// truncated download; it is not a signature and does not prove authorship, so
/// the UI says where the file came from rather than implying it is trusted.
///
/// Nothing here runs without the user asking. There is no background polling
/// and no automatic install.
enum Updater {
    static let repository = "yourchocomate/attacksharkx3"

    struct Release {
        let version: String
        let tag: String
        let notesURL: URL
        let dmg: Asset
        let checksums: Asset?

        struct Asset {
            let name: String
            let url: URL
            let size: Int
        }
    }

    enum Failure: LocalizedError {
        case noRelease
        case noDiskImage(tag: String)
        case badChecksum(expected: String, actual: String)
        case notInstalledAsApp
        case commandFailed(String, Int32)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .noRelease:
                return "no published release found — only drafts, or none yet"
            case .noDiskImage(let tag):
                return "release \(tag) has no .dmg attached"
            case .badChecksum(let expected, let actual):
                return "the download does not match its published checksum "
                    + "(expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
            case .notInstalledAsApp:
                return "this is the command line binary, not the app bundle — "
                    + "replace it by hand, or install the app"
            case .commandFailed(let what, let code):
                return "\(what) failed with status \(code)"
            case .http(let code):
                return "GitHub returned HTTP \(code)"
            }
        }
    }

    // MARK: Checking

    /// Fetch the latest published release. Returns nil when it is not newer.
    ///
    /// `/releases/latest` deliberately skips drafts and pre-releases, so a
    /// release left as a draft is invisible here — which is correct, but worth
    /// knowing when a freshly built release does not show up.
    static func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("asctl/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                return completion(.failure(code == 404 ? Failure.noRelease : Failure.http(code)))
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return completion(.failure(Failure.noRelease)) }

            let assets = (json["assets"] as? [[String: Any]]) ?? []
            func asset(matching test: (String) -> Bool) -> Release.Asset? {
                for entry in assets {
                    guard let name = entry["name"] as? String, test(name),
                          let string = entry["browser_download_url"] as? String,
                          let url = URL(string: string) else { continue }
                    return Release.Asset(
                        name: name, url: url, size: entry["size"] as? Int ?? 0)
                }
                return nil
            }
            guard let dmg = asset(matching: { $0.hasSuffix(".dmg") }) else {
                return completion(.failure(Failure.noDiskImage(tag: tag)))
            }

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let release = Release(
                version: version,
                tag: tag,
                notesURL: URL(string: json["html_url"] as? String ?? "")
                    ?? URL(string: "https://github.com/\(repository)/releases")!,
                dmg: dmg,
                checksums: asset(matching: { $0.hasPrefix("SHA256SUMS") }))

            completion(.success(
                AppVersion.isNewer(version, than: AppVersion.current) ? release : nil))
        }.resume()
    }

    // MARK: Installing

    /// Download, verify, and swap the installed app for the new one.
    ///
    /// `progress` is called on an arbitrary queue with a fraction, or nil while
    /// doing something that has no meaningful percentage.
    static func install(
        _ release: Release,
        progress: @escaping (String, Double?) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let destination = installedBundle() else {
                    throw Failure.notInstalledAsApp
                }
                let work = try FileManager.default.url(
                    for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: destination, create: true)
                defer { try? FileManager.default.removeItem(at: work) }

                progress("downloading \(release.dmg.name)", nil)
                let dmg = try download(release.dmg, into: work)

                if let checksums = release.checksums {
                    progress("checking the download", nil)
                    let sums = try download(checksums, into: work)
                    try verify(dmg, named: release.dmg.name, against: sums)
                } else {
                    progress("no checksums published — skipping verification", nil)
                }

                progress("installing", nil)
                try swap(dmg: dmg, into: destination, work: work)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Where to install. The running bundle if there is one, so an app kept
    /// somewhere other than /Applications updates itself in place.
    static func installedBundle() -> URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private static func download(_ asset: Release.Asset, into directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(asset.name)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?

        var request = URLRequest(url: asset.url)
        request.setValue("asctl/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        URLSession.shared.downloadTask(with: request) { temporary, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                result = .failure(Failure.http(code)); return
            }
            guard let temporary else { result = .failure(Failure.noRelease); return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }.resume()

        semaphore.wait()
        return try result!.get()
    }

    /// Compare the download against the published SHA256SUMS line for it.
    private static func verify(_ file: URL, named name: String, against sums: URL) throws {
        let text = try String(contentsOf: sums, encoding: .utf8)
        var expected: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            // shasum writes "<hash>  <name>", and the name may carry a leading
            // "*" for binary mode or a path prefix.
            let listed = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*./"))
            if listed == name { expected = String(parts[0]); break }
        }
        guard let expected else { return }  // nothing published for this file

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw Failure.badChecksum(expected: expected, actual: actual)
        }
    }

    /// Mount the image, copy the app out, and put it where the old one was.
    ///
    /// The old bundle is moved aside rather than deleted first, so a failure
    /// part-way leaves a working app to go back to instead of a hole where one
    /// used to be. Replacing a running bundle is safe on macOS: the running
    /// image stays mapped from the old inode until the process exits.
    private static func swap(dmg: URL, into destination: URL, work: URL) throws {
        let mount = work.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil",
                ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        let source = mount.appendingPathComponent(destination.lastPathComponent)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw Failure.noDiskImage(tag: destination.lastPathComponent)
        }

        let staged = work.appendingPathComponent("staged.app")
        try run("/usr/bin/ditto", [source.path, staged.path])

        let old = work.appendingPathComponent("previous.app")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: old)
        }
        do {
            try run("/usr/bin/ditto", [staged.path, destination.path])
        } catch {
            // Put the old one back rather than leaving nothing installed.
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: old, to: destination)
            throw error
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw Failure.commandFailed(
                "\(URL(fileURLWithPath: tool).lastPathComponent) \(arguments.first ?? "")",
                task.terminationStatus)
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// Relaunch the freshly installed copy and quit this one.
    ///
    /// Handing the relaunch to a detached shell rather than doing it here: the
    /// new copy must not start until this process has exited, or the
    /// single-instance guard sees us still running and the new one immediately
    /// hands back and quits.
    static func relaunch(_ bundle: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; "
                + "do sleep 0.2; done; open \(shellQuoted(bundle.path))",
        ]
        try? task.run()
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
