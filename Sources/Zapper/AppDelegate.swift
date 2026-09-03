import AppKit
import SwiftUI
import ZapperKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    func popoverDidShow(_ notification: Notification) { controller.popoverVisible = true }
    func popoverDidClose(_ notification: Notification) { controller.popoverVisible = false }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let controller = RemoteController()
    private var monitor: Any?
    private lazy var previewWindow = PreviewWindowController(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.statusImage()
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.toolTip = "Zapper"
        }

        let hosting = NSHostingController(rootView: RemoteView(controller: controller))
        hosting.sizingOptions = [.preferredContentSize]

        popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        // Never animate: NSPopover animates size changes by tweening the
        // window frame while SwiftUI is already laid out at the final
        // positions, so any inline expansion (now-playing panel, search
        // results) renders content sliding over the header.
        popover.animates = false

        // Screenshot mode: populate state, render, exit. No discovery, so
        // nothing on the network is touched.
        if let kind = ProcessInfo.processInfo.environment["ZAPPER_SHOWCASE"],
           let path = ProcessInfo.processInfo.environment["ZAPPER_RENDER"] {
            Showcase.isRendering = true
            Task { @MainActor in
                await self.controller.loadShowcase(kind: kind)
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.render(to: path)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        controller.presentPreview = { [weak self] in self?.previewWindow.toggle() }
        controller.start()

        // Development aid: lets the popover be captured without driving the
        // status item through Accessibility automation.
        if ProcessInfo.processInfo.environment["ZAPPER_SHOW_POPOVER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.togglePopover(nil)
            }
        }

        // Renders the popover to a PNG once the TV state has landed, then
        // exits. Used to check layout without Screen Recording permission.
        if let path = ProcessInfo.processInfo.environment["ZAPPER_RENDER"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self.render(to: path)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func render(to path: String) {
        let card = RemoteView(controller: controller)
            .background(Color(red: 0.13, green: 0.13, blue: 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
        let renderer = ImageRenderer(
            content: Group {
                if Showcase.isRendering {
                    card
                        .padding(26)
                        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
                } else {
                    RemoteView(controller: controller)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .environment(\.colorScheme, .dark)
        )
        renderer.scale = Showcase.isRendering ? 3 : 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("rendered \(path)\n".utf8))
    }

    /// A menu bar glyph is ~16pt, so the remote gets two shapes and no more:
    /// a body and a clickpad. SF Symbols' own remote packs in a whole button
    /// grid, which turns to mush at this size.
    ///
    /// Drawn rather than picked from SF Symbols so the proportions are ours —
    /// the body has to read as clearly taller than it is wide, and only
    /// gently rounded, or it looks like a mouse.
    private static func statusImage() -> NSImage {
        let height: CGFloat = 16
        let width: CGFloat = 7

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let stroke = rect.height / 16 * 1.3
            let body = rect.insetBy(dx: stroke / 2, dy: stroke / 2)

            NSColor.black.setStroke()
            NSColor.black.setFill()

            let outline = NSBezierPath(
                roundedRect: body,
                xRadius: body.width * 0.30,
                yRadius: body.width * 0.30
            )
            outline.lineWidth = stroke
            outline.stroke()

            let pad = body.width * 0.40
            NSBezierPath(ovalIn: NSRect(
                x: body.midX - pad / 2,
                y: body.maxY - body.height * 0.21 - pad / 2,
                width: pad,
                height: pad
            )).fill()

            return true
        }

        // Template mode lets macOS handle light/dark and the menu-open highlight.
        image.isTemplate = true
        return image
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
