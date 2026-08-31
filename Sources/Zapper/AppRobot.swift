import Foundation
import ZapperKit

/// Direct deep links are ignored by the streaming apps on this firmware, so
/// content plays through the TV's universal search hand-off (ZapperKit's
/// UniversalSearch) — instant text injection, then LG launches the app with
/// its partner-blessed link. The supervisor finishes the job on the app's
/// side (profile gate, title-page play button).
extension RemoteController {

    func universalPlay(title: String, query: String) {
        supervisorTask?.cancel()
        guard let device = activeDevice else { return }
        let search = UniversalSearch(device: device) { [weak self] status in
            self?.flash(status)
        }
        flash("Finding \(title) on the TV\u{2026}")
        supervisorTask = Task { [weak self] in
            let handedOff = await search.play(query: query)
            guard let self, !Task.isCancelled else { return }
            guard handedOff else {
                self.flash("The TV's search couldn't find \(title).")
                return
            }
            await self.superviseSteps()
        }
    }
}
