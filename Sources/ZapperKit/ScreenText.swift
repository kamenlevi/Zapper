import Foundation
import CoreGraphics
import ImageIO
import Vision

/// On-device OCR over TV screen captures, plus the parser that turns a
/// streaming app's transport overlay into structured now-playing facts.
public enum ScreenText {

    /// All recognized text in the frame, one observation per line.
    public static func read(jpeg: Data) -> String {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let results = request.results else { return "" }
        return results
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

/// What a transport overlay reveals about the current playback, in whatever
/// combination was legible — fields are nil when that part wasn't on screen.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var showTitle: String?
    public var season: Int?
    public var episode: Int?
    public var episodeTitle: String?
    /// Seconds elapsed / total, when the timeline was visible.
    public var position: TimeInterval?
    public var duration: TimeInterval?

    public var isEmpty: Bool {
        showTitle == nil && season == nil && position == nil
    }

    /// Parses OCR text of a Netflix/HBO-style overlay:
    ///     Friends
    ///     S9: E20 "The One with the Soap Opera Party"
    ///     07:52   ...   16:00
    public static func parse(ocrText: String) -> NowPlayingSnapshot {
        var snapshot = NowPlayingSnapshot()
        let lines = ocrText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let seasonEpisode = #/s(?:eason)?\s*(\d{1,2})\s*[:.]?\s*e(?:p(?:isode)?)?\s*(\d{1,3})/#.ignoresCase()
        let quoted = #/["“'']([^"“”'']{2,60})["”'']/#
        let clock = #/\b(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\b/#

        for (index, line) in lines.enumerated() {
            guard let match = line.firstMatch(of: seasonEpisode) else { continue }
            snapshot.season = Int(match.1)
            snapshot.episode = Int(match.2)
            if let title = line.firstMatch(of: quoted).map({ String($0.1) }) {
                snapshot.episodeTitle = title
            }
            // The show name sits on its own line right before the episode
            // line; a long line there is a subtitle, not a title.
            if snapshot.showTitle == nil, index > 0 {
                let previous = lines[index - 1]
                if previous.count <= 40, previous.firstMatch(of: clock) == nil {
                    snapshot.showTitle = previous
                }
            }
            break
        }

        // Elapsed and total: the two clock readings around the timeline —
        // smaller is the position, larger the duration.
        let times = ocrText.matches(of: clock).map { match -> TimeInterval in
            let hours = match.1.flatMap { Double($0) } ?? 0
            let minutes = Double(match.2) ?? 0
            let seconds = Double(match.3) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        }
        if times.count >= 2 {
            let sorted = times.sorted()
            let position = sorted[0]
            let duration = sorted[sorted.count - 1]
            if duration > 0, position <= duration, duration >= 60 {
                snapshot.position = position
                snapshot.duration = duration
            }
        }
        return snapshot
    }
}
