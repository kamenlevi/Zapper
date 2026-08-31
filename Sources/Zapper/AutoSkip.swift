import Foundation
import CoreGraphics
import ImageIO
import Vision
import ZapperKit

/// Watches the TV screen while a streaming app is playing and presses OK the
/// moment a "Skip Intro"-style prompt appears. The TV's capture endpoint
/// blacks out DRM'd video but keeps app UI overlays, so the prompts are
/// visible; frames are OCR'd locally with Vision and discarded immediately.
enum AutoSkip {

    struct Settings {
        var enabled: Bool
        var intros: Bool
        var recaps: Bool
        var stillWatching: Bool

        static let enabledKey = "Zapper.autoSkip.enabled"
        static let introsKey = "Zapper.autoSkip.intros"
        static let recapsKey = "Zapper.autoSkip.recaps"
        static let stillWatchingKey = "Zapper.autoSkip.stillWatching"

        static func load() -> Settings {
            let defaults = UserDefaults.standard
            func flag(_ key: String, default value: Bool) -> Bool {
                defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
            }
            return Settings(
                enabled: flag(enabledKey, default: false),
                intros: flag(introsKey, default: true),
                recaps: flag(recapsKey, default: true),
                stillWatching: flag(stillWatchingKey, default: true)
            )
        }
    }

    /// Apps whose playback shows skippable prompts.
    static let videoApps: Set<String> = [
        "netflix", "com.wbd.stream", "com.disney.disneyplus-prod", "amazon",
        "com.apple.appletv", "com.skyshowtime.tv", "ui30", "voyo.bg", "sweet.tv",
    ]

    /// What was matched, so the caller can report it.
    enum Prompt {
        case intro, recap, stillWatching

        var message: String {
            switch self {
            case .intro:         return "Skipped an intro."
            case .recap:         return "Skipped a recap."
            case .stillWatching: return "Kept playback going."
            }
        }
    }

    private static let introPhrases = ["skip intro", "прескочи интрото", "пропусни интрото"]
    private static let recapPhrases = ["skip recap", "прескочи резюмето"]
    private static let stillWatchingPhrases = [
        "are you still watching", "still watching", "continue watching",
        "гледате ли още", "продължи гледането",
    ]

    /// OCRs one captured frame and returns the first enabled prompt found.
    static func detectPrompt(in jpeg: Data, settings: Settings) -> Prompt? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results
        else { return nil }

        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .lowercased()

        if settings.intros, introPhrases.contains(where: text.contains) { return .intro }
        if settings.recaps, recapPhrases.contains(where: text.contains) { return .recap }
        if settings.stillWatching, stillWatchingPhrases.contains(where: text.contains) { return .stillWatching }
        return nil
    }
}
