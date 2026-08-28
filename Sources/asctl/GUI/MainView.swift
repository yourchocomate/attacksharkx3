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
    @State private var showUnmapped = false

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingSettings {
                SettingsView(state: state)
            } else {
                deviceBody
            }
        }
        .frame(minWidth: 1180, minHeight: 780)
        .onAppear {
            state.refreshDevices()
            state.refreshProfiles()
            state.restoreLastApplied()
            state.startMonitor()
            state.startDeviceWatch()
        }
        .onChange(of: state.link) { _ in state.restartMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: .asctlShowSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .asctlShowDevice)) { _ in
            showingSettings = false
        }
    }

    private var deviceBody: some View {
        VStack(spacing: 0) {
            provenanceBar
            Divider()
            HStack(alignment: .top, spacing: 0) {
                leftColumn.frame(width: 300)
                Divider()
                centreColumn.frame(minWidth: 380)
                Divider()
                rightColumn.frame(width: 380)
            }
            Divider()
            footer
        }
    }

    private var provenanceBar: some View {
        HStack(spacing: 7) {
            Image(systemName: state.provenance == .edited
                  ? "pencil.circle.fill" : "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(state.provenance == .edited ? Color.orange : .secondary)
            Text(state.provenance.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(state.provenance == .edited
                    ? Color.orange.opacity(0.10) : Color.primary.opacity(0.03))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("asctl").font(.system(size: 18, weight: .bold))
            Text("Attack Shark X3").font(.system(size: 12)).foregroundStyle(.secondary)

            Divider().frame(height: 20)

            Picker("", selection: $state.link) {
                ForEach(GUITransport.Link.allCases) { option in
                    Text(option.rawValue)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .help("Detected automatically. Override only if you know better.")

            Circle()
                .fill(state.devices.isEmpty ? Color.red
                      : (state.isReady ? Color.green : Color.orange))
                .frame(width: 8, height: 8)
            Text(state.devices.isEmpty
                 ? "mouse not found — check the slider underneath"
                 : state.connectionSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Toggle("Dry run", isOn: $state.dryRun)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                .help("Print the exact bytes without writing anything to the device")

            HStack(spacing: 4) {
                Circle()
                    .fill(state.monitorConnected ? Color.green
                          : (state.monitorRunning ? Color.orange : Color.secondary))
                    .frame(width: 6, height: 6)
                Toggle("Listen", isOn: Binding(
                    get: { state.monitorRunning },
                    set: { $0 ? state.startMonitor() : state.stopMonitor() }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 11))
            }
            .help(state.monitorConnected
                ? "Connected — DPI-button presses sync the active stage here"
                : "Not connected to the device's event channel")

            // Two labelled destinations rather than one toggling icon: a
            // button whose meaning depends on where you already are gives no
            // clue what it will do.
            Picker("", selection: $showingSettings) {
                Label("Mouse", systemImage: "computermouse").tag(false)
                Label("Settings", systemImage: "gearshape").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Button(state.anyDirty ? "Apply changes" : "Apply all") {
                state.applyEverything()
            }
            .keyboardShortcut("s")
            .disabled(state.busy || !state.isReady)
            .help(state.anyDirty
                  ? "Write every section that has unapplied changes"
                  : "Rewrite every setting, even though nothing has changed")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Left — buttons, macros, profile, power

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Section("Button Setting", expanded: true, dirty: state.buttonsDirty,
                        onDiscard: { state.discardButtons() }) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(AppState.physicalButtons, id: \.self) { index in
                            buttonRow(index)
                        }

                        Text(
                            "The report carries 18 entries; these seven are the ones "
                            + "shown to drive a button on this shell. The rest are still "
                            + "transmitted, unchanged."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                        HStack {
                            Button("Restore factory") { state.restoreFactoryButtons() }
                            Spacer()
                            Button("Apply") { state.applyButtons() }
                                .disabled(state.busy || !state.isReady)
                        }
                        .padding(.top, 4)

                        if !state.buttonsHaveLeftClick {
                            Text("At least one entry must stay a left click.")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("Battery", expanded: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        BatteryGauge(
                            level: state.battery,
                            available: state.batteryAvailable,
                            reading: state.batteryReading)

                        if state.batteryHistory.count > 1 {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(state.batteryHistory.enumerated()), id: \.offset) {
                                    _, entry in
                                    Text("\(entry.at, style: .time)  \(entry.level)%  \(entry.raw)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }

                        HStack {
                            Button("Refresh") { state.refreshBattery() }
                                .controlSize(.small)
                                .disabled(state.batteryReading || !state.batteryAvailable)
                            Spacer()
                        }

                        Text(
                            "Read from GATT 2A19 on the live connection. Each reading "
                            + "is listed with the raw byte, so a value that moves can "
                            + "be told apart from a value that is being misread."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Profiles", subtitle: "\(state.profileNames.count)", expanded: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.profileNames.isEmpty {
                            Text("No saved profiles yet.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(state.profileNames, id: \.self) { name in
                            HStack(spacing: 6) {
                                Text(name).font(.system(size: 11))
                                Spacer()
                                Button("Load") { state.loadProfile(named: name) }
                                    .controlSize(.small)
                                    .help("Load into the editor without writing")
                                Button("Apply") {
                                    state.loadProfile(named: name)
                                    state.applyEverything()
                                }
                                .controlSize(.small)
                                .disabled(state.busy || !state.isReady)
                                Button {
                                    state.deleteProfile(named: name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                            }
                        }

                        Divider().padding(.vertical, 2)

                        HStack(spacing: 6) {
                            TextField("New profile name", text: $state.newProfileName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .onSubmit { state.saveProfile(named: state.newProfileName) }
                            Button("Save") { state.saveProfile(named: state.newProfileName) }
                                .controlSize(.small)
                                .disabled(state.newProfileName
                                    .trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        Text(
                            "Profiles are files on this Mac, replayed through the normal "
                            + "reports — the device's own slots are unused by this product. "
                            + "Because the protocol is write-only, a saved profile is the "
                            + "only record of a configuration that exists anywhere."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Scrolling",
                        subtitle: state.scrollRunning ? "active" : nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(state.macOSNaturalScrolling ? Color.orange : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text("macOS natural scrolling is "
                                + (state.macOSNaturalScrolling ? "ON" : "off"))
                                .font(.system(size: 11))
                            Spacer()
                        }

                        Picker("", selection: $state.scrollMode) {
                            ForEach(ScrollDirection.allCases) { mode in
                                Text(mode.short).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: state.scrollMode) { _ in state.applyScrollMode() }

                        Text(state.scrollMode.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        if state.scrollRunning {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("intercepting the wheel — trackpad untouched")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }

                        Text(
                            "Applies while asctl is running. Turn on \"Open at login\" "
                            + "in settings to have it always active."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
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
                .foregroundStyle(
                    AppState.physicalButtons.contains(index) ? .primary : .secondary)
                .frame(width: 104, alignment: .leading)
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
        .help(index == AppState.modeButtonEntry
            ? "The mode button cycles the Bluetooth identity. Remapping it costs "
                + "channel switching until you restore the factory mapping."
            : AppState.buttonNames[index])
    }

    // MARK: Centre — the mouse

    private var centreColumn: some View {
        ScrollView {
            VStack(spacing: 10) {
                MouseDiagram(selected: $selectedButton) { index in
                    AppState.label(forAction: state.buttonActions[index])
                }
                .padding(.top, 10)

                Text(
                    "The 2.4G / OFF / BT slider, the sensor, the indicator LEDs and "
                    + "the Type-C port are shown for orientation. None of them is "
                    + "remappable."
                )
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Right — the settings accordion

    private var rightColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Section("DPI Setting", subtitle: "\(state.stages.filter { $0.enabled }.count) stages",
                        expanded: true, dirty: state.dpiDirty,
                        onDiscard: { state.discardDPI() }) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.stages.indices, id: \.self) { index in
                            DPIStageRow(
                                index: index,
                                stage: $state.stages[index],
                                activeStage: $state.activeStage,
                                advanced: state.showAdvancedDPI,
                                confirmed: state.deviceActiveStage == index)
                        }

                        HStack(spacing: 5) {
                            if let reported = state.deviceActiveStage {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("Mouse reports stage \(reported + 1) active")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            } else {
                                Circle()
                                    .strokeBorder(Color.orange, lineWidth: 1)
                                    .frame(width: 6, height: 6)
                                Text(
                                    "Active stage unconfirmed — press the DPI button "
                                    + "on the mouse to sync"
                                )
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            }
                            Spacer()
                        }

                        if !state.activeStageIsEnabled {
                            Text("The active stage is switched off — pick one that is on.")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }

                        HStack(spacing: 8) {
                            Toggle("Advanced", isOn: $state.showAdvancedDPI)
                                .toggleStyle(.switch)
                                .font(.system(size: 11))
                                .help("Show a slider per stage. Values snap to 50 either way.")
                            Spacer()
                            Menu("Presets") {
                                Button("Vendor factory table — 6 stages") {
                                    state.loadVendorFactoryStages()
                                }
                                Button("This unit's stock — 5 stages") {
                                    state.loadStockStages()
                                }
                            }
                            .frame(width: 92)
                            Button("Apply") { state.applyDPI() }
                                .disabled(state.busy || !state.isReady)
                        }

                        Text(
                            "Report 0x04 is atomic: DPI, the four sensor toggles below "
                            + "and every stage colour go together, and none can be read "
                            + "back first. The eight slots are addressed by index — "
                            + "switching one off does not renumber the rest."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Polling Rate", subtitle: "\(state.pollingRate) Hz", expanded: true,
                        dirty: state.pollingDirty,
                        onDiscard: { state.discardPolling() }) {
                    VStack(alignment: .leading, spacing: 10) {
                        PollingRateDial(selection: $state.pollingRate)
                        HStack {
                            Text("The wire carries a divider against 1000 Hz.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Apply") { state.applyPolling() }
                                .disabled(state.busy || !state.isReady)
                        }
                    }
                }

                Section("Sensor", dirty: state.sensorDirty,
                        onDiscard: { state.discardSensor() }) {
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

                Section("Power Setting", dirty: state.powerDirty,
                        onDiscard: { state.discardPower() }) {
                    VStack(alignment: .leading, spacing: 6) {
                        SliderRow(title: "Sleep time", range: 1...60, unit: "min",
                                  value: $state.sleepMinutes)
                        SliderRow(title: "Deep sleep time", range: 1...60, unit: "min",
                                  value: $state.deepSleepMinutes)
                        SliderRow(
                            title: "Key response time", range: 2...25, unit: "",
                            value: $state.debounceMs,
                            detail: { "= \(LightReport.effectiveDebounceMs($0)) ms" })
                        HStack {
                            Spacer()
                            Button("Apply") { state.applyPower() }
                                .disabled(state.busy || !state.isReady)
                        }
                        Text(
                            "Key response time counts 2 ms units — measured on "
                            + "hardware, so the effective debounce is twice the "
                            + "number. The sleep timers are accepted by the device "
                            + "but their behaviour has not been measured."
                        )
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
