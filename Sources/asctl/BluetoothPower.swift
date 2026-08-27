import Foundation

/// Toggle the Mac's Bluetooth controller off and on.
///
/// This exists for one reason: the X3 intermittently reconnects over Bluetooth
/// with its buttons working and its sensor dead. Every configuration report the
/// protocol has — including report 0x04, which programs the sensor itself — is
/// delivered and acknowledged in that state, and none of them restarts it. The
/// only thing that does is tearing the Bluetooth link down completely.
///
/// That makes it a firmware fault in the mouse rather than something `asctl`
/// can properly fix. This is a convenience wrapper around the workaround, not
/// a solution.
enum BluetoothPower {
    /// `IOBluetoothPreferenceSetControllerPowerState` is not in IOBluetooth's
    /// public headers, so it is resolved at runtime instead of linked. If it
    /// ever disappears we fall back to `blueutil` rather than crashing.
    private typealias SetPowerState = @convention(c) (Int32) -> Int32
    private typealias GetPowerState = @convention(c) () -> Int32

    /// The framework handle is opened once and deliberately never closed —
    /// the power-state call is asynchronous, and unloading the framework while
    /// it is still settling is a good way to lose the transition.
    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Current controller power state, or nil if it cannot be read.
    static func isPoweredOn() -> Bool? {
        guard let get = symbol(
            "IOBluetoothPreferenceGetControllerPowerState", as: GetPowerState.self)
        else { return nil }
        return get() != 0
    }

    /// Set the power state and **wait until the controller actually reports it**.
    ///
    /// The setter is asynchronous and returns long before the transition
    /// completes. An earlier version called it once and assumed success, which
    /// could leave Bluetooth switched off — the worst possible outcome for a
    /// command whose whole job is to switch it back on.
    private static func setAndVerify(_ on: Bool, timeout: TimeInterval = 10) -> Bool {
        guard let set = symbol(
            "IOBluetoothPreferenceSetControllerPowerState", as: SetPowerState.self)
        else { return blueutil(on) }

        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        while Date() < deadline {
            if isPoweredOn() == on { return true }
            // Re-issue periodically: the first request is sometimes dropped
            // while the controller is still settling from a previous change.
            if attempts % 8 == 0 { _ = set(on ? 1 : 0) }
            attempts += 1
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }
        if isPoweredOn() == on { return true }
        return blueutil(on)
    }

    /// Fallback for when the private symbol is unavailable or ineffective.
    private static func blueutil(_ on: Bool) -> Bool {
        let candidates = ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
        guard let tool = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-p", on ? "1" : "0"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Cycle Bluetooth off, pause, and back on.
    static func cycle() -> Bool {
        if isPoweredOn() == false {
            print("Bluetooth is already off — turning it back on.")
            if setAndVerify(true) {
                print("done — Bluetooth is on again.")
                return true
            }
            FileHandle.standardError.write(Data(
                "error: could not turn Bluetooth on. Use the menu bar.\n".utf8))
            return false
        }

        print("turning Bluetooth off…")
        guard setAndVerify(false) else {
            FileHandle.standardError.write(Data("""
                error: could not control the Bluetooth controller.

                Install blueutil and retry:
                  brew install blueutil

                Or toggle Bluetooth by hand in the menu bar.

                """.utf8))
            return false
        }
        // The controller needs a moment down for the mouse to fully drop.
        Thread.sleep(forTimeInterval: 2.0)
        print("turning Bluetooth back on…")
        guard setAndVerify(true) else {
            let message = "error: Bluetooth was turned off but could not be "
                + "turned back on. Use the menu bar.\n"
            FileHandle.standardError.write(Data(message.utf8))
            return false
        }
        print("done — the mouse should reconnect in a few seconds.")
        return true
    }
}
