import SwiftUI
import ZapperKit

/// The search field and its suggestion dropdown. The field grabs focus as
/// soon as the popover opens, so typing lands in it without a click; ↑/↓
/// move the highlight, Enter fires the highlighted row, Esc clears.
struct SearchSection: View {
    @ObservedObject var controller: RemoteController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            field
            if !controller.suggestions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(controller.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionRow(
                            controller: controller,
                            suggestion: suggestion,
                            isSelected: index == controller.selectedVisibleIndex
                        )
                    }
                }
            }
        }
        .onChange(of: controller.searchText) { _, text in controller.queryChanged(text) }
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if Showcase.isRendering {
                // ImageRenderer draws AppKit-backed controls as placeholders.
                Text(controller.searchText.isEmpty ? "Channels, apps, shows…" : controller.searchText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(controller.searchText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Channels, apps, shows…", text: $controller.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { controller.executeSelected() }
                .onKeyPress(.upArrow) { controller.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { controller.moveSelection(1); return .handled }
                .onKeyPress(.escape) {
                    guard !controller.searchText.isEmpty else { return .ignored }
                    controller.clearSearch()
                    return .handled
                }
            }

            if !controller.searchText.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .tapPress { controller.clearSearch() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Palette.key, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SuggestionRow: View {
    let controller: RemoteController
    let suggestion: Suggestion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 26, height: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if case .content(let hit, let ref, _) = suggestion {
                HStack(spacing: 3) {
                    ForEach(hit.offers, id: \.self) { offer in
                        Text(offer.providerName)
                            .font(.system(size: 8.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Palette.accentKey, in: Capsule())
                            .tapPress {
                                controller.play(hit, episode: ref, via: offer.providerName)
                                controller.clearSearch()
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            isSelected ? Palette.keyHover : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .tapPress { controller.execute(suggestion) }
    }

    @ViewBuilder
    private var icon: some View {
        switch suggestion {
        case .channel(let ch):
            Text(ch.number)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.key, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .app(let app):
            if let image = controller.quickIcons[app.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .input:
            Image(systemName: "cable.connector")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .content(let hit, _, _):
            Image(systemName: hit.isShow ? "play.tv" : "film")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .spotify(let item):
            Image(systemName: Self.spotifySymbol(item.kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .inAppSearch(let app, _):
            if let image = controller.quickIcons[app.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch suggestion {
        case .channel(let ch): return ch.name
        case .app(let app):    return app.label
        case .input(let inp):  return inp.label
        case .content(let hit, _, _): return hit.title
        case .spotify(let item):   return item.name
        case .inAppSearch(let app, let query): return "\u{201C}\(query)\u{201D} in \(app.label)"
        }
    }

    private var subtitle: String {
        switch suggestion {
        case .channel(let ch): return "Channel \(ch.number)"
        case .app:             return "Open app"
        case .input:           return "Switch input"
        case .content(let hit, let ref, _):
            let kind = hit.isShow ? "Show" : "Movie"
            var parts = [kind]
            if let year = hit.year { parts.append(String(year)) }
            if let ref { parts.append("S\(ref.season) E\(ref.episode)") }
            return parts.joined(separator: " · ")
        case .spotify(let item):
            if item.isOwn { return "Your playlist · Spotify" }
            let kind: String
            switch item.kind {
            case .artist:   kind = "Artist"
            case .track:    kind = "Song"
            case .album:    kind = "Album"
            case .playlist: kind = "Playlist"
            }
            let parts = [kind, item.detail, "Spotify"].filter { !$0.isEmpty }
            return parts.joined(separator: " · ")
        case .inAppSearch: return "Search in app"
        }
    }

    private static func spotifySymbol(_ kind: SpotifyItem.Kind) -> String {
        switch kind {
        case .artist:   return "music.microphone"
        case .track:    return "music.note"
        case .album:    return "square.stack"
        case .playlist: return "music.note.list"
        }
    }
}
