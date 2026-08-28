import SwiftUI

// MARK: - Outlines
//
// Proportions follow the vendor's published dimensions: 61 mm wide, 118.5 mm
// long, 39.7 mm tall. Each shape is drawn in a unit rect so the three faces stay
// in scale with one another.

/// Top-down and underside silhouette: narrow nose, widest around two-thirds
/// back, rounded tail.
struct MouseShellShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: p(0.50, 0.000))
        // Nose: blunt, and already close to full width by a tenth of the way back.
        path.addCurve(to: p(0.90, 0.085), control1: p(0.72, 0.000), control2: p(0.84, 0.030))
        path.addCurve(to: p(0.965, 0.240), control1: p(0.945, 0.125), control2: p(0.965, 0.180))
        // A shallow waist through the grip, then out again to the widest point.
        path.addCurve(to: p(0.955, 0.470), control1: p(0.965, 0.320), control2: p(0.950, 0.400))
        path.addCurve(to: p(0.990, 0.660), control1: p(0.965, 0.545), control2: p(0.990, 0.590))
        path.addCurve(to: p(0.855, 0.895), control1: p(0.990, 0.775), control2: p(0.940, 0.840))
        path.addCurve(to: p(0.50, 1.000), control1: p(0.775, 0.955), control2: p(0.645, 1.000))
        // Mirrored.
        path.addCurve(to: p(0.145, 0.895), control1: p(0.355, 1.000), control2: p(0.225, 0.955))
        path.addCurve(to: p(0.010, 0.660), control1: p(0.060, 0.840), control2: p(0.010, 0.775))
        path.addCurve(to: p(0.045, 0.470), control1: p(0.010, 0.590), control2: p(0.035, 0.545))
        path.addCurve(to: p(0.035, 0.240), control1: p(0.050, 0.400), control2: p(0.035, 0.320))
        path.addCurve(to: p(0.10, 0.085), control1: p(0.035, 0.180), control2: p(0.055, 0.125))
        path.addCurve(to: p(0.50, 0.000), control1: p(0.16, 0.030), control2: p(0.28, 0.000))
        path.closeSubpath()
        return path
    }
}

/// The hexagonal receiver-bay cover on the underside.
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: p(0.50, 0.00))
        path.addLine(to: p(1.00, 0.27))
        path.addLine(to: p(1.00, 0.73))
        path.addLine(to: p(0.50, 1.00))
        path.addLine(to: p(0.00, 0.73))
        path.addLine(to: p(0.00, 0.27))
        path.closeSubpath()
        return path
    }
}

/// Left flank — a long, low wedge, not a dome. The base is flat for the whole
/// length, the crest sits about 60% back, and the nose stays low. Height is only
/// a third of the length, which is what stops it reading as a hill.
struct MouseSideShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: p(0.02, 0.67))
        path.addCurve(to: p(0.19, 0.43), control1: p(0.08, 0.56), control2: p(0.14, 0.49))
        path.addCurve(to: p(0.39, 0.20), control1: p(0.26, 0.34), control2: p(0.32, 0.25))
        path.addCurve(to: p(0.57, 0.03), control1: p(0.46, 0.13), control2: p(0.51, 0.05))
        path.addCurve(to: p(0.75, 0.00), control1: p(0.64, 0.01), control2: p(0.70, 0.00))
        path.addCurve(to: p(0.91, 0.22), control1: p(0.83, 0.07), control2: p(0.88, 0.14))
        path.addCurve(to: p(0.99, 0.70), control1: p(0.95, 0.43), control2: p(0.99, 0.61))
        path.addCurve(to: p(0.92, 0.91), control1: p(0.99, 0.78), control2: p(0.97, 0.87))
        path.addCurve(to: p(0.20, 0.94), control1: p(0.67, 0.94), control2: p(0.39, 0.94))
        path.addCurve(to: p(0.13, 0.86), control1: p(0.17, 0.93), control2: p(0.14, 0.90))
        path.addCurve(to: p(0.02, 0.67), control1: p(0.09, 0.82), control2: p(0.03, 0.73))
        path.closeSubpath()
        return path
    }
}

/// The three faces, annotated the way the vendor's own product diagram is:
/// every label sits **outside** the silhouette with a leader line to the part.
///
/// Which entries are clickable is not a guess. Writing a distinct key onto each
/// report entry and watching the mouse established:
///
/// | Entry | Button | Face |
/// |---|---|---|
/// | 1, 2 | left, right | top |
/// | 3 | middle (wheel) | top |
/// | 4 | DPI switch | underside, left of the sensor |
/// | 5 | mode key | underside, right of the sensor |
/// | 7, 8 | forward, backward | left flank |
///
/// Entries 6 and 9-18 exist in the report and drive nothing on this shell.
/// Fixed parts — sensor, Type-C, the 2.4G/OFF/BT slider, the indicator LEDs,
/// the receiver bay — are labelled but not clickable.
@available(macOS 12.0, *)
struct MouseDiagram: View {
    @Binding var selected: Int
    var actionLabel: (Int) -> String

    private enum Side { case left, right }

    private struct Part {
        var entry: Int?
        var title: String
        var anchor: CGPoint
        var side: Side
        var labelY: CGFloat
    }

    // Canvas geometry. The shell is centred; the columns either side hold the
    // labels, which is the whole reason the vendor's diagram stays readable.
    private let canvasWidth: CGFloat = 360
    private let shellWidth: CGFloat = 96
    private var shellHeight: CGFloat { shellWidth * 118.5 / 61.0 }   // 186
    private var shellLeft: CGFloat { (canvasWidth - shellWidth) / 2 }
    private var shellRight: CGFloat { shellLeft + shellWidth }
    private var shellTop: CGFloat { 10 }

    private let sideShellWidth: CGFloat = 186
    private var sideShellHeight: CGFloat { sideShellWidth * 39.7 / 118.5 }  // 62

    var body: some View {
        VStack(spacing: 22) {
            face("Top", height: shellHeight + 26) { topFace }
            face("Underside", height: shellHeight + 26) { bottomFace }
            face("Left side", height: sideShellHeight + 70) { sideFace }
        }
    }

    private func face<C: View>(
        _ title: String, height: CGFloat, @ViewBuilder content: () -> C
    ) -> some View {
        VStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            ZStack(alignment: .topLeading) { content() }
                .frame(width: canvasWidth, height: height)
        }
    }

    /// Shell coordinates → canvas coordinates.
    private func onShell(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: shellLeft + shellWidth * x, y: shellTop + shellHeight * y)
    }

    // MARK: Top

    private var topFace: some View {
        let parts = [
            Part(entry: 0, title: "Left Button", anchor: onShell(0.26, 0.16),
                 side: .left, labelY: shellTop + 10),
            Part(entry: 1, title: "Right Button", anchor: onShell(0.74, 0.16),
                 side: .right, labelY: shellTop + 10),
            Part(entry: 2, title: "Middle Button", anchor: onShell(0.50, 0.18),
                 side: .right, labelY: shellTop + 62),
            Part(entry: 6, title: "Forward", anchor: onShell(0.045, 0.42),
                 side: .left, labelY: shellTop + 84),
            Part(entry: 7, title: "Backward", anchor: onShell(0.05, 0.53),
                 side: .left, labelY: shellTop + 124),
        ]

        return ZStack(alignment: .topLeading) {
            shell

            // The shell is split across its width at about 44%: the two main
            // buttons sit above the seam, the palm below it.
            Path { path in
                path.move(to: onShell(0.045, 0.435))
                path.addCurve(to: onShell(0.955, 0.435),
                              control1: onShell(0.30, 0.465),
                              control2: onShell(0.70, 0.465))
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 1)

            // Seam between the two main buttons, from the nose to that split.
            line(from: onShell(0.50, 0.005), to: onShell(0.50, 0.445),
                 colour: .white.opacity(0.22))

            // Scroll wheel, ribbed, sunk into the seam near the nose.
            piece(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.09)),
                  at: onShell(0.50, 0.175), size: CGSize(width: 12, height: 38))
            ForEach(0..<7, id: \.self) { rib in
                piece(Rectangle().fill(Color.white.opacity(0.16)),
                      at: onShell(0.50, 0.115 + CGFloat(rib) * 0.020),
                      size: CGSize(width: 9, height: 0.8))
            }
            piece(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6),
                  at: onShell(0.50, 0.175), size: CGSize(width: 12, height: 38))

            // The indicator panel below the wheel, with its light.
            piece(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8),
                  at: onShell(0.50, 0.325), size: CGSize(width: 13, height: 26))
            piece(Capsule().fill(Color.cyan.opacity(0.85)),
                  at: onShell(0.50, 0.365), size: CGSize(width: 4, height: 7))

            // Two side-button tabs, protruding past the left edge.
            piece(RoundedRectangle(cornerRadius: 2.5).fill(Color(white: 0.34)),
                  at: onShell(0.045, 0.42), size: CGSize(width: 7, height: 26))
            piece(RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6),
                  at: onShell(0.045, 0.42), size: CGSize(width: 7, height: 26))
            piece(RoundedRectangle(cornerRadius: 2.5).fill(Color(white: 0.34)),
                  at: onShell(0.05, 0.53), size: CGSize(width: 7, height: 24))
            piece(RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6),
                  at: onShell(0.05, 0.53), size: CGSize(width: 7, height: 24))

            callouts(parts)
        }
    }

    // MARK: Underside

    private var bottomFace: some View {
        let parts = [
            Part(entry: nil, title: "Type-C", anchor: onShell(0.50, 0.025),
                 side: .right, labelY: shellTop + 2),
            Part(entry: nil, title: "2.4G / OFF / BT", anchor: onShell(0.50, 0.235),
                 side: .right, labelY: shellTop + 34),
            Part(entry: nil, title: "DPI light", anchor: onShell(0.245, 0.435),
                 side: .left, labelY: shellTop + 66),
            Part(entry: nil, title: "Mode light", anchor: onShell(0.755, 0.435),
                 side: .right, labelY: shellTop + 66),
            Part(entry: 3, title: "DPI Switch", anchor: onShell(0.235, 0.525),
                 side: .left, labelY: shellTop + 104),
            Part(entry: 4, title: "Mode Key", anchor: onShell(0.765, 0.525),
                 side: .right, labelY: shellTop + 104),
            Part(entry: nil, title: "Sensor", anchor: onShell(0.50, 0.505),
                 side: .left, labelY: shellTop + 150),
            Part(entry: nil, title: "Receiver bay", anchor: onShell(0.50, 0.685),
                 side: .right, labelY: shellTop + 150),
        ]

        return ZStack(alignment: .topLeading) {
            shell

            // PTFE feet: a bar behind the nose and a broad arc at the tail.
            piece(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.10)),
                  at: onShell(0.50, 0.105), size: CGSize(width: shellWidth * 0.60, height: 10))
            piece(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.10)),
                  at: onShell(0.50, 0.855), size: CGSize(width: shellWidth * 0.70, height: 14))

            // The inner moulding line the line art shows around the whole base.
            MouseShellShape()
                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                .frame(width: shellWidth * 0.88, height: shellHeight * 0.90)
                .offset(x: shellLeft + shellWidth * 0.06,
                        y: shellTop + shellHeight * 0.05)

            // Type-C port at the nose.
            piece(Capsule().fill(Color.black.opacity(0.75)),
                  at: onShell(0.50, 0.025), size: CGSize(width: 17, height: 6))

            // The 2.4G / OFF / BT slider. Physical, not remappable — and the
            // reason a "no configurable interface" state can be the switch
            // rather than the software.
            piece(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.6)),
                  at: onShell(0.50, 0.235), size: CGSize(width: 28, height: 13))
            piece(Circle().fill(Color.white.opacity(0.65)),
                  at: onShell(0.405, 0.235), size: CGSize(width: 7, height: 7))

            // Indicator LEDs, each above its own button.
            piece(Capsule().fill(Color.white.opacity(0.45)),
                  at: onShell(0.245, 0.435), size: CGSize(width: 9, height: 4))
            piece(Capsule().fill(Color.white.opacity(0.45)),
                  at: onShell(0.755, 0.435), size: CGSize(width: 9, height: 4))

            // DPI switch (left of the sensor) and mode key (right of it).
            piece(Capsule().fill(Color(white: 0.44)),
                  at: onShell(0.235, 0.525), size: CGSize(width: 16, height: 9))
            piece(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6),
                  at: onShell(0.235, 0.525), size: CGSize(width: 16, height: 9))
            piece(Capsule().fill(Color(white: 0.44)),
                  at: onShell(0.765, 0.525), size: CGSize(width: 16, height: 9))
            piece(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6),
                  at: onShell(0.765, 0.525), size: CGSize(width: 16, height: 9))

            // Sensor housing.
            piece(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.85)),
                  at: onShell(0.50, 0.505), size: CGSize(width: 20, height: 30))
            piece(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6),
                  at: onShell(0.50, 0.505), size: CGSize(width: 20, height: 30))
            piece(Circle().fill(Color(white: 0.40)),
                  at: onShell(0.50, 0.505), size: CGSize(width: 9, height: 9))

            // Receiver bay — a hexagonal cover in the line art.
            piece(HexagonShape().fill(Color.white.opacity(0.06)),
                  at: onShell(0.50, 0.685), size: CGSize(width: 24, height: 22))
            piece(HexagonShape().stroke(Color.white.opacity(0.22), lineWidth: 0.9),
                  at: onShell(0.50, 0.685), size: CGSize(width: 24, height: 22))

            callouts(parts)
        }
    }

    // MARK: Left flank

    private var sideFace: some View {
        let left = (canvasWidth - sideShellWidth) / 2
        let top: CGFloat = 8
        func onSide(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: left + sideShellWidth * x, y: top + sideShellHeight * y)
        }

        let parts = [
            Part(entry: 6, title: "Forward", anchor: onSide(0.35, 0.47),
                 side: .left, labelY: top + sideShellHeight + 22),
            Part(entry: 7, title: "Backward", anchor: onSide(0.52, 0.47),
                 side: .right, labelY: top + sideShellHeight + 22),
        ]

        return ZStack(alignment: .topLeading) {
            MouseSideShape()
                .fill(LinearGradient(
                    colors: [Color(white: 0.32), Color(white: 0.15)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: sideShellWidth, height: sideShellHeight)
                .offset(x: left, y: top)
            MouseSideShape()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .frame(width: sideShellWidth, height: sideShellHeight)
                .offset(x: left, y: top)

            piece(Capsule().fill(Color.white.opacity(0.18)),
                  at: onSide(0.35, 0.47), size: CGSize(width: 26, height: 9))
            piece(Capsule().fill(Color.white.opacity(0.18)),
                  at: onSide(0.52, 0.47), size: CGSize(width: 26, height: 9))

            // Top shell seam visible in the reference side profile.
            Path { path in
                path.move(to: onSide(0.57, 0.03))
                path.addCurve(to: onSide(0.54, 0.31),
                              control1: onSide(0.56, 0.14),
                              control2: onSide(0.56, 0.25))
            }
            .stroke(Color.white.opacity(0.18), lineWidth: 1)

            callouts(parts)
        }
    }

    // MARK: Drawing helpers

    private var shell: some View {
        ZStack(alignment: .topLeading) {
            MouseShellShape()
                .fill(LinearGradient(
                    colors: [Color(white: 0.32), Color(white: 0.15)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: shellWidth, height: shellHeight)
                .offset(x: shellLeft, y: shellTop)
            MouseShellShape()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .frame(width: shellWidth, height: shellHeight)
                .offset(x: shellLeft, y: shellTop)
        }
    }

    private func piece<S: View>(_ view: S, at centre: CGPoint, size: CGSize) -> some View {
        view
            .frame(width: size.width, height: size.height)
            .offset(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
    }

    private func line(from: CGPoint, to: CGPoint, colour: Color) -> some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(colour, lineWidth: 1)
    }

    /// Leader lines and labels for one face.
    ///
    /// A label never overlaps the shell: it lives in the margin, and a two
    /// segment leader — a diagonal, then a short horizontal into the text —
    /// connects it to the part. This is what the vendor's diagram does, and
    /// without it the labels collide with each other and with the mouse.
    private func callouts(_ parts: [Part]) -> some View {
        let labelWidth: CGFloat = 108
        let gutter: CGFloat = 16

        return ZStack(alignment: .topLeading) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                let isSelected = part.entry.map { selected == $0 } ?? false
                let innerX = part.side == .left ? shellLeft - gutter : shellRight + gutter
                let elbowX = part.side == .left ? innerX - 12 : innerX + 12

                Path { path in
                    path.move(to: part.anchor)
                    path.addLine(to: CGPoint(x: elbowX, y: part.labelY + 9))
                    path.addLine(to: CGPoint(x: innerX, y: part.labelY + 9))
                }
                .stroke(
                    isSelected ? Color.accentColor : Color.white.opacity(0.28),
                    lineWidth: 1)

                Circle()
                    .fill(isSelected ? Color.accentColor : Color.white.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .offset(x: part.anchor.x - 2.5, y: part.anchor.y - 2.5)

                label(part, isSelected: isSelected, width: labelWidth)
                    .frame(width: labelWidth,
                           alignment: part.side == .left ? .trailing : .leading)
                    .offset(
                        x: part.side == .left ? innerX - labelWidth - 4 : innerX + 4,
                        y: part.labelY)
            }
        }
    }

    @ViewBuilder
    private func label(_ part: Part, isSelected: Bool, width: CGFloat) -> some View {
        let alignment: HorizontalAlignment = part.side == .left ? .trailing : .leading

        if let entry = part.entry {
            Button {
                selected = entry
            } label: {
                VStack(alignment: alignment, spacing: 0) {
                    Text(part.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(actionLabel(entry))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Report entry \(entry + 1)")
        } else {
            Text(part.title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
