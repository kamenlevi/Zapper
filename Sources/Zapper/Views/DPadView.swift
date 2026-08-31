import SwiftUI
import ZapperKit

/// An annular sector — one quarter of the D-pad ring.
struct RingSegment: Shape {
    let start: Angle
    let end: Angle
    let innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio

        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The centrepiece: a four-way ring with OK in the middle. The whole ring is
/// live, not just the arrow glyphs, so aiming is forgiving.
struct DPadView: View {
    let onPress: (RemoteKey) -> Void

    private let diameter: CGFloat = 178
    private let innerRatio: CGFloat = 0.42
    private let gap: Double = 2.6

    private struct Direction: Identifiable {
        let id: String
        let key: RemoteKey
        let icon: String
        let centre: Double      // degrees, 0 = right, clockwise
    }

    private var directions: [Direction] {
        [
            .init(id: "up",    key: .up,    icon: "chevron.up",    centre: 270),
            .init(id: "right", key: .right, icon: "chevron.right", centre: 0),
            .init(id: "down",  key: .down,  icon: "chevron.down",  centre: 90),
            .init(id: "left",  key: .left,  icon: "chevron.left",  centre: 180),
        ]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.key)
                .frame(width: diameter, height: diameter)

            ForEach(directions) { direction in
                SegmentButton(
                    direction: direction,
                    diameter: diameter,
                    innerRatio: innerRatio,
                    gap: gap,
                    onPress: { onPress(direction.key) }
                )
            }

            OKButton(diameter: diameter * innerRatio - 7) { onPress(.ok) }
        }
        .frame(width: diameter, height: diameter)
    }

    private struct SegmentButton: View {
        let direction: Direction
        let diameter: CGFloat
        let innerRatio: CGFloat
        let gap: Double
        let onPress: () -> Void

        @State private var isHovering = false

        private var shape: RingSegment {
            RingSegment(
                start: .degrees(direction.centre - 45 + gap),
                end: .degrees(direction.centre + 45 - gap),
                innerRatio: innerRatio
            )
        }

        /// Puts the glyph in the middle of its own band.
        private var glyphOffset: CGSize {
            let radius = diameter / 2 * (1 + innerRatio) / 2
            let radians = direction.centre * .pi / 180
            return CGSize(width: cos(radians) * radius, height: sin(radians) * radius)
        }

        var body: some View {
            ZStack {
                shape
                    .fill(isHovering ? Palette.keyHover : Color.clear)
                Image(systemName: direction.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(glyphOffset)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .holdRepeat(shape: shape, onPress)
        }
    }

    private struct OKButton: View {
        let diameter: CGFloat
        let onPress: () -> Void

        @State private var isHovering = false

        var body: some View {
            Text("OK")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(isHovering ? Palette.keyHover : Palette.key)
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
                .contentShape(Circle())
                .onHover { isHovering = $0 }
                .tapPress(shape: Circle(), onPress)
        }
    }
}
