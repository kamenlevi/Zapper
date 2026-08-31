import Foundation
import ZapperKit

// A thin driver over ZapperKit, used to exercise the protocol against a real
// TV without going through the UI.

func usage() -> Never {
    print("""
    zapperctl — drive a webOS TV from the terminal

      zapperctl discover
      zapperctl pair    <host>
      zapperctl status  <host>
      zapperctl key     <host> <up|down|left|right|ok|back|home|exit|info|play|pause|...>
      zapperctl vol     <host> <0-100>
      zapperctl mute    <host> <on|off>
      zapperctl channel <host> <number>
      zapperctl inputs  <host>
      zapperctl input   <host> <inputId>
      zapperctl apps    <host>
      zapperctl launch  <host> <appId>
      zapperctl toast   <host> <message>
      zapperctl off     <host>
      zapperctl on      <host>
      zapperctl unpair  <host>
    """)
    exit(1)
}

func makeDevice(_ host: String) -> WebOSDevice {
    // Adopt the identity an existing pairing is already filed under, so the
    // CLI and the app share one entry instead of re-keying it back and forth.
    let existing = CredentialStore.shared.credentials(for: host, host: host)
    return WebOSDevice(
        id: existing?.key ?? host,
        displayName: existing?.value.displayName ?? "TV at \(host)",
        host: host
    )
}

/// Connects, reporting the pairing prompt if the TV shows one.
func connected(_ host: String) async throws -> WebOSDevice {
    let device = makeDevice(host)

    let watcher = Task {
        for await state in device.connectionStates {
            switch state {
            case .awaitingPairing:
                print("→ The TV is showing a pairing prompt. Accept it with the physical remote.")
            case .failed(let message):
                print("✗ \(message)")
            default:
                break
            }
        }
    }

    await device.connect()

    // Wait for the connection to settle either way.
    let deadline = Date().addingTimeInterval(70)
    while Date() < deadline {
        if case .connected = device.connectionState { break }
        if case .failed(let message) = device.connectionState {
            watcher.cancel()
            throw RemoteError.handshakeFailed(message)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    watcher.cancel()

    guard case .connected = device.connectionState else {
        throw RemoteError.handshakeFailed("timed out waiting for the TV")
    }
    return device
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

do {
    switch command {
    case "discover":
        let discovery = Discovery()
        discovery.start()
        print("Browsing for 8 seconds…")
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let devices = discovery.devices.value
        discovery.stop()
        if devices.isEmpty {
            print("No TVs found.")
        }
        for device in devices {
            print("  \(device.name)  [\(device.kind.rawValue)]  \(device.host)  id=\(device.id)  model=\(device.model ?? "-")")
        }

    case "pair":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        try? await device.toast("Zapper is paired.")
        print("✓ Paired and connected to \(args[1]).")
        await device.disconnect()

    case "status":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let state = device.deviceState
        print("on=\(state.isOn) volume=\(state.volume.map(String.init) ?? "-") muted=\(state.muted) app=\(state.currentAppID ?? "-") channel=\(state.currentChannel ?? "-")")
        await device.disconnect()

    case "key":
        guard args.count >= 3, let key = RemoteKey(rawValue: args[2]) else {
            print("Unknown key. Valid: \(RemoteKey.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }
        let device = try await connected(args[1])
        try await device.press(key)
        print("✓ sent \(key.rawValue)")
        await device.disconnect()

    case "vol":
        guard args.count >= 3, let level = Int(args[2]) else { usage() }
        let device = try await connected(args[1])
        try await device.setVolume(level)
        print("✓ volume \(level)")
        await device.disconnect()

    case "mute":
        guard args.count >= 3 else { usage() }
        let device = try await connected(args[1])
        try await device.setMute(args[2] == "on")
        print("✓ mute \(args[2])")
        await device.disconnect()

    case "channel":
        guard args.count >= 3 else { usage() }
        let device = try await connected(args[1])
        try await device.openChannel(number: args[2])
        print("✓ channel \(args[2])")
        await device.disconnect()

    case "inputs":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        for input in try await device.inputs() {
            print("  \(input.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(input.label)  connected=\(input.connected)")
        }
        await device.disconnect()

    case "input":
        guard args.count >= 3 else { usage() }
        let device = try await connected(args[1])
        try await device.switchInput(id: args[2])
        print("✓ input \(args[2])")
        await device.disconnect()

    case "channels":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        for ch in try await device.channels() {
            print("  \(ch.number.padding(toLength: 8, withPad: " ", startingAt: 0)) \(ch.name)")
        }
        await device.disconnect()

    case "appsjson":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        print(try await device.rawLaunchPointsJSON())
        await device.disconnect()

    case "apps":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        for app in try await device.apps() {
            print("  \(app.id.padding(toLength: 42, withPad: " ", startingAt: 0)) \(app.label)\(app.bestIconURL.map { "  " + $0.absoluteString } ?? "")")
        }
        await device.disconnect()

    case "launch":
        guard args.count >= 3 else { usage() }
        let device = try await connected(args[1])
        try await device.launchApp(id: args[2], contentTarget: args.count >= 4 ? args[3] : nil)
        print("✓ launched \(args[2])")
        await device.disconnect()

    case "find":
        guard args.count >= 2 else { usage() }
        let country = Locale.current.region?.identifier ?? "US"
        for hit in try await ContentSearch.search(args[1], country: country) {
            let year = hit.year.map(String.init) ?? "?"
            print("  \(hit.title) (\(year), \(hit.isShow ? "show" : "movie"))")
            for offer in hit.offers {
                print("      \(offer.providerName): \(offer.url)")
            }
        }

    case "findep":
        guard args.count >= 4, let season = Int(args[2]), let episode = Int(args[3]) else { usage() }
        let country = Locale.current.region?.identifier ?? "US"
        guard let show = try await ContentSearch.search(args[1], country: country).first(where: { $0.isShow }) else {
            print("no show found"); break
        }
        print("  \(show.title) [\(show.id)] S\(season) E\(episode)")
        for offer in try await ContentSearch.episodeOffers(showID: show.id, season: season, episode: episode, country: country) {
            print("      \(offer.providerName): \(offer.url)")
        }

    case "spotify-connect":
        guard args.count >= 2 else { usage() }
        SpotifyClient.shared.setClientID(args[1])
        try await SpotifyClient.shared.connect { url in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = [url.absoluteString]
            try? task.run()
        }
        print("connected as \(SpotifyClient.shared.displayName ?? "?")")

    case "spotify":
        guard args.count >= 2 else { usage() }
        let kind = args.count >= 3 ? SpotifyItem.Kind(rawValue: args[2]) : nil
        for item in try await SpotifyClient.shared.search(args[1], kind: kind) {
            print("  [\(item.kind.rawValue)\(item.isOwn ? ", yours" : "")] \(item.name) - \(item.detail)  \(item.uri)")
        }

    case "toast":
        guard args.count >= 3 else { usage() }
        let device = try await connected(args[1])
        try await device.toast(args[2...].joined(separator: " "))
        print("✓ toast sent")
        await device.disconnect()

    case "off":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        try await device.powerOff()
        print("✓ powering off")
        await device.disconnect()

    case "on":
        guard args.count >= 2 else { usage() }
        let device = makeDevice(args[1])
        try await device.powerOn()
        print("✓ Wake-on-LAN packet sent")

    case "unpair":
        guard args.count >= 2 else { usage() }
        CredentialStore.shared.forget(args[1])
        print("✓ forgot \(args[1])")

    default:
        usage()
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    print("✗ \(message)")
    exit(1)
}
