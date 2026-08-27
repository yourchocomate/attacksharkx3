import SwiftUI

/// The main window, laid out like the vendor's: buttons and profile on the
/// left, the mouse in the middle, the settings accordion on the right.
///
/// What it adds over the vendor: a transport picker, a dry-run switch, a live
/// log of every byte sent and every acknowledgement received, full RGB per DPI
/// stage, sensor toggles that are always reachable rather than gated on the
/// connection type, and the Bluetooth tools the vendor has no equivalent for.
@available(macOS 12.0, *)
struct MainView: View {
    @StateObject var state = AppState()
    @State private var selectedButton = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                leftColumn.frame(width: 300)
                Divider()
                centreColumn.frame(minWidth: 280)
                Divider()
                rightColumn.frame(width: 380)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1060, minHeight: 720)
        .onAppear { state.refreshDevices() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("asctl").font(.system(size: 18, weight: .bold))
            Text("Attack Shark X3").font(.system(size: 12)).foregroundStyle(.secondary)

            Divider().frame(height: 20)

            Picker("", selection: $state.link) {
                ForEach(GUITransport.Link.allCases) { link in
                    Text(link.rawValue).tag(link)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Circle()
                .fill(state.isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(state.connectionSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Toggle("Dry run", isOn: $state.dryRun)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                .help("Print the exact bytes without writing anything to the device")

            Button("Rescan") { state.refreshDevices() }
            Button("Apply all") { state.applyEverything() }
                .keyboardShortcut("s")
                .disabled(state.busy || !state.isReady)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Left — buttons, macros, profile, power

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Section("Button Setting", expanded: true) {
                    VStack(spacing: 4) {
                        ForEach(0..<AppState.buttonNames.count, id: \.self) { index in
                            buttonRow(index)
                        }
                        HStack {
                            Button("Restore factory") { state.restoreFactoryButtons() }
                            Spacer()
                            Button("Apply") { state.applyButtons() }
                                .disabled(state.busy || !state.isReady)
                        }
                        .padding(.top, 4)
                        if !state.buttonsHaveLeftClick {
                            Text("At least one button must stay a left click.")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("Power", subtitle: state.battery.map { "\($0)%" }, expanded: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let battery = state.battery {
                            ProgressView(value: Double(battery), total: 100)
                        } else {
                            Text("Battery is only readable over Bluetooth.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Button("Read battery") { state.refreshBattery() }
                            .disabled(state.busy)
                    }
                }

                Section("Bluetooth") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "The mouse sometimes reconnects with working buttons and a "
                            + "dead cursor. That is a firmware fault — no configuration "
                            + "write clears it, only a link teardown."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        Button("Cycle Bluetooth") {
                            state.note("── cycling the Bluetooth controller")
                            DispatchQueue.global().async {
                                let ok = BluetoothPower.cycle()
                                DispatchQueue.main.async {
                                    state.note(ok ? "ok — Bluetooth cycled" : "error: could not cycle Bluetooth")
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func buttonRow(_ index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(AppState.buttonNames[index])
                .font(.system(size: 11))
                .frame(width: 100, alignment: .leading)
            Picker("", selection: Binding(
                get: { state.buttonActions[index] },
                set: { state.buttonActions[index] = $0 }
            )) {
                ForEach(AppState.actionGroups, id: \.0) { group in
                    SwiftUI.Section(group.0) {
                        ForEach(group.1, id: \.key) { choice in
                            Text(choice.label).tag(choice.key)
                        }
                    }
                }
            }
            .labelsHidden()
            .font(.system(size: 11))
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selectedButton == index ? Color.accentColor.opacity(0.14) : .clear))
        .onTapGesture { selectedButton = index }
        .help(index == 4 || index == 8
            ? "The mode-switch button. Remapping it costs Bluetooth channel switching."
            : "")
    }

    // MARK: Centre — the mouse

    private var centreColumn: some View {
        VStack {
            MouseDiagram(selected: $selectedButton) { index in
                AppState.label(forAction: state.buttonActions[index])
            }
            .padding(16)
            Spacer()
        }
    }

    // MARK: Right — the settings accordion

    private var rightColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Section("DPI Setting", expanded: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.stages.indices, id: \.self) { index in
                            DPIStageRow(
                                index: index,
                                stage: $state.stages[index],
                                activeStage: $state.activeStage,
                                enabledCount: state.stages.filter { $0.enabled }.count)
                        }
                        HStack {
                            Text("Active stage").font(.system(size: 11))
                            Picker("", selection: $state.activeStage) {
                                ForEach(0..<max(1, state.stages.filter { $0.enabled }.count), id: \.self) {
                                    Text("\($0 + 1)").tag($0)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 70)
                            Spacer()
                            Button("Apply") { state.applyDPI() }
                                .disabled(state.busy || !state.isReady)
                        }
                        Text(
                            "Report 0x04 is atomic: DPI, the four sensor toggles below "
                            + "and every stage colour are written together, and none of "
                            + "them can be read back first."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Polling Rate", subtitle: "\(state.pollingRate) Hz", expanded: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $state.pollingRate) {
                            ForEach(PollingRate.supported, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        HStack {
                            Spacer()
                            Button("Apply") { state.applyPolling() }
                                .disabled(state.busy || !state.isReady)
                        }
                    }
                }

                Section("Sensor") {
                    VStack(alignment: .leading, spacing: 6) {
                        ToggleRow(
                            title: "Lift-off distance", offLabel: "1 mm", onLabel: "2 mm",
                            value: $state.liftOff2mm)
                        ToggleRow(
                            title: "Ripple control", offLabel: "Off", onLabel: "On",
                            value: $state.rippleControl)
                        ToggleRow(
                            title: "Angle snap", offLabel: "Off", onLabel: "On",
                            value: $state.angleSnap)
                        ToggleRow(
                            title: "Motion sync", offLabel: "Off", onLabel: "On",
                            value: $state.motionSync,
                            note: "Ripple control and motion sync are only observable at "
                                + "high DPI. Testing them at 800 DPI produces a false negative.")
                        HStack {
                            Spacer()
                            Button("Apply") { state.applyDPI() }
                                .disabled(state.busy || !state.isReady)
                        }
                    }
                }

                Section("Power Setting") {
                    VStack(alignment: .leading, spacing: 6) {
                        SliderRow(title: "Sleep time", range: 1...60, unit: "min",
                                  value: $state.sleepMinutes)
                        SliderRow(title: "Deep sleep time", range: 1...60, unit: "min",
                                  value: $state.deepSleepMinutes)
                        SliderRow(title: "Key response time", range: 2...25, unit: "ms",
                                  value: $state.debounceMs)
                        HStack {
                            Spacer()
                            Button("Apply") { state.applyPower() }
                                .disabled(state.busy || !state.isReady)
                        }
                        Text("Accepted by the device; the resulting behaviour has not been measured.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Light Setting", subtitle: "unavailable") {
                    Text(
                        "The X3 has no user-controllable lighting. The light beside the "
                        + "wheel is a battery indicator: off on battery, magenta while "
                        + "charging, green at full. The vendor's own light panel is "
                        + "hidden on this model too."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 11, weight: .semibold))
                if state.busy { ProgressView().controlSize(.small).scaleEffect(0.6) }
                Spacer()
                Button("Clear") { state.log = [] }.controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            LogPane(lines: state.log)
                .frame(height: 120)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}
