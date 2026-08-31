import SwiftUI
import ZapperKit

struct RemoteView: View {
    @ObservedObject var controller: RemoteController
    @State private var showNumberPad = false
    @State private var typedChannel = ""

    var body: some View {
        VStack(spacing: 14) {
            header

            SearchSection(controller: controller)

            DPadView { key in controller.press(key) }
                .padding(.vertical, 2)
                .opacity(controller.isConnected ? 1 : 0.4)
                .allowsHitTesting(controller.isConnected)

            navigationRow
            volumeSection
            channelSection

            if showNumberPad {
                NumberPad(
                    typed: $typedChannel,
                    onGo: {
                        controller.openChannel(typedChannel)
                        typedChannel = ""
                        showNumberPad = false
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            sourcesRow

            QuickLaunchRow(controller: controller)

            if let message = controller.transientMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
        .animation(.easeOut(duration: 0.16), value: showNumberPad)
        .animation(.easeOut(duration: 0.16), value: controller.transientMessage)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColour)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.currentDevice?.name ?? "No TV found")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "power")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(controller.state.isOn ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Palette.key, in: Circle())
                .tapPress { controller.togglePower() }

            settingsMenu
        }
    }

    private var subtitle: String {
        if let channel = controller.state.currentChannel,
           controller.state.isOn,
           controller.state.currentAppID == "com.webos.app.livetv" {
            return channel
        }
        if let app = controller.state.currentAppID,
           let label = controller.apps.first(where: { $0.id == app })?.label {
            return label
        }
        return controller.statusText
    }

    private var statusColour: Color {
        switch controller.connection {
        case .connected:       return controller.state.isOn ? .green : .secondary
        case .connecting:      return .yellow
        case .awaitingPairing: return .orange
        case .disconnected, .failed: return .red
        }
    }

    private var settingsMenu: some View {
        Menu {
            if controller.discovered.count > 1 || controller.currentDevice == nil {
                Section("Devices") {
                    ForEach(controller.discovered) { found in
                        Button {
                            controller.select(found)
                        } label: {
                            if found.id == controller.selectedDeviceID {
                                Label(found.name, systemImage: "checkmark")
                            } else {
                                Text(found.name)
                            }
                        }
                    }
                }
            }
            Button("Reconnect") { controller.reconnect() }
            Button("Forget Pairing…") { controller.forgetPairing() }
            Divider()
            if controller.spotifyConnected {
                Button("Disconnect Spotify") { controller.disconnectSpotify() }
            } else {
                Button("Connect Spotify…") { controller.connectSpotify() }
            }
            Divider()
            Button("Quit Zapper") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .background(Palette.key, in: Circle())
    }

    // MARK: - Sections

    private var navigationRow: some View {
        HStack(spacing: 8) {
            KeyButton(icon: "arrow.uturn.backward", title: "Back") { controller.press(.back) }
            KeyButton(icon: "house", title: "Home") { controller.press(.home) }
            KeyButton(icon: "info.circle", title: "Info") { controller.press(.info) }
        }
        .disabled(!controller.isConnected)
        .opacity(controller.isConnected ? 1 : 0.4)
    }

    private var volumeSection: some View {
        VStack(spacing: 7) {
            Rocker(
                icon: controller.state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: volumeLabel,
                onDown: { controller.press(.volumeDown) },
                onUp: { controller.press(.volumeUp) },
                centerTap: { controller.toggleMute() }
            )

            if let volume = controller.state.volume {
                Slider(
                    value: Binding(
                        get: { controller.scrubbingVolume ?? Double(volume) },
                        set: { controller.scrubbingVolume = $0 }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        if !editing, let target = controller.scrubbingVolume {
                            controller.setVolume(Int(target.rounded()))
                            controller.scrubbingVolume = nil
                        }
                    }
                )
                .controlSize(.mini)
            }
        }
        .disabled(!controller.isConnected)
        .opacity(controller.isConnected ? 1 : 0.4)
    }

    private var volumeLabel: String {
        if controller.state.muted { return "muted" }
        if let volume = controller.state.volume { return "\(volume)" }
        return "vol"
    }

    private var channelSection: some View {
        Rocker(
            icon: "number",
            label: "ch",
            onDown: { controller.press(.channelDown) },
            onUp: { controller.press(.channelUp) },
            centerTap: { showNumberPad.toggle() }
        )
        .disabled(!controller.isConnected)
        .opacity(controller.isConnected ? 1 : 0.4)
    }

    private var sourcesRow: some View {
        HStack(spacing: 8) {
            Menu {
                if controller.inputs.isEmpty {
                    Text("No inputs reported")
                } else {
                    ForEach(controller.inputs) { input in
                        Button {
                            controller.switchInput(input)
                        } label: {
                            Text(input.connected ? input.label : "\(input.label) (nothing connected)")
                        }
                    }
                }
            } label: {
                dropdownLabel(icon: "cable.connector", title: "Input")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Menu {
                ForEach(controller.apps) { app in
                    Button(app.label) { controller.launch(app) }
                }
            } label: {
                dropdownLabel(icon: "square.grid.2x2", title: "Apps")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .disabled(!controller.isConnected)
        .opacity(controller.isConnected ? 1 : 0.4)
    }

    private func dropdownLabel(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Palette.key, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Type a channel number and jump straight to it — something the iPhone
/// remote can't do on a third-party TV.
struct NumberPad: View {
    @Binding var typed: String
    let onGo: () -> Void

    private let keys = ["1","2","3","4","5","6","7","8","9","⌫","0","Go"]

    var body: some View {
        VStack(spacing: 7) {
            Text(typed.isEmpty ? "—" : typed)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(typed.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Palette.key, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 13, weight: key == "Go" ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(key == "Go" ? Color.accentColor : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            key == "Go" ? Palette.accentKey : Palette.key,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .tapPress { handle(key) }
                }
            }
        }
    }

    private func handle(_ key: String) {
        switch key {
        case "⌫": if !typed.isEmpty { typed.removeLast() }
        case "Go": onGo()
        default:  if typed.count < 5 { typed.append(key) }
        }
    }
}
