import Foundation
import ZapperKit

/// One row in the search dropdown. Local rows (channels, apps, inputs) come
/// straight from the TV's own catalogues; content rows from availability
/// search, already filtered to services the TV actually has installed.
enum Suggestion: Identifiable, Hashable {
    case channel(TVChannel)
    case app(DeviceApp)
    case input(DeviceInput)
    case content(ContentHit)

    var id: String {
        switch self {
        case .channel(let c): return "channel-\(c.id)-\(c.number)"
        case .app(let a):     return "app-\(a.id)"
        case .input(let i):   return "input-\(i.id)"
        case .content(let h): return "content-\(h.id)"
        }
    }
}

extension RemoteController {

    // MARK: - Query → suggestions

    func queryChanged(_ text: String) {
        selectedIndex = 0
        contentTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { suggestions = []; return }

        suggestions = localMatches(trimmed)

        // Digits are channel tuning; content search wants at least two letters.
        guard trimmed.count >= 2, !trimmed.allSatisfy(\.isNumber) else { return }
        contentTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let country = Locale.current.region?.identifier ?? "US"
            let hits = (try? await ContentSearch.search(trimmed, country: country)) ?? []
            guard !Task.isCancelled, let self else { return }
            let playable: [Suggestion] = hits.compactMap { hit in
                let installed = hit.offers.filter { self.appForProvider($0.providerName) != nil }
                guard !installed.isEmpty else { return nil }
                return .content(ContentHit(id: hit.id, title: hit.title, year: hit.year,
                                           isShow: hit.isShow, offers: installed))
            }
            self.suggestions = self.localMatches(trimmed) + playable.prefix(4)
        }
    }

    private func localMatches(_ query: String) -> [Suggestion] {
        if query.allSatisfy(\.isNumber) {
            // The list can hold several tuner sources; one row per number.
            var seen = Set<String>()
            let matches = channelsList
                .filter { $0.number == query || $0.number.hasPrefix(query) }
                .filter { seen.insert($0.number).inserted }
                .sorted { ($0.number == query ? 0 : 1, $0.number.count) < ($1.number == query ? 0 : 1, $1.number.count) }
                .prefix(5)
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
            .prefix(3)
            .map(Suggestion.app)
        var seen = Set<String>()
        out += channelsList
            .filter { $0.name.lowercased().contains(lower) && seen.insert($0.number).inserted }
            .prefix(3)
            .map(Suggestion.channel)
        out += inputs
            .filter { $0.label.lowercased().contains(lower) }
            .prefix(2)
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
        case .content(let hit): play(hit)
        }
        clearSearch()
    }

    /// Launches the title. Preference order when it's on several services:
    /// the one named explicitly (a chip click), the app already open on the
    /// TV, quick-launch order, then whatever's first. Resume position is the
    /// app's own — Netflix and HBO pick up where you left off.
    func play(_ hit: ContentHit, via providerName: String? = nil) {
        let candidates: [(offer: ContentHit.Offer, app: DeviceApp)] = hit.offers.compactMap { offer in
            guard let app = appForProvider(offer.providerName) else { return nil }
            return (offer, app)
        }
        guard !candidates.isEmpty else { return }

        let chosen = providerName.flatMap { name in candidates.first { $0.offer.providerName == name } }
            ?? candidates.first { $0.app.id == state.currentAppID }
            ?? quickApps.compactMap { quick in candidates.first { $0.app.id == quick?.id } }.first
            ?? candidates[0]

        launch(chosen.app, contentTarget: chosen.offer.url)
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
