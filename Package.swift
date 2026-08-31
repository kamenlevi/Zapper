// swift-tools-version:5.9
import PackageDescription

// The executable target is named ZapperApp rather than Zapper: a target whose
// name matches the package name confuses SPM's build-plan naming. The built
// binary is renamed to Zapper when build.sh assembles the .app bundle.
let package = Package(
    name: "Zapper",
    platforms: [.macOS(.v14)],
    targets: [
        // Device-agnostic remote-control core. Knows nothing about AppKit.
        .target(name: "ZapperKit"),

        // Headless driver used to exercise the protocol against a real TV.
        .executableTarget(name: "zapperctl", dependencies: ["ZapperKit"]),

        // The menu bar app itself.
        .executableTarget(name: "ZapperApp", dependencies: ["ZapperKit"], path: "Sources/Zapper"),
    ]
)
