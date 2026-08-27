import SwiftUI

/// The mouse silhouette that sits in the middle column, mirroring the vendor's
/// layout. Drawn rather than shipped as an image — the vendor's artwork is not
/// ours to redistribute, and a vector drawing scales cleanly anyway.
///
/// Callers pass the index of the button being edited so it can be highlighted,
/// and get a callback when one of the callouts is clicked.
@available(macOS 12.0, *)
struct MouseDiagram: View {
    @Binding var selected: Int
    var actionLabel: (Int) -> String

    /// Positions are fractions of the drawing box, so the diagram scales.
    /// Only the buttons that physically exist on an X3 get a callout; the
    /// report carries 18 entries but this shell has eight real controls.
    private static let callouts: [(index: Int, x: CGFloat, y: CGFloat, side: HorizontalAlignment)] = [
        (0, 0.22, 0.16, .trailing),   // left click
        (1, 0.78, 0.16, .leading),    // right click
        (2, 0.50, 0.22, .leading),    // wheel click
        (16, 0.50, 0.33, .leading),   // wheel down
        (3, 0.50, 0.50, .leading),    // dpi
        (5, 0.50, 0.62, .leading),    // dpi down
        (7, 0.14, 0.40, .trailing),   // backward
        (6, 0.14, 0.50, .trailing),   // forward
        (4, 0.50, 0.80, .leading),    // mode switch
    ]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let bodyRect = CGRect(
                x: width * 0.28, y: height * 0.04,
                width: width * 0.44, height: height * 0.9)

            ZStack {
                shell(in: bodyRect)
                ForEach(Self.callouts, id: \.index) { callout in
                    calloutView(callout, width: width, height: height, body: bodyRect)
                }
            }
        }
        .frame(minWidth: 260, minHeight: 420)
    }

    private func shell(in rect: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: rect.width * 0.45, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.28), Color(white: 0.14)],
                        startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: rect.width * 0.45, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Split between the two main buttons.
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 1, height: rect.height * 0.34)
                .position(x: rect.midX, y: rect.minY + rect.height * 0.17)

            // Scroll wheel.
            Capsule()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: rect.width * 0.12, height: rect.height * 0.1)
                .position(x: rect.midX, y: rect.minY + rect.height * 0.15)
        }
    }

    private func calloutView(
        _ callout: (index: Int, x: CGFloat, y: CGFloat, side: HorizontalAlignment),
        width: CGFloat, height: CGFloat, body: CGRect
    ) -> some View {
        let isSelected = selected == callout.index
        let anchorX = width * callout.x
        let anchorY = height * callout.y
        let labelX = callout.side == .trailing ? width * 0.13 : width * 0.87

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: anchorX, y: anchorY))
                path.addLine(to: CGPoint(x: labelX, y: anchorY))
            }
            .stroke(
                isSelected ? Color.accentColor : Color.white.opacity(0.22),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            Circle()
                .fill(isSelected ? Color.accentColor : Color.white.opacity(0.5))
                .frame(width: 7, height: 7)
                .position(x: anchorX, y: anchorY)

            Button {
                selected = callout.index
            } label: {
                VStack(alignment: callout.side, spacing: 1) {
                    Text(AppState.buttonNames[callout.index])
                        .font(.system(size: 10, weight: .semibold))
                    Text(actionLabel(callout.index))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.black.opacity(0.28)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.white.opacity(0.14),
                            lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(width: width * 0.26)
            .position(
                x: callout.side == .trailing ? width * 0.13 : width * 0.87,
                y: anchorY)
        }
    }
}
