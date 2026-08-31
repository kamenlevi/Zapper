import SwiftUI
import ZapperKit

/// Three fixed shortcut tiles above the D-pad, rendered from the artwork the
/// TV itself serves for each launch point — the same full-bleed tile look as
/// the TV's home row. Right-click a tile to point it at a different app.
struct QuickLaunchRow: View {
    @ObservedObject var controller: RemoteController

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { slot in
                tile(slot: slot)
            }
        }
        .disabled(!controller.isConnected)
        .opacity(controller.isConnected ? 1 : 0.4)
    }

    @ViewBuilder
    private func tile(slot: Int) -> some View {
        let app = controller.quickApps.indices.contains(slot) ? controller.quickApps[slot] : nil
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        ZStack {
            // The brand ground the TV uses for its own home-row tile. The
            // square artwork's baked-in background matches it, so the logo
            // sits small and centred on one seamless wide card.
            tileBackground(for: app)

            if let app, let icon = controller.quickIcons[app.id] {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text(app?.label ?? "—")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .tapPress(shape: shape) {
            if let app { controller.launch(app) }
        }
        .contextMenu {
            if controller.apps.isEmpty {
                Text("Connect to the TV to list its apps")
            } else {
                ForEach(controller.apps) { candidate in
                    Button(candidate.label) { controller.setQuickApp(candidate, slot: slot) }
                }
            }
        }
        .help(app?.label ?? "")
    }

    @ViewBuilder
    private func tileBackground(for app: DeviceApp?) -> some View {
        if let app, let hex = controller.quickColors[app.id], let colour = Color(tileHex: hex) {
            colour
        } else {
            Palette.key
        }
    }
}

extension Color {
    /// "#RRGGBB" (case-insensitive, hash optional) — the form webOS uses for
    /// `iconColor`.
    init?(tileHex: String) {
        var hex = tileHex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
