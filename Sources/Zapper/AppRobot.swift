import Foundation
import ZapperKit

/// Direct deep links are ignored by the streaming apps on this firmware, so
/// content plays through the TV's universal search hand-off (ZapperKit's
/// UniversalSearch) — instant text injection, then LG launches the app with
/// its partner-blessed link. The supervisor finishes the job on the app's
/// side (profile gate, title-page play button). When the requested show is
/// the app's last-played one, all of that is skipped: a plain launch makes
/// the app resume it by itself.
extension RemoteController {

    static func lastPlayedKey(_ appID: String) -> String { "Zapper.lastPlayed.\(appID)" }

    func recordLastPlayed(appID: String, title: String) {
        UserDefaults.standard.set(title.searchNormalized, forKey: Self.lastPlayedKey(appID))
    }

    func lastPlayed(appID: String) -> String? {
        UserDefaults.standard.string(forKey: Self.lastPlayedKey(appID))
    }

    /// The quick lane: the app resumes its own last title on a plain launch,
    /// so if that's what was asked for there's nothing to search. Falls back
    /// to the full universal-search flow when the app parks on Home instead
    /// (cold start) — detected by the nav bar being on screen.
    func fastResume(app: DeviceApp, title: String, query: String,
                    wantsShow: Bool?, exclusive: Bool) {
        supervisorTask?.cancel()
        guard let device = activeDevice else { return }
        flash("Resuming \(title) on \(app.label)\u{2026}")
        supervisorTask = Task { [weak self] in
            try? await device.launchApp(id: app.id, contentTarget: nil)
            guard let self else { return }
            await self.superviseSteps(timeout: 14)
            guard !Task.isCancelled else { return }

            let onHome = await self.robotOCRText().lowercased()
            let parkedOnHome = ["my netflix", "shows movies", "home shows"]
                .contains(where: onHome.replacingOccurrences(of: "\n", with: " ").contains)
            if self.state.isMediaPlaying == true, !parkedOnHome {
                self.recordLastPlayed(appID: app.id, title: query)
                return
            }
            // Cold start went to the app's home — do it the long way.
            await self.runUniversalPlay(title: title, query: query, preferApp: app,
                                        wantsShow: wantsShow, exclusive: exclusive)
        }
    }

    func universalPlay(title: String, query: String, preferApp: DeviceApp? = nil,
                       wantsShow: Bool? = nil, exclusive: Bool = false) {
        supervisorTask?.cancel()
        supervisorTask = Task { [weak self] in
            await self?.runUniversalPlay(title: title, query: query, preferApp: preferApp,
                                         wantsShow: wantsShow, exclusive: exclusive)
        }
    }

    private func runUniversalPlay(title: String, query: String, preferApp: DeviceApp?,
                                  wantsShow: Bool?, exclusive: Bool) async {
        guard let device = activeDevice else { return }
        let search = UniversalSearch(device: device) { [weak self] status in
            self?.flash(status)
        }
        flash("Finding \(title) on the TV \u{2014} screen stays dark until it plays\u{2026}")
        // Backlight off: the whole search dance runs invisibly, and the
        // defer guarantees the screen comes back whatever happens.
        try? await device.screenOff()
        defer { Task { try? await device.screenOn() } }
        let handedOff = await search.play(
            query: query, preferAppID: preferApp?.id, preferAppLabel: preferApp?.label,
            wantsShow: wantsShow, exclusive: exclusive
        )
        guard !Task.isCancelled else { return }
        guard handedOff else {
            flash("The TV's search couldn't find \(title).")
            return
        }
        await superviseSteps()
        if state.isMediaPlaying == true, let appID = preferApp?.id ?? state.currentAppID {
            recordLastPlayed(appID: appID, title: query)
        }
    }

    func robotOCRText() async -> String {
        guard let device = activeDevice, let frame = try? await device.captureScreen() else { return "" }
        return await Task.detached(priority: .userInitiated) { ScreenText.read(jpeg: frame) }.value
    }
}
