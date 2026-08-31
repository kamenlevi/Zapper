import AppKit

@main
struct ZapperMain {
    /// NSApplication.delegate is a weak reference, so the delegate needs an
    /// owner that outlives main().
    @MainActor static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate

        // Menu bar only: no Dock tile, no menu bar title of its own.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
