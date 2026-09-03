import SwiftUI
import ZapperKit

/// The inline extended view for whatever's on the TV right now, opened by
/// clicking the now-playing line in the header. App-specific: Live TV gets a
/// live thumbnail + EPG progress, streaming apps get poster, a real-time
/// trackbar (extrapolated between overlay sightings) and an episode strip.
struct NowPlayingSection: View {
    @ObservedObject var controller: RemoteController

    private var isLiveTV: Bool { controller.state.currentAppID == "com.webos.app.livetv" }

    var body: some View {
        VStack(spacing: 8) {
            if isLiveTV {
                liveTVPanel
            } else {
                streamingPanel
            }
        }
        .padding(10)
        .background(Palette.key, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Live TV

    @ViewBuilder
    private var liveTVPanel: some View {
        if let thumbnail = controller.liveThumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .tapPress { controller.presentPreview?() }
                .help("Open the full-size preview")
        }
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.state.currentChannel ?? "Live TV")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let program = controller.currentProgram {
                    Text(program.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            channelButton("arrow.up.left.and.arrow.down.right") { controller.presentPreview?() }
                .help("Open the full-size preview")
            channelButton("chevron.down") { controller.press(.channelDown) }
            channelButton("chevron.up") { controller.press(.channelUp) }
        }
        if let program = controller.currentProgram {
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                let total = program.end.timeIntervalSince(program.start)
                let done = min(max(Date().timeIntervalSince(program.start), 0), total)
                VStack(spacing: 2) {
                    progressBar(fraction: total > 0 ? done / total : 0)
                    HStack {
                        Text(program.start, style: .time)
                        Spacer()
                        Text(program.end, style: .time)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func channelButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 26, height: 26)
            .background(Palette.key, in: Circle())
            .tapPress(shape: Circle(), action)
    }

    // MARK: - Streaming apps

    @ViewBuilder
    private var streamingPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let poster = controller.nowPlayingPoster {
                    Image(nsImage: poster)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.key)
                }
            }
            .frame(width: 52, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.nowPlaying.showTitle ?? currentAppLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let line = episodeLine {
                    Text(line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(playStateLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                if controller.nowPlaying.showTitle == nil {
                    Text("Pause on the TV once and I'll read what's playing.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Palette.key, in: Circle())
                .tapPress(shape: Circle()) { controller.presentPreview?() }
                .help("Open the full-size preview")
        }

        trackbar
        transportRow

        if !controller.episodeStrip.isEmpty {
            episodeStripView
        }
    }

    private var currentAppLabel: String {
        controller.apps.first { $0.id == controller.state.currentAppID }?.label ?? "Now Playing"
    }

    private var episodeLine: String? {
        let playing = controller.nowPlaying
        var parts: [String] = []
        if let season = playing.season, let episode = playing.episode {
            parts.append("S\(season) E\(episode)")
        }
        if let title = playing.episodeTitle { parts.append(title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var playStateLabel: String {
        switch controller.state.isMediaPlaying {
        case true?:  return "Playing"
        case false?: return "Paused"
        default:     return " "
        }
    }

    @ViewBuilder
    private var trackbar: some View {
        if controller.nowPlaying.duration != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let playing = controller.nowPlaying
                let duration = playing.duration ?? 1
                let position = playing.livePosition(playing: controller.state.isMediaPlaying) ?? 0
                VStack(spacing: 2) {
                    progressBar(fraction: min(position / duration, 1))
                    HStack {
                        Text(Self.clock(position))
                        Spacer()
                        Text(Self.clock(duration))
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 22) {
            transportButton("gobackward.10", size: 13) { controller.press(.rewind) }
            transportButton(
                controller.state.isMediaPlaying == true ? "pause.fill" : "play.fill",
                size: 17, diameter: 40
            ) {
                controller.press(controller.state.isMediaPlaying == true ? .pause : .play)
            }
            transportButton("goforward.10", size: 13) { controller.press(.fastForward) }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        _ symbol: String, size: CGFloat, diameter: CGFloat = 32, action: @escaping () -> Void
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .frame(width: diameter, height: diameter)
            .background(Palette.key, in: Circle())
            .tapPress(shape: Circle(), action)
    }

    @ViewBuilder
    private var episodeStripView: some View {
        if Showcase.isRendering {
            // ImageRenderer can't draw ScrollView content; show the window
            // around the current episode that the real strip scrolls to.
            let episodes = controller.episodeStrip
            let current = episodes.firstIndex { $0.number == controller.nowPlaying.episode } ?? 0
            let start = max(current - 1, 0)
            HStack(spacing: 6) {
                ForEach(episodes[start..<min(start + 3, episodes.count)]) { episodeCard($0) }
            }
            .frame(height: 52, alignment: .leading)
        } else {
            realEpisodeStrip
        }
    }

    private var realEpisodeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(controller.episodeStrip) { episode in
                        episodeCard(episode)
                            .id(episode.number)
                    }
                }
            }
            .onAppear {
                if let current = controller.nowPlaying.episode {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
            .onChange(of: controller.episodeStrip) { _, _ in
                if let current = controller.nowPlaying.episode {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
        .frame(height: 52)
    }

    private func episodeCard(_ episode: EpisodeInfo) -> some View {
        let isCurrent = episode.number == controller.nowPlaying.episode
        return VStack(alignment: .leading, spacing: 1) {
            Text("E\(episode.number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
            Text(episode.title)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(6)
        .frame(width: 88, height: 48, alignment: .topLeading)
        .background(
            isCurrent ? Palette.accentKey : Palette.key,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .tapPress { controller.playEpisode(episode) }
    }

    // MARK: - Shared bits

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(geo.size.width * fraction, 3))
            }
        }
        .frame(height: 3)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
