import Foundation

/// Plays a specific title by driving the TV's own universal search
/// (`com.webos.app.voice`) — the only launch path streaming apps honour on
/// this firmware, and fast: the whole query is injected through the system
/// IME in one call, so there's no on-screen keyboard walking. The flow is
/// open search → inject text → enter → pick suggestion → pick the
/// best-matching result card → LG hands off to the app with its blessed
/// deep link.
public final class UniversalSearch {

    private let device: WebOSDevice
    private let onStatus: @MainActor (String) -> Void

    public init(device: WebOSDevice, onStatus: @escaping @MainActor (String) -> Void = { _ in }) {
        self.device = device
        self.onStatus = onStatus
    }

    /// Runs the search hand-off. Returns true once a result card was
    /// activated; the app-side supervisor takes it from there (profile
    /// gates, title-page play button). When a target app is given it is
    /// launched first, so the results' "Current App" row belongs to it and
    /// the hand-off can't drift to whatever app happened to be open.
    public func play(query: String, preferAppID: String? = nil, preferAppLabel: String? = nil) async -> Bool {
        if let preferAppID {
            try? await device.launchApp(id: preferAppID, contentTarget: nil)
            try? await sleep(3500)
        }
        try? await device.launchApp(id: "com.webos.app.voice", contentTarget: nil)
        try? await sleep(3500)

        // Inject the query; verify it landed, retrying while the field wakes.
        var typed = false
        for _ in 0..<3 {
            guard !Task.isCancelled else { return false }
            try? await device.insertText(query)
            try? await sleep(1200)
            let text = await ocrText()
            if text.lowercased().contains(query.lowercased().prefix(8)) { typed = true; break }
        }
        guard typed else { return false }

        try? await device.imeEnter()
        try? await sleep(1200)
        await tap(.down)          // onto the suggestion list
        await tap(.ok, ms: 4000)  // open full results

        // Find the result card whose label matches the query best.
        guard let frame = try? await device.captureScreen() else { return false }
        let lines = ScreenText.lines(jpeg: frame)
        guard let target = Self.bestCard(for: query, in: lines, preferAppLabel: preferAppLabel) else {
            // No labels read? Take the focused first card as a best effort.
            await tap(.ok, ms: 1000)
            return true
        }
        if target.row > 0 {
            for _ in 0..<target.row { await tap(.down, ms: 450) }
        }
        for _ in 0..<target.column { await tap(.right, ms: 450) }
        await tap(.ok, ms: 1000)
        return true
    }

    struct CardTarget { let row: Int; let column: Int; let title: String }

    /// Result cards are poster tiles with 1–2 line labels; section headers
    /// ("Current App (Netflix)", "TV Shows", "Movies") separate rows. Focus
    /// starts on the first card of the first row.
    static func bestCard(for query: String, in lines: [ScreenText.Line],
                         preferAppLabel: String? = nil) -> CardTarget? {
        let headers = ["current app", "tv shows", "movies", "apps", "live", "youtube"]
        let headerLines = lines.filter { line in
            headers.contains(where: line.text.lowercased().contains)
        }
        // Labels live below the search field (y < 0.88) and are short.
        let labels = lines.filter { line in
            line.box.maxY < 0.88 && line.text.count >= 2 && line.text.count <= 40
                && !headers.contains(where: line.text.lowercased().contains)
        }
        guard !labels.isEmpty else { return nil }

        // Merge wrapped labels: same card ⇢ same left edge, small y gap.
        var cards: [(title: String, x: Double, y: Double)] = []
        for label in labels.sorted(by: { $0.box.maxY > $1.box.maxY }) {
            if let index = cards.firstIndex(where: {
                abs($0.x - label.box.minX) < 0.025 && abs($0.y - label.box.maxY) < 0.09
            }) {
                cards[index].title += " " + label.text
                cards[index].y = min(cards[index].y, Double(label.box.minY))
            } else {
                cards.append((label.text, label.box.minX, label.box.maxY))
            }
        }

        // Rows: cluster by y (top first), columns by x.
        var rows: [[(title: String, x: Double, y: Double)]] = []
        for card in cards.sorted(by: { $0.y > $1.y }) {
            if let index = rows.firstIndex(where: { abs($0[0].y - card.y) < 0.12 }) {
                rows[index].append(card)
            } else {
                rows.append([card])
            }
        }
        for index in rows.indices { rows[index].sort { $0.x < $1.x } }

        // Score every card; earlier rows win ties (fewer presses, and the
        // "Current App" row lists the target app's own hits). When a target
        // app was requested, its row — the one under a header naming it —
        // gets a strong boost so the hand-off can't drift to another app.
        let want = query.searchNormalized
        let preferLabel = preferAppLabel?.lowercased()
        var best: (score: Int, target: CardTarget)? = nil
        for (rowIndex, row) in rows.enumerated() {
            // The header for this row: the nearest header line just above it.
            let rowTop = row[0].y
            let header = headerLines
                .filter { Double($0.box.minY) > rowTop }
                .min { Double($0.box.minY) - rowTop < Double($1.box.minY) - rowTop }
            let rowBoost: Int
            if let preferLabel, let header, header.text.lowercased().contains(preferLabel) {
                rowBoost = 4
            } else {
                rowBoost = 0
            }
            for (columnIndex, card) in row.enumerated() {
                let name = card.title
                    .replacingOccurrences(of: "…", with: "")
                    .searchNormalized
                let score: Int
                if name == want { score = 3 }
                else if name.hasPrefix(want) || want.hasPrefix(name) { score = 2 }
                else if name.contains(want) || want.contains(name) { score = 1 }
                else { score = 0 }
                guard score > 0 else { continue }
                if score + rowBoost > (best?.score ?? 0) {
                    best = (score + rowBoost, CardTarget(row: rowIndex, column: columnIndex, title: card.title))
                }
            }
        }
        return best?.target
    }

    // MARK: - Primitives

    private func tap(_ key: RemoteKey, ms: UInt64 = 500) async {
        try? await device.press(key)
        try? await sleep(ms)
    }

    private func sleep(_ ms: UInt64) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func ocrText() async -> String {
        guard let frame = try? await device.captureScreen() else { return "" }
        return ScreenText.read(jpeg: frame)
    }
}
