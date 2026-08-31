import SwiftUI
import ZapperKit

// MARK: - Press handling

/// Fires immediately on press, then repeats while the button stays held —
/// what you want for volume and channel, where one click at a time is tedious.
struct HoldRepeat<S: Shape>: ViewModifier {
    let shape: S
    let action: () -> Void
    var initialDelay: Double = 0.45
    var interval: Double = 0.12

    @State private var isPressed = false
    @State private var repeater: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        action()
                        repeater = Task {
                            try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
                            while !Task.isCancelled {
                                await MainActor.run { action() }
                                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                            }
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
    }
}

/// Single-shot press with the same visual feedback.
struct TapPress<S: Shape>: ViewModifier {
    let shape: S
    let action: () -> Void
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { value in
                        isPressed = false
                        // Only fire if the pointer is still over the control.
                        if value.translation.width.magnitude < 24,
                           value.translation.height.magnitude < 24 {
                            action()
                        }
                    }
            )
    }
}

extension View {
    func holdRepeat(_ action: @escaping () -> Void) -> some View {
        modifier(HoldRepeat(shape: Rectangle(), action: action))
    }

    /// Overload for controls whose live area isn't rectangular — the D-pad
    /// segments, which must let clicks fall through to their neighbours.
    func holdRepeat<S: Shape>(shape: S, _ action: @escaping () -> Void) -> some View {
        modifier(HoldRepeat(shape: shape, action: action))
    }

    func tapPress(_ action: @escaping () -> Void) -> some View {
        modifier(TapPress(shape: Rectangle(), action: action))
    }

    func tapPress<S: Shape>(shape: S, _ action: @escaping () -> Void) -> some View {
        modifier(TapPress(shape: shape, action: action))
    }
}

// MARK: - Shared look

enum Palette {
    static let key = Color.primary.opacity(0.08)
    static let keyHover = Color.primary.opacity(0.14)
    static let accentKey = Color.accentColor.opacity(0.18)
}

/// A pill-shaped control with two halves that repeat while held — the volume
/// and channel rockers.
struct Rocker: View {
    let icon: String
    let label: String
    let onDown: () -> Void
    let onUp: () -> Void
    var centerTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "minus")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .holdRepeat(onDown)

            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 8.5, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 34)
            .contentShape(Rectangle())
            .modifier(OptionalTap(action: centerTap))

            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .holdRepeat(onUp)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.key, in: Capsule())
    }
}

private struct OptionalTap: ViewModifier {
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action { AnyView(content.tapPress(action)) } else { AnyView(content) }
    }
}

/// A square-ish labelled key (Back, Home, Exit…).
struct KeyButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Palette.key, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .tapPress(action)
    }
}
