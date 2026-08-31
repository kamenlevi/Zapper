import Foundation
import ZapperKit

/// "friends s1 e4" → the show title plus the episode being asked for.
struct EpisodeRef: Hashable {
    let season: Int
    let episode: Int
}

/// One row in the search dropdown. Local rows (channels, apps, inputs) come
/// straight from the TV's own catalogues; content rows from availability
/// search, already filtered to services the TV actually has installed;
/// in-app rows hand the query to an app's own search (Spotify, YouTube).
enum Suggestion: Identifiable, Hashable {
    case channel(TVChannel)
    case app(DeviceApp)
    case input(DeviceInput)
    case content(ContentHit, EpisodeRef?)
    case spotify(SpotifyItem)
    case inAppSearch(DeviceApp, String)

    var id: String {
        switch self {
        case .channel(let c):       return "channel-\(c.id)-\(c.number)"
        case .app(let a):           return "app-\(a.id)"
        case .input(let i):         return "input-\(i.id)"
        case .content(let h, let e): return "content-\(h.id)-\(e.map { "s\($0.season)e\($0.episode)" } ?? "")"
        case .spotify(let s):       return "spotify-\(s.uri)"
        case .inAppSearch(let a, _): return "inapp-\(a.id)"
        }
    }
}

extension RemoteController {

    /// Keeps the dropdown a dropdown, not a page.
    private static let maxRows = 6

    /// Apps whose search can be deep-linked into directly. %@ is replaced
    /// with the percent-encoded query.
    private static let inAppSearchTargets: [String: String] = [
        "spotify-beehive": "spotify:search:%@",
        "youtube.leanback.v4": "https://www.youtube.com/results?search_query=%@",
    ]

    // MARK: - Query → suggestions

    func queryChanged(_ text: String) {
        selectedIndex = 0
        contentTask?.cancel()
        spotifyTask?.cancel()
        contentBucket = []
        spotifyBucket = []
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { suggestions = []; return }

        let (title, episodeRef) = Self.parseEpisode(trimmed)
        reassemble(trimmed)

        // Digits are channel tuning; content search wants at least two letters.
        guard title.count >= 2, !title.allSatisfy(\.isNumber) else { return }
        contentTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let country = Locale.current.region?.identifier ?? "US"
            let hits = (try? await ContentSearch.search(title, country: country)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.contentBucket = hits.compactMap { hit in
                let installed = hit.offers.filter { self.appForProvider($0.providerName) != nil }
                guard !installed.isEmpty else { return nil }
                let pruned = ContentHit(id: hit.id, title: hit.title, year: hit.year,
                                        isShow: hit.isShow, offers: installed)
                // An episode request only makes sense against a show.
                return .content(pruned, hit.isShow ? episodeRef : nil)
            }
            self.reassemble(trimmed)
        }
        guard SpotifyClient.shared.isConnected else { return }
        spotifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let items = (try? await SpotifyClient.shared.search(trimmed)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.spotifyBucket = items.map(Suggestion.spotify)
            self.reassemble(trimmed)
        }
    }

    /// "friends s1 e4", "friends season 1 episode 4", "friends s01e04".
    static func parseEpisode(_ query: String) -> (title: String, ref: EpisodeRef?) {
        let pattern = #/^(.*\S)\s+s(?:eason)?\s*(\d{1,2})\s*[ .x-]*\s*e(?:p(?:isode)?)?\s*(\d{1,3})\s*$/#
            .ignoresCase()
        guard let match = query.wholeMatch(of: pattern),
              let season = Int(match.2), let episode = Int(match.3)
        else { return (query, nil) }
        return (String(match.1), EpisodeRef(season: season, episode: episode))
    }

    private func reassemble(_ query: String) {
        let local = localMatches(query)
        var rows: [Suggestion] = []

        // A Spotify artist whose name starts with the query is almost
        // certainly what was typed — "the weeknd" ⏎ should be his page.
        var spotify = spotifyBucket
        if case .spotify(let item)? = spotify.first,
           item.kind == .artist || item.isOwn,
           item.name.lowercased().hasPrefix(query.lowercased()) {
            rows.append(spotify.removeFirst())
        }

        rows += local.prefix(2)
        rows += contentBucket.prefix(2)
        rows += spotify.prefix(2)

        // Backfill whatever room is left, most useful bucket first.
        for extras in [contentBucket.dropFirst(2), spotify.dropFirst(2), local.dropFirst(2)] {
            guard rows.count < Self.maxRows else { break }
            rows += extras.prefix(Self.maxRows - rows.count)
        }

        // One in-app hand-off at the end when an app supports it — Spotify's
        // only until the account is connected (then results come inline).
        if query.count >= 2, !query.allSatisfy(\.isNumber) {
            for (appID, _) in Self.inAppSearchTargets {
                if rows.count >= Self.maxRows { break }
                if appID == "spotify-beehive", SpotifyClient.shared.isConnected { continue }
                if let app = apps.first(where: { $0.id == appID }) {
                    rows.append(.inAppSearch(app, query))
                }
            }
        }
        suggestions = Array(rows.prefix(Self.maxRows))
    }

    private func localMatches(_ query: String) -> [Suggestion] {
        if query.allSatisfy(\.isNumber) {
            // The list can hold several tuner sources; one row per number.
            var seen = Set<String>()
            let matches = channelsList
                .filter { $0.number == query || $0.number.hasPrefix(query) }
                .filter { seen.insert($0.number).inserted }
                .sorted { ($0.number == query ? 0 : 1, $0.number.count) < ($1.number == query ? 0 : 1, $1.number.count) }
                .prefix(4)
            if matches.isEmpty {
                // No list yet (TV just woke, or list not loaded): still offer
                // direct tuning to the typed number.
                return [.channel(TVChannel(id: "direct", number: query, name: "Channel \(query)"))]
            }
            return matches.map(Suggestion.channel)
        }

        let lower = query.lowercased()
        var out: [Suggestion] = []
        out += apps
            .filter { $0.label.lowercased().contains(lower) }
            .sorted { ($0.label.lowercased().hasPrefix(lower) ? 0 : 1) < ($1.label.lowercased().hasPrefix(lower) ? 0 : 1) }
            .prefix(2)
            .map(Suggestion.app)
        var seen = Set<String>()
        out += channelsList
            .filter { $0.name.lowercased().contains(lower) && seen.insert($0.number).inserted }
            .prefix(2)
            .map(Suggestion.channel)
        out += inputs
            .filter { $0.label.lowercased().contains(lower) }
            .prefix(1)
            .map(Suggestion.input)
        return out
    }

    // MARK: - Selection & execution

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), suggestions.count - 1)
    }

    func clearSearch() {
        searchText = ""
        suggestions = []
        selectedIndex = 0
        contentTask?.cancel()
        spotifyTask?.cancel()
        contentBucket = []
        spotifyBucket = []
    }

    func executeSelected() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if suggestions.indices.contains(selectedIndex) {
            execute(suggestions[selectedIndex])
        } else if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) {
            openChannel(trimmed)
            clearSearch()
        }
    }

    func execute(_ suggestion: Suggestion) {
        switch suggestion {
        case .channel(let ch): openChannel(ch.number)
        case .app(let app):    launch(app)
        case .input(let inp):  switchInput(inp)
        case .content(let hit, let ref): play(hit, episode: ref)
        case .spotify(let item):  playSpotify(item)
        case .inAppSearch(let app, let query): searchInApp(app, query: query)
        }
        clearSearch()
    }

    /// Opens the item in the TV's Spotify app via its spotify: URI.
    func playSpotify(_ item: SpotifyItem) {
        guard let app = apps.first(where: { $0.id == "spotify-beehive" }) else {
            flash("Spotify isn't installed on the TV.")
            return
        }
        launch(app, contentTarget: item.uri)
        flash("Opening \(item.name) in Spotify.")
    }

    /// Hands the query to the app's own search (spotify:search:…, YouTube
    /// results page). Playback continues on the TV from there.
    func searchInApp(_ app: DeviceApp, query: String) {
        guard let template = Self.inAppSearchTargets[app.id],
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { launch(app); return }
        launch(app, contentTarget: template.replacingOccurrences(of: "%@", with: encoded))
    }

    /// Launches the title. Preference order when it's on several services:
    /// the one named explicitly (a chip click), the app already open on the
    /// TV, quick-launch order, then whatever's first. For episode requests,
    /// services with a true per-episode link (HBO Max) beat ones that can
    /// only open the show (Netflix). Resume position is the app's own.
    func play(_ hit: ContentHit, episode: EpisodeRef? = nil, via providerName: String? = nil) {
        guard let episode else {
            playOffers(hit.offers, title: hit.title, via: providerName)
            return
        }
        Task { [weak self] in
            let country = Locale.current.region?.identifier ?? "US"
            let offers = (try? await ContentSearch.episodeOffers(
                showID: hit.id, season: episode.season, episode: episode.episode, country: country
            )) ?? []
            guard let self else { return }
            if offers.isEmpty {
                self.flash("No link for S\(episode.season) E\(episode.episode) — opening the show.")
                self.playOffers(hit.offers, title: hit.title, via: providerName)
                return
            }
            // Which services actually link to the episode, not just the show?
            let showURLs = Set(hit.offers.map(\.url))
            let episodeSpecific = offers.filter { !showURLs.contains($0.url) }
            let preferred = providerName != nil ? offers
                : (episodeSpecific.isEmpty ? offers : episodeSpecific)
            self.playOffers(preferred, title: "\(hit.title) S\(episode.season) E\(episode.episode)",
                            via: providerName)
        }
    }

    private func playOffers(_ offers: [ContentHit.Offer], title: String, via providerName: String?) {
        let candidates: [(offer: ContentHit.Offer, app: DeviceApp)] = offers.compactMap { offer in
            guard let app = appForProvider(offer.providerName) else { return nil }
            return (offer, app)
        }
        guard !candidates.isEmpty else {
            flash("None of the TV's apps carry \(title).")
            return
        }

        let chosen = providerName.flatMap { name in candidates.first { $0.offer.providerName == name } }
            ?? candidates.first { $0.app.id == state.currentAppID }
            ?? quickApps.compactMap { quick in candidates.first { $0.app.id == quick?.id } }.first
            ?? candidates[0]

        launch(chosen.app, contentTarget: chosen.offer.url)
        flash("Playing \(title) on \(chosen.app.label).")
    }

    /// JustWatch service names → webOS app ids, with a label match as the
    /// net for anything not in the table. Only installed apps count.
    func appForProvider(_ name: String) -> DeviceApp? {
        let known: [String: String] = [
            "netflix": "netflix",
            "hbo max": "com.wbd.stream",
            "max": "com.wbd.stream",
            "disney plus": "com.disney.disneyplus-prod",
            "disney+": "com.disney.disneyplus-prod",
            "amazon video": "amazon",
            "amazon prime video": "amazon",
            "prime video": "amazon",
            "apple tv plus": "com.apple.appletv",
            "apple tv+": "com.apple.appletv",
            "apple tv": "com.apple.appletv",
            "skyshowtime": "com.skyshowtime.tv",
            "youtube": "youtube.leanback.v4",
            "rakuten tv": "ui30",
            "voyo": "voyo.bg",
            "sweet.tv": "sweet.tv",
        ]
        if let id = known[name.lowercased()], let app = apps.first(where: { $0.id == id }) {
            return app
        }
        return apps.first { $0.label.caseInsensitiveCompare(name) == .orderedSame }
    }
}
