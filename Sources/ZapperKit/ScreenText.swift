import Foundation
import CoreGraphics
import ImageIO
import Vision

/// On-device OCR over TV screen captures, plus the parser that turns a
/// streaming app's transport overlay into structured now-playing facts.
public enum ScreenText {

    public struct Line: Sendable {
        public let text: String
        /// Vision-normalised bounding box: origin bottom-left, 0...1.
        public let box: CGRect
    }

    /// All recognized text in the frame with positions. Accurate recognition:
    /// the fast path mangles stylised app fonts ("Frlends", "03=31").
    public static func lines(jpeg: Data) -> [Line] {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        return results.compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            return Line(text: top.string, box: observation.boundingBox)
        }
    }

    /// All recognized text in the frame, one observation per line.
    public static func read(jpeg: Data) -> String {
        lines(jpeg: jpeg).map(\.text).joined(separator: "\n")
    }

    /// Finds the focused "pill" in a nav bar: a solid near-white rounded
    /// rect that only the focused item has. Scans the pixel band at the
    /// given Vision-normalised (bottom-origin) y for the widest bright run
    /// and returns its centre x, normalised 0...1. Nil when nothing on that
    /// row is focused.
    public static func focusPillX(jpeg: Data, nearY y: Double, ignoringLeft: Double = 0) -> Double? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data,
              let base = CFDataGetBytePtr(data)
        else { return nil }

        let width = image.width, height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }

        let centerRow = Int((1 - y) * Double(height))
        let band = max(4, height / 54)  // ≈ pill half-height
        let rows = max(centerRow - band, 0)...min(centerRow + band, height - 1)

        // A column belongs to the pill when most of the band is near-white
        // (solid background); text strokes alone don't reach that density.
        var brightFraction = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var bright = 0
            for row in rows {
                let p = row * bytesPerRow + x * bytesPerPixel
                if base[p] > 205, base[p + 1] > 205, base[p + 2] > 205 { bright += 1 }
            }
            brightFraction[x] = Double(bright) / Double(rows.count)
        }

        let minX = Int(ignoringLeft * Double(width))
        var bestRun = (start: 0, length: 0)
        var runStart: Int? = nil
        for x in minX...width {
            let isPill = x < width && brightFraction[x] > 0.4
            if isPill, runStart == nil { runStart = x }
            if !isPill, let start = runStart {
                if x - start > bestRun.length { bestRun = (start, x - start) }
                runStart = nil
            }
        }
        // Narrower than ~2% of the screen is stray text, not a pill.
        guard bestRun.length > width / 50 else { return nil }
        return (Double(bestRun.start) + Double(bestRun.length) / 2) / Double(width)
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

        // OCR of stylised overlays is dirty: S reads as 5, ":" as "=" or
        // "..", quotes as degree signs. The patterns absorb all of that.
        let seasonEpisode = #/[s5](?:eason)?\s*(\d{1,2})\s*[:.,]*\s*e(?:p(?:isode)?)?\.?\s*(\d{1,3})/#.ignoresCase()
        let quoted = #/["“'°]([^"“”'°]{2,60})["”'°]/#
        let clock = #/\b(?:(\d{1,2})[:=])?(\d{1,2})[:=](\d{2})\b/#

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

        // The timeline's two clocks read elapsed on the left and REMAINING on
        // the right (Netflix style), in that order — total is their sum.
        let times = ocrText.matches(of: clock).map { match -> TimeInterval in
            let hours = match.1.flatMap { Double($0) } ?? 0
            let minutes = Double(match.2) ?? 0
            let seconds = Double(match.3) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        }
        if times.count == 2 {
            let position = times[0]
            let duration = times[0] + times[1]
            if duration >= 60, position <= duration {
                snapshot.position = position
                snapshot.duration = duration
            }
        }
        return snapshot
    }
}
