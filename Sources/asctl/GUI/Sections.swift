import SwiftUI

/// The vendor's settings column is an accordion: a header checkbox that toggles
/// the visibility of a body. This reproduces that, with a disclosure arrow
/// instead of a checkbox because a checkbox that means "expanded" reads as a
/// setting on macOS.
@available(macOS 12.0, *)
struct Section: View {
    let title: String
    var subtitle: String? = nil
    @State var expanded: Bool
    @ViewBuilder var content: () -> AnyView

    init<C: View>(
        _ title: String, subtitle: String? = nil, expanded: Bool = false,
        @ViewBuilder content: @escaping () -> C
    ) {
        self.title = title
        self.subtitle = subtitle
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
                    Spacer()
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
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
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
        }
    }
}

/// The DPI editor — eight stages, each with an enable box, a slider, a typed
/// value and a colour well, exactly as the vendor lays them out.
@available(macOS 12.0, *)
struct DPIStageRow: View {
    let index: Int
    @Binding var stage: AppState.Stage
    @Binding var activeStage: Int
    let enabledCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $stage.enabled).labelsHidden().toggleStyle(.checkbox)

            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Slider(
                value: Binding(
                    get: { Double(stage.dpi) },
                    // The wire encoding is dpi/50 - 1, so anything not a
                    // multiple of 50 cannot be represented. Snap here rather
                    // than silently rounding at build time.
                    set: { stage.dpi = max(50, Int(($0 / 50).rounded()) * 50) }),
                in: 50...26000, step: 50)
                .disabled(!stage.enabled)

            TextField("", value: $stage.dpi, formatter: NumberFormatter())
                .frame(width: 58)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .disabled(!stage.enabled)

            ColorPicker("", selection: $stage.colour, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34)
                .disabled(!stage.enabled)
        }
        .opacity(stage.enabled ? 1 : 0.45)
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
