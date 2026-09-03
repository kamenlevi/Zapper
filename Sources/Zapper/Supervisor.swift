import AppKit
import Foundation
import ZapperKit

/// Getting a title actually playing takes more than a launch call: Netflix
/// ignores SSAP deep links (DIAL with `v=<id>` is what works), apps park on
/// profile gates and title pages, and somebody has to press the buttons.
/// That somebody is the launch supervisor: for ~45s after a play request it
/// watches the screen and pushes through whatever appears.
extension RemoteController {

    static let profileKey = "Zapper.profileName"

    /// The profile to pick when an app asks who's watching. Unset means
    /// "accept whichever profile the app highlights first", which is what a
    /// single-profile account wants — so nothing is assumed about the user.
    var profileName: String? {
        let stored = UserDefaults.standard.string(forKey: Self.profileKey)?
            .trimmingCharacters(in: .whitespaces)
        return stored?.isEmpty == false ? stored : nil
    }

    /// Kicks off playback via the mechanism that works for the app, then
    /// supervises the launch.
    func startPlayback(app: DeviceApp, offer: ContentHit.Offer, title: String, query: String,
                       wantsShow: Bool? = nil, exclusive: Bool = false) {
        nowPlaying.appID = app.id
        // Asking for the show the app already has open/resumable: a plain
        // launch resumes it in seconds, no search needed.
        if query.searchNormalized == lastPlayed(appID: app.id) {
            fastResume(app: app, title: title, query: query,
                       wantsShow: wantsShow, exclusive: exclusive)
            return
        }
        universalPlay(title: title, query: query, preferApp: app, wantsShow: wantsShow,
                      exclusive: exclusive)
    }

    /// Babysits an app launch: answers the profile gate, presses the parked
    /// title page's Resume/Play, stops once playback runs. Call from within
    /// an existing supervisor task.
    func superviseSteps(timeout: TimeInterval = 45) async {
        var okPresses = 0
        var profileHandled = false
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        while !Task.isCancelled, Date() < deadline {
            guard let device = activeDevice else { return }
            guard let frame = try? await device.captureFrame(width: 1280, height: 720) else {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                continue
            }
            let lines = await Task.detached(priority: .userInitiated) {
                ScreenText.lines(jpeg: frame)
            }.value
            let joined = lines.map(\.text).joined(separator: "\n").lowercased()

            let profileGate = ["who's watching", "whos watching", "who is watching",
                               "choose a profile", "кой гледа", "избери профил"]
                .contains(where: joined.contains)
            let titlePage = ["play from beginning", "resume", "продължи", "възобнови", "гледай"]
                .contains(where: joined.contains)

            if profileGate, !profileHandled {
                profileHandled = true
                await selectProfile(among: lines)
            } else if titlePage, okPresses < 2 {
                // The page's default-focused button is Resume/Play.
                okPresses += 1
                press(.ok)
            } else if state.isMediaPlaying == true, okPresses + (profileHandled ? 1 : 0) > 0 {
                // We acted and playback is running — job done.
                return
            }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
        }
    }

    /// On a profile gate, walks the focus to the configured profile and
    /// confirms. Focus starts on the leftmost profile; the OCR boxes tell us
    /// how many steps right the target is.
    func selectProfile(among lines: [ScreenText.Line]) async {
        guard let profileName else {
            // No preference set: take the focused (default) profile.
            press(.ok)
            return
        }
        let target = profileName.searchNormalized
        let candidates = lines.filter { line in
            let lower = line.text.lowercased()
            return line.text.count <= 20
                && !lower.contains("watching")
                && !lower.contains("who")
                && !lower.contains("profile")
        }
        guard let hit = candidates.first(where: {
            let name = $0.text.searchNormalized
            return !name.isEmpty && (name.contains(target) || target.contains(name))
        }) else {
            press(.ok)
            return
        }
        let row = candidates
            .filter { abs($0.box.midY - hit.box.midY) < 0.08 }
            .sorted { $0.box.minX < $1.box.minX }
        let steps = row.firstIndex(where: { $0.text == hit.text }) ?? 0
        for _ in 0..<steps {
            press(.right)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        press(.ok)
        flash("Picked the \(hit.text) profile.")
    }

    func promptForProfile() {
        let alert = NSAlert()
        alert.messageText = "Streaming Profile"
        alert.informativeText = """
        The profile Zapper picks when an app asks who's watching. Leave it \
        blank to accept whichever profile the app highlights first.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Profile name"
        field.stringValue = profileName ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(
            field.stringValue.trimmingCharacters(in: .whitespaces),
            forKey: Self.profileKey
        )
    }
}
