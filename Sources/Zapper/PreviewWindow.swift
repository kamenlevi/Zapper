import AppKit
import SwiftUI
import ZapperKit

/// The big preview. Opens filling the screen's *visible* frame — everything
/// except the Dock and menu bar — rather than taking over a Space; the green
/// button is still there for anyone who wants real fullscreen.
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {

    private let controller: RemoteController
    private var window: NSWindow?

    init(controller: RemoteController) {
        self.controller = controller
        super.init()
    }

    func toggle() {
        if let window {
            window.close()
        } else {
            present()
        }
    }

    private func present() {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 720)

        let window = EscapableWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zapper"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PreviewView(controller: controller) { [weak window] title in
                window?.title = title
            }
        )
        window.setFrame(frame, display: true)
        self.window = window

        // Menu bar apps aren't frontmost by default, so ask for focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        controller.previewWindowOpen = true
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        controller.previewWindowOpen = false
    }
}

/// Escape closes the preview, the way any viewer should.
private final class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct PreviewView: View {
    @ObservedObject var controller: RemoteController
    let setTitle: (String) -> Void

    @State private var showControls = true

    private var isLiveTV: Bool { controller.state.currentAppID == "com.webos.app.livetv" }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            if let image = controller.liveThumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Waiting for the TV…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if !isLiveTV {
                VStack {
                    Text("Streaming apps block screen capture — only their overlays come through.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                }
            }

            if showControls { controlBar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { showControls = $0 }
        .onAppear { setTitle(titleText) }
        .onChange(of: titleText) { _, updated in setTitle(updated) }
    }

    private var titleText: String {
        if isLiveTV {
            return controller.state.currentChannel ?? "Live TV"
        }
        if let show = controller.nowPlaying.showTitle { return show }
        return controller.apps.first { $0.id == controller.state.currentAppID }?.label ?? "Zapper"
    }

    private var subtitleText: String? {
        if isLiveTV { return controller.currentProgram?.name }
        let playing = controller.nowPlaying
        var parts: [String] = []
        if let season = playing.season, let episode = playing.episode {
            parts.append("S\(season) E\(episode)")
        }
        if let episodeTitle = playing.episodeTitle { parts.append(episodeTitle) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let subtitleText {
                    Text(subtitleText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if isLiveTV {
                barButton("chevron.down") { controller.press(.channelDown) }
                barButton("chevron.up") { controller.press(.channelUp) }
            } else {
                barButton(controller.state.isMediaPlaying == true ? "pause.fill" : "play.fill") {
                    controller.press(controller.state.isMediaPlaying == true ? .pause : .play)
                }
            }

            barButton(controller.state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                controller.toggleMute()
            }
            barButton("minus") { controller.press(.volumeDown) }
            barButton("plus") { controller.press(.volumeUp) }

            Picker("", selection: $controller.previewSharp) {
                Text("Smoother").tag(false)
                Text("Sharper").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func barButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 32, height: 32)
            .background(Palette.key, in: Circle())
            .tapPress(shape: Circle(), action)
    }
}
