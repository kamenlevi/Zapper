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

    case "nowplay":
        guard args.count >= 2 else { usage() }
        let frame: Data
        if FileManager.default.fileExists(atPath: args[1]) {
            frame = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        } else {
            let device = try await connected(args[1])
            frame = try await device.captureScreen()
            await device.disconnect()
        }
        let text = ScreenText.read(jpeg: frame)
        print("--- OCR ---")
        print(text)
        print("--- parsed ---")
        print(NowPlayingSnapshot.parse(ocrText: text))

    case "play":
        guard args.count >= 3 else { usage() }
        let device = try await connected(args[1])
        let search = UniversalSearch(device: device) { status in print("  → \(status)") }
        let handedOff = await search.play(query: args[2])
        print(handedOff ? "✓ handed off to the app" : "✗ search failed")
        await device.disconnect()

    case "stream":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        let w = args.count >= 3 ? Int(args[2]) ?? 640 : 640
        let h = args.count >= 4 ? Int(args[3]) ?? 360 : 360
        var frames = 0
        var bytes = 0
        var hashes = Set<Int>()
        let t0 = Date()
        for await frame in device.screenFrames(width: w, height: h) {
            frames += 1
            bytes += frame.count
            hashes.insert(frame.hashValue)
            if Date().timeIntervalSince(t0) > 6 { break }
        }
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "%dx%d: %d frames in %.1fs -> %.1f fps | %d unique | avg %d KB",
                     w, h, frames, dt, Double(frames) / dt, hashes.count, frames == 0 ? 0 : bytes / frames / 1024))
        await device.disconnect()

    case "lat":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        let uri = args.count >= 3 ? args[2] : "ssap://audio/getVolume"
        let t0 = Date()
        for _ in 0..<15 { _ = try? await device.rawRequest(uri, json: nil) }
        print(String(format: "%@: %.3fs/call", uri, Date().timeIntervalSince(t0) / 15))
        await device.disconnect()

    case "bench2":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        let w = args.count >= 3 ? args[2] : "960"
        let h = args.count >= 4 ? args[3] : "540"
        // Register one token URL, then overwrite its backing file in a loop.
        let response = try await device.rawRequest("ssap://tv/executeOneShot", json: nil)
        guard let r = response.range(of: "imageUri\" : \""),
              let e = response[r.upperBound...].range(of: "\""),
              let url = URL(string: response[r.upperBound..<e.lowerBound].replacingOccurrences(of: "\\/", with: "/"))
        else { print("no uri"); break }
        print("token url: \(url.absoluteString)")
        var hashes = Set<String>()
        var bytes = 0
        var capTime = 0.0, fetchTime = 0.0
        let t0 = Date()
        for _ in 0..<15 {
            let c0 = Date()
            do {
                _ = try await device.rawRequest("ssap://com.webos.service.capture/executeOneShot",
                    json: "{\"path\":\"/tmp/capture.jpg\",\"method\":\"DISPLAY\",\"format\":\"JPG\",\"width\":\(w),\"height\":\(h)}")
            } catch {
                print("  capture error: \(error)")
            }
            let c1 = Date()
            capTime += c1.timeIntervalSince(c0)
            if let data = try? await device.fetchIconData(from: url) {
                bytes += data.count
                hashes.insert(String(data.hashValue))
            }
            fetchTime += Date().timeIntervalSince(c1)
        }
        print(String(format: "  capture %.3fs/frame, fetch %.3fs/frame", capTime / 15, fetchTime / 15))
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "15 frames in %.2fs -> %.1f fps | %d unique | avg %d KB",
                     dt, 15 / dt, hashes.count, bytes / 15 / 1024))
        await device.disconnect()

    case "bench":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        let json = args.count >= 3 ? args[2] : nil
        var sizes: [Int] = []
        let t0 = Date()
        for _ in 0..<10 {
            let response = try await device.rawRequest("ssap://tv/executeOneShot", json: json)
            guard let uriRange = response.range(of: "imageUri\" : \""),
                  let end = response[uriRange.upperBound...].range(of: "\"") else { continue }
            let uri = response[uriRange.upperBound..<end.lowerBound]
                .replacingOccurrences(of: "\\/", with: "/")
            if let url = URL(string: String(uri)) {
                let data = try await device.fetchIconData(from: url)
                sizes.append(data.count)
            }
        }
        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "10 frames in %.2fs -> %.1f fps, avg %d KB", elapsed, 10 / elapsed, sizes.isEmpty ? 0 : sizes.reduce(0,+) / sizes.count / 1024))
        await device.disconnect()

    case "focus":
        guard args.count >= 2 else { usage() }
        let device = try await connected(args[1])
        let frame = try await device.captureScreen()
        let lines = ScreenText.lines(jpeg: frame)
        guard let home = lines.first(where: { $0.text == "Home" }) else {
            print("no Home label"); await device.disconnect(); break
        }
        let focus = ScreenText.focusPillX(jpeg: frame, nearY: home.box.midY)
        print("homeBox minX=\(String(format: "%.3f", home.box.minX)) midY=\(String(format: "%.3f", home.box.midY))  focusX=\(focus.map { String(format: "%.3f", $0) } ?? "none")")
        await device.disconnect()

    case "raw":
        guard args.count >= 3 else { usage() }
        let device = try await connected(args[1])
        print(try await device.rawRequest(args[2], json: args.count >= 4 ? args[3] : nil))
        await device.disconnect()

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
