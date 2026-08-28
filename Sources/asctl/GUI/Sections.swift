import SwiftUI

/// The vendor's settings column is an accordion: a header checkbox that toggles
/// the visibility of a body. This reproduces that, with a disclosure arrow
/// instead of a checkbox because a checkbox that means "expanded" reads as a
/// setting on macOS.
@available(macOS 12.0, *)
struct Section: View {
    let title: String
    var subtitle: String? = nil
    /// Whether this section holds edits that have not reached the mouse.
    var dirty: Bool = false
    var onDiscard: (() -> Void)? = nil
    @State var expanded: Bool
    @ViewBuilder var content: () -> AnyView

    init<C: View>(
        _ title: String, subtitle: String? = nil, expanded: Bool = false,
        dirty: Bool = false, onDiscard: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> C
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dirty = dirty
        self.onDiscard = onDiscard
        self._expanded = State(initialValue: expanded)
        self.content = { AnyView(content()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if dirty {
                        // An amber dot rather than a word: this appears on
                        // several sections at once and the point is that the
                        // values on screen are not what the mouse holds.
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("not applied")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if dirty, let onDiscard {
                        Button("Discard") { onDiscard() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dirty ? Color.orange.opacity(0.08) : Color.primary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dirty ? Color.orange.opacity(0.35) : .clear, lineWidth: 1))
    }
}

/// A two-option segmented row, matching the vendor's paired radio buttons for
/// lift-off distance and the three sensor toggles.
@available(macOS 12.0, *)
struct ToggleRow: View {
    let title: String
    let offLabel: String
    let onLabel: String
    @Binding var value: Bool
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Picker("", selection: $value) {
                    Text(offLabel).tag(false)
                    Text(onLabel).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@available(macOS 12.0, *)
struct SliderRow: View {
    let title: String
    let range: ClosedRange<Double>
    let unit: String
    @Binding var value: Int
    /// Extra text after the value, for a field whose wire units are not the
    /// units the user thinks in.
    var detail: ((Int) -> String)? = nil

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 130, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }),
                in: range, step: 1)
            Text("\(value) \(unit)")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
            if let detail {
                Text(detail(value))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
            }
        }
    }
}

/// One DPI slot.
///
/// The slider is the *advanced* control. In the simple view a slot is just its
/// number, its value, its colour and whether it is on — which is all the vendor
/// really offers once you stop dragging.
///
/// The wire encoding is `dpi/50 - 1`, so a value that is not a multiple of 50
/// cannot be represented. Both editors snap to 50 rather than letting the
/// builder round silently.
@available(macOS 12.0, *)
struct DPIStageRow: View {
    let index: Int
    @Binding var stage: AppState.Stage
    @Binding var activeStage: Int
    let advanced: Bool
    /// Whether the *device* has confirmed this is the stage it is on, as
    /// opposed to it merely being what we intend to write.
    ///
    /// The distinction is the whole point: the protocol is write-only, so on a
    /// cold start the active stage is a guess. Drawing a guess the same way as
    /// a confirmed reading is how the panel came to claim a stage the mouse was
    /// not actually on.
    let confirmed: Bool

    private static let range = 50.0...26000.0

    private var isActive: Bool { activeStage == index }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $stage.enabled).labelsHidden().toggleStyle(.checkbox)

            Button {
                if stage.enabled { activeStage = index }
            } label: {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(
                        isActive
                            ? (confirmed ? Color.white : Color.accentColor)
                            : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Group {
                            if isActive && confirmed {
                                Circle().fill(Color.accentColor)
                            } else if isActive {
                                Circle().strokeBorder(
                                    Color.accentColor,
                                    style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5]))
                            }
                        })
            }
            .buttonStyle(.plain)
            .help(confirmed
                ? "The mouse reported this stage as active"
                : "Intended active stage — unconfirmed until the mouse reports one")

            if advanced {
                Slider(
                    value: Binding(
                        get: { Double(max(50, stage.dpi)) },
                        set: { stage.dpi = max(50, Int(($0 / 50).rounded()) * 50) }),
                    in: Self.range, step: 50)
                    .disabled(!stage.enabled)
            } else {
                Spacer(minLength: 0)
            }

            TextField("", value: Binding(
                get: { stage.dpi },
                set: { stage.dpi = max(0, min(26000, ($0 / 50) * 50)) }
            ), formatter: NumberFormatter())
                .frame(width: 62)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .disabled(!stage.enabled)

            ColorPicker("", selection: $stage.colour, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34)
        }
        .opacity(stage.enabled ? 1 : 0.4)
    }
}

/// The polling-rate selector as circles, one per supported rate.
///
/// Only four values exist — the wire carries a divider against 1000 Hz and the
/// vendor exposes exactly 8/4/2/1 — so a free control would imply a range the
/// device does not have.
@available(macOS 12.0, *)
struct PollingRateDial: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 16) {
            ForEach(PollingRate.supported, id: \.self) { rate in
                let isOn = selection == rate
                Button {
                    selection = rate
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.08))
                                .frame(width: 52, height: 52)
                            Circle()
                                .strokeBorder(
                                    isOn ? Color.accentColor : Color.primary.opacity(0.22),
                                    lineWidth: isOn ? 2 : 1)
                                .frame(width: 52, height: 52)
                            Text("\(rate)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(isOn ? Color.white : .primary)
                        }
                        Text("Hz").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("\(rate) Hz — divider \(1000 / rate) on the wire")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A log pane. The vendor has nothing like this — it gives no feedback at all
/// beyond the UI state it already believed. Every byte we send and every
/// acknowledgement that comes back is shown here.
@available(macOS 12.0, *)
struct LogPane: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(colour(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .onChange(of: lines.count) { _ in
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.22)))
    }

    private func colour(for line: String) -> Color {
        if line.hasPrefix("error") || line.hasPrefix("refused") { return .red }
        if line.hasPrefix("warning") { return .orange }
        if line.hasPrefix("ok") { return .green }
        if line.hasPrefix("←") { return .cyan }
        if line.hasPrefix("──") { return .accentColor }
        return .secondary
    }
}

/// A segmented battery gauge.
///
/// Ten vertical bars in a battery outline, filled to the level and coloured by
/// it. The colour thresholds are conventional rather than protocol-derived —
/// the device reports a plain 0-100 percentage on GATT 2A19 and attaches no
/// meaning to any band.
@available(macOS 12.0, *)
struct BatteryGauge: View {
    let level: Int?
    let available: Bool
    let reading: Bool

    private let segments = 10

    /// 2A19 is defined as 0-100; clamp anyway so a bad read can never render as
    /// an impossible gauge.
    private var percent: Int? { level.map { max(0, min(100, $0)) } }

    private var colour: Color {
        guard let percent else { return .secondary }
        if percent <= 20 { return .red }
        if percent <= 40 { return .orange }
        return .green
    }

    private var filled: Int {
        guard let percent else { return 0 }
        return max(0, min(segments, Int((Double(percent) / 100.0 * Double(segments)).rounded())))
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index < filled ? colour : Color.primary.opacity(0.10))
                            .frame(width: 7, height: 20)
                    }
                }
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2))

                // The terminal nub.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 3, height: 9)
            }

            VStack(alignment: .leading, spacing: 1) {
                if let percent {
                    Text("\(percent)%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(colour)
                } else if reading {
                    Text("reading…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if available {
                    Text("—").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Bluetooth only")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if !available {
                    Text("no battery report on 2.4 GHz")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }
}
