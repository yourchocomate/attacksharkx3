import AppKit
import SwiftUI

/// asctl's own settings, as opposed to the mouse's.
///
/// Kept separate from the device panels on purpose: everything else in this
/// window writes to the mouse, and none of this does. Mixing "how the app
/// behaves" into the same accordion as "what the hardware is set to" made it
/// unclear which changes were being sent anywhere.
///
/// Ordered by what a section asks of the reader rather than by subject: the two
/// switches first, then the read-only status, then the reference material, then
/// the one destructive action. Uninstalling used to sit in the middle of the
/// panel, between Data and Permissions.
@available(macOS 12.0, *)
struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // Controls
                startupSection
                listenerSection

                // Status
                permissionsSection

                // Reference
                dataSection
                troubleshootingSection

                // Destructive, and last for that reason
                uninstallSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    /// Carries the version and the update control.
    ///
    /// Both used to be reachable only from the menu bar popover, which is a
    /// strange place to have to look for "what am I running".
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("asctl settings").font(.system(size: 16, weight: .semibold))
                Text("How the app behaves. Nothing here is written to the mouse.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Version \(AppVersion.current)")
                    .font(.system(size: 11, weight: .medium))
                Text(state.updateSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
                HStack(spacing: 6) {
                    if case .available = state.updateState {
                        Button("Install update") { state.installUpdate() }
                            .controlSize(.small)
                    }
                    Button("Check for updates") { state.checkForUpdate() }
                        .controlSize(.small)
                        .disabled(state.updateIsBusy)
                }
            }
        }
    }

    // MARK: Controls

    private var startupSection: some View {
        group("Startup") {
            Toggle("Open asctl at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!state.canLaunchAtLogin || state.launchAtLoginBusy)

            if state.launchAtLogin && !state.launchAtLoginRegistered {
                warning("launchd has not accepted the login item, so asctl will not "
                    + "open at login. Toggle this off and on again; if it persists, "
                    + "the app may have moved since it was registered.")
            }

            if state.canLaunchAtLogin {
                note("One switch for everything the app does. asctl opens at login "
                    + "and stays in the menu bar, so the device listener, the "
                    + "DPI-stage and battery readings and the wheel-direction fix "
                    + "all keep working. Closing the window does not stop it — quit "
                    + "from the menu bar item for that.")
            } else {
                note("Only the app bundle can be launched at login. Build it with "
                    + "Scripts/make-app.sh and run that rather than the bare binary.")
            }
        }
    }

    private var listenerSection: some View {
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
            note("The mouse volunteers a small set of events, a DPI-button press "
                + "among them. That is the only piece of device state this app can "
                + "read rather than assume, because the configuration protocol is "
                + "write-only.")
        }
    }

    // MARK: Status

    private var permissionsSection: some View {
        group("Permissions") {
            permission(
                "Input Monitoring", granted: !state.devices.isEmpty,
                why: "Configuring over the 2.4 GHz receiver or the USB cable.")
            permission(
                "Bluetooth", granted: state.batteryAvailable && state.monitorConnected,
                why: "Configuring over GATT, and the battery level.")
            permission(
                "Accessibility", granted: state.scrollAccessibilityGranted,
                why: "Intercepting wheel events for the direction fix.")
            note("Granted in System Settings ▸ Privacy & Security. macOS attributes "
                + "each one to the process that asks, so grant them to asctl.app "
                + "rather than to your terminal.")
        }
    }

    // MARK: Reference

    private var dataSection: some View {
        group("Data") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppPaths.configDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(AppPaths.configDirectoryExists
                         ? "\(AppPaths.storedProfileCount) profile(s), plus the record "
                           + "of the last configuration written"
                         : "not created yet — it appears when you save a profile or "
                           + "apply a setting")
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
            note("Profiles are plain JSON. Because the mouse cannot be read back, "
                + "this folder is the only record of a configuration that exists "
                + "anywhere — worth keeping if you reinstall.")
        }
    }

    private var troubleshootingSection: some View {
        group("Troubleshooting") {
            labelled("Menu bar icon missing",
                "The menu bar is full — on a notched display the overflow hides "
                + "behind the notch. Cmd-drag any icon to reorder, and move asctl to "
                + "the left of the notch. Its position is remembered.")
            labelled("Permissions lost after updating",
                "Expected. These builds are signed with a certificate that is not "
                + "issued by Apple, and macOS re-checks identity on each update. "
                + "Grant them once more.")
            labelled("Cursor dead after a Bluetooth reconnect",
                "A firmware fault. No configuration write clears it; use the "
                + "Bluetooth recovery button on the device page.")
        }
    }

    // MARK: Destructive

    private var uninstallSection: some View {
        group("Uninstall") {
            note("Removes the app, both launch agents, the window preferences and "
                + "the Privacy & Security entries. It asks whether to keep your "
                + "profiles before removing anything.")
            note("Settings already written to the mouse stay on the mouse — the "
                + "protocol has no readback and no factory reset.")
            HStack(spacing: 8) {
                if state.uninstallerPath == nil {
                    Text("Only the app bundle carries the uninstaller. From a source "
                        + "checkout, run Scripts/uninstall.sh.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reveal") { state.revealUninstaller() }
                    .controlSize(.small)
                    .disabled(state.uninstallerPath == nil)
                Button("Run uninstaller…") { state.runUninstaller() }
                    .controlSize(.small)
                    .disabled(state.uninstallerPath == nil)
            }
        }
    }

    // MARK: Building blocks

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

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A symptom and what to do about it, rather than a wall of prose.
    private func labelled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(body)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
