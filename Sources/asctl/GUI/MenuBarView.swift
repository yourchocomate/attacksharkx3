import SwiftUI

/// The popover behind the menu bar icon.
///
/// Deliberately read-only apart from the two actions at the bottom. The panel
/// exists to answer "what is the mouse doing right now" at a glance, and every
/// value it shows is one the device actually reported — the active stage from a
/// DPI-button press, the battery from GATT. Nothing here is inferred from what
/// we last wrote, because with a write-only protocol that is a guess, and a
/// guess dressed up as a status readout is worse than no readout.
@available(macOS 12.0, *)
struct MenuBarView: View {
    @ObservedObject var state: AppState
    var onOpen: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    private var activeStageValue: Int? {
        guard let index = state.deviceActiveStage,
              state.stages.indices.contains(index) else { return nil }
        return state.stages[index].dpi
    }

    private var activeStageColour: Color {
        guard let index = state.deviceActiveStage,
              state.stages.indices.contains(index) else { return .secondary }
        return state.stages[index].colour
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                dpiRow
                batteryRow
                if state.scrollRunning { scrollRow }
            }
            .padding(14)

            Divider()
            footer
        }
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.devices.isEmpty ? Color.red
                      : (state.monitorConnected ? Color.green : Color.orange))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.devices.isEmpty ? "Not connected" : "Attack Shark X3")
                    .font(.system(size: 12, weight: .semibold))
                Text(state.devices.isEmpty
                     ? "check the slider underneath"
                     : state.link.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var dpiRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("DPI")
            if let dpi = activeStageValue, let index = state.deviceActiveStage {
                HStack(spacing: 8) {
                    Circle()
                        .fill(activeStageColour)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25),
                                                       lineWidth: 0.5))
                    Text("\(dpi)")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("stage \(index + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // A row of pips, so the ladder and where you are in it are both
                // visible without opening the window.
                HStack(spacing: 3) {
                    ForEach(state.stages.indices, id: \.self) { slot in
                        if state.stages[slot].enabled {
                            Capsule()
                                .fill(slot == index
                                      ? state.stages[slot].colour
                                      : state.stages[slot].colour.opacity(0.25))
                                .frame(height: slot == index ? 5 : 3)
                        }
                    }
                }
                .frame(height: 5)
            } else {
                Text("unknown")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("press the DPI button on the mouse to sync")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var batteryRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("Battery")
            if let level = state.battery {
                BatteryGauge(level: level, available: true, reading: false)
            } else if state.batteryAvailable {
                Text(state.batteryReading ? "reading…" : "not read yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Bluetooth only")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("no battery report exists on the 2.4 GHz path")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var scrollRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Wheel")
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(state.scrollMode.short).font(.system(size: 12))
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open") { onOpen() }
            Button("Settings") { onSettings() }
            Spacer()
            Button("Quit") { onQuit() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}
