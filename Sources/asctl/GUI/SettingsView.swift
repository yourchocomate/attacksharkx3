import AppKit
import SwiftUI

/// asctl's own settings, as opposed to the mouse's.
///
/// Kept separate from the device panels on purpose: everything else in this
/// window writes to the mouse, and none of this does. Mixing "how the app
/// behaves" into the same accordion as "what the hardware is set to" made it
/// unclear which changes were being sent anywhere.
@available(macOS 12.0, *)
struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                group("Startup") {
                    Toggle("Open asctl at login", isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(!state.canLaunchAtLogin)

                    if state.canLaunchAtLogin {
                        note("One switch for the whole app. asctl opens at login and "
                            + "stays in the menu bar, so everything it does keeps "
                            + "working: the device listener, the DPI-stage and battery "
                            + "readings, and the wheel-direction fix. Closing the window "
                            + "does not stop it — quit from the menu bar item for that.")
                    } else {
                        note("Only the app bundle can be launched at login. Build it "
                            + "with Scripts/make-app.sh and run that instead of the "
                            + "bare binary — a loose executable is identified by its "
                            + "path and loses its permissions on every rebuild.")
                    }
                }

                group("Device listener") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.monitorConnected ? Color.green
                                  : (state.monitorRunning ? Color.orange : Color.secondary))
                            .frame(width: 7, height: 7)
                        Text(state.monitorConnected ? "Connected"
                             : (state.monitorRunning ? "Trying to connect" : "Off"))
                            .font(.system(size: 12))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { state.monitorRunning },
                            set: { $0 ? state.startMonitor() : state.stopMonitor() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    note("The mouse volunteers a small set of events — a DPI-button "
                        + "press among them. That is the only piece of device state "
                        + "this app can read rather than assume, because the "
                        + "configuration protocol is write-only. The listener also "
                        + "carries the battery level on Bluetooth.")
                }

                group("Data") {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppPaths.configDirectory.path)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(AppPaths.configDirectoryExists
                                 ? "\(AppPaths.storedProfileCount) profile(s), plus the "
                                   + "record of the last configuration written"
                                 : "not created yet — it appears when you save a profile "
                                   + "or apply a setting")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [AppPaths.configDirectory])
                        }
                        .disabled(!AppPaths.configDirectoryExists)
                    }
                    note("Profiles live here as plain JSON. Because the mouse cannot be "
                        + "read back, this folder is the only record of a configuration "
                        + "that exists anywhere — worth keeping if you reinstall.")
                }

                group("Uninstalling") {
                    note("Scripts/uninstall.sh removes asctl. It asks whether to keep "
                        + "this folder, so a reinstall can pick up your profiles, or to "
                        + "remove everything. Run it with --keep-data or --all to skip "
                        + "the question.")
                    HStack {
                        Spacer()
                        Button("Reveal uninstaller") {
                            let script = URL(fileURLWithPath: Bundle.main.bundlePath)
                                .deletingLastPathComponent()
                                .appendingPathComponent("uninstall.sh")
                            NSWorkspace.shared.activateFileViewerSelecting([script])
                        }
                    }
                }

                group("Permissions") {
                    permission(
                        "Input Monitoring", granted: !state.devices.isEmpty,
                        why: "Configuring over the 2.4 GHz receiver or the USB cable.")
                    permission(
                        "Bluetooth", granted: state.batteryAvailable && state.monitorConnected,
                        why: "Configuring over GATT, and reading the battery.")
                    permission(
                        "Accessibility", granted: state.scrollAccessibilityGranted,
                        why: "Intercepting wheel events for the direction fix.")
                    note("Granted in System Settings ▸ Privacy & Security. macOS "
                        + "attributes each one to the process that asks, so grant them "
                        + "to asctl.app rather than to your terminal.")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("asctl settings").font(.system(size: 16, weight: .semibold))
            Text("How the app behaves. Nothing here is written to the mouse.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func group<C: View>(
        _ title: String, @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Shown as *observed*, not as read from TCC.
    ///
    /// macOS gives no reliable way to ask whether a permission is held without
    /// also triggering a prompt, so these report whether the thing that needs
    /// the permission is currently working — which is what the user cares about
    /// and is honest about being an inference.
    private func permission(_ name: String, granted: Bool, why: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12))
                Text(why).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "working" : "not seen working")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
