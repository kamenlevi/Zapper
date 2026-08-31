import AppKit

/// App tile artwork fetched from the TV, kept on disk so the quick-launch row
/// renders instantly on later launches — including while the TV is off.
enum IconCache {
    private static var directory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zapper/Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(for appID: String) -> URL {
        let safe = appID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).png")
    }

    static func load(appID: String) -> NSImage? {
        NSImage(contentsOf: url(for: appID))
    }

    static func save(_ data: Data, appID: String) {
        try? data.write(to: url(for: appID), options: .atomic)
    }

    /// The artwork's own edge colour, for apps whose launch point doesn't
    /// declare an `iconColor`. Sampled just inside the corner; refused when
    /// the corner is transparent (a logo on empty ground has no edge to blend).
    static func edgeColorHex(of image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let sampled = rep.colorAt(x: 2, y: 2),
              sampled.alphaComponent > 0.95,
              let rgb = sampled.usingColorSpace(.sRGB)
        else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255)
        )
    }
}
