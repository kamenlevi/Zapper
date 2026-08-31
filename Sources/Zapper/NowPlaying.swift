import AppKit
import Foundation
import ZapperKit

/// Everything Zapper currently believes about what's on screen, accumulated
/// from overlay sightings (OCR) and from launches Zapper itself performed.
struct NowPlayingState {
    var appID: String?
    var showTitle: String?
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var position: TimeInterval?
    var duration: TimeInterval?
    /// When `position` was last read off the screen — playback time is
    /// extrapolated from here while the app reports "playing".
    var syncedAt: Date?
    /// JustWatch node id, once the title has been resolved.
    var contentID: String?

    var hasAnything: Bool { showTitle != nil || position != nil }

    func livePosition(playing: Bool?) -> TimeInterval? {
        guard let position else { return nil }
        guard playing == true, let syncedAt else { return position }
        let advanced = position + Date().timeIntervalSince(syncedAt)
        return duration.map { min(advanced, $0) } ?? advanced
    }

    mutating func merge(_ snapshot: NowPlayingSnapshot) {
        if let title = snapshot.showTitle, title != showTitle {
            // A different show: everything derived from the old one is stale.
            showTitle = title
            contentID = nil
            episodeTitle = nil
        }
        if let season = snapshot.season { self.season = season }
        if let episode = snapshot.episode { self.episode = episode }
        if let episodeTitle = snapshot.episodeTitle { self.episodeTitle = episodeTitle }
        if let position = snapshot.position {
            self.position = position
            if let duration = snapshot.duration { self.duration = duration }
            syncedAt = Date()
        }
    }
}

extension RemoteController {

    /// Fills in what OCR can't: the JustWatch identity behind the title,
    /// its poster, and the episode strip around the current episode.
    func resolveNowPlayingContext() {
        guard !nowPlayingResolving else { return }

        // 1. Title → JustWatch id + poster.
        if nowPlaying.contentID == nil, let title = nowPlaying.showTitle {
            nowPlayingResolving = true
            Task { [weak self] in
                defer { self?.nowPlayingResolving = false }
                let country = Locale.current.region?.identifier ?? "US"
                let hits = (try? await ContentSearch.search(title, country: country)) ?? []
                guard let self, title == self.nowPlaying.showTitle else { return }
                let normalized = title.searchNormalized
                guard let hit = hits.first(where: { $0.title.searchNormalized == normalized })
                    ?? hits.first else { return }
                self.nowPlaying.contentID = hit.id
                if let url = hit.posterURL {
                    let data = try? await URLSession.shared.data(from: url).0
                    if title == self.nowPlaying.showTitle {
                        self.nowPlayingPoster = data.flatMap { NSImage(data: $0) }
                    }
                }
                self.resolveNowPlayingContext()
            }
            return
        }

        // 2. id + season → episode strip.
        if let id = nowPlaying.contentID, let season = nowPlaying.season {
            let key = "\(id)-s\(season)"
            guard episodeStripKey != key else { return }
            episodeStripKey = key
            Task { [weak self] in
                let country = Locale.current.region?.identifier ?? "US"
                let episodes = (try? await ContentSearch.seasonEpisodes(
                    showID: id, season: season, country: country)) ?? []
                guard let self, self.episodeStripKey == key else { return }
                self.episodeStrip = episodes
            }
        }
    }

    /// Plays one episode from the strip, preferring true episode deep links.
    func playEpisode(_ episodeInfo: EpisodeInfo) {
        let playable = episodeInfo.offers.filter { appForProvider($0.providerName) != nil }
        guard !playable.isEmpty else {
            flash("None of the TV's apps carry that episode.")
            return
        }
        nowPlaying.episode = episodeInfo.number
        nowPlaying.episodeTitle = episodeInfo.title
        nowPlaying.position = nil
        nowPlaying.syncedAt = nil
        playOffers(playable, title: "E\(episodeInfo.number) · \(episodeInfo.title)",
                   query: nowPlaying.showTitle ?? episodeInfo.title, via: nil)
    }

    func clearNowPlayingContext(newAppID: String?) {
        nowPlaying = NowPlayingState(appID: newAppID)
        nowPlayingPoster = nil
        episodeStrip = []
        episodeStripKey = nil
        currentProgram = nil
        liveThumbnail = nil
    }
}
