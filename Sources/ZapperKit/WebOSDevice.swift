import Foundation

/// An LG webOS TV driven over SSAP.
public final class WebOSDevice: RemoteDevice, @unchecked Sendable {

    public let id: String
    public let displayName: String
    public private(set) var host: String

    public var capabilities: RemoteCapabilities {
        [.dpad, .absoluteVolume, .channels, .inputs, .apps, .power, .wakeOnLAN, .pointer, .textEntry]
    }

    private let socket = WebOSSocket()
    private let pointer = PointerSocket()
    private let store: CredentialStore

    private let connection = StateBroadcaster<ConnectionState>(.disconnected)
    private let device = StateBroadcaster<DeviceState>(DeviceState())

    private let lock = NSLock()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: UInt64 = 1
    private var wantsConnection = false

    public var connectionStates: AsyncStream<ConnectionState> { connection.stream() }
    public var deviceStates: AsyncStream<DeviceState> { device.stream() }
    public var connectionState: ConnectionState { connection.value }
    public var deviceState: DeviceState { device.value }

    public init(id: String, displayName: String, host: String, store: CredentialStore = .shared) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.store = store
    }

    /// The discovery layer may see the TV move to a new DHCP address.
    public func updateHost(_ newHost: String) {
        let shouldReconnect = lock.withLock { () -> Bool in
            let changed = newHost != host
            host = newHost
            return changed && wantsConnection
        }
        if shouldReconnect { Task { await self.reconnectNow() } }
    }

    // MARK: - Connection lifecycle

    public func connect() async {
        lock.withLock { wantsConnection = true }
        await attemptConnect()
    }

    public func disconnect() async {
        lock.withLock {
            wantsConnection = false
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        await socket.close()
        await pointer.close()
        connection.send(.disconnected)
    }

    /// Drops the stored pairing so the TV will prompt again next time.
    public func unpair() async {
        store.forget(id)
        await disconnect()
    }

    private func attemptConnect() async {
        connection.send(.connecting)

        let currentHost = lock.withLock { host }
        let match = store.credentials(for: id, host: currentHost)
        let existing = match?.value

        guard let url = URL(string: "wss://\(currentHost):3001") else {
            connection.send(.failed("Bad host \(currentHost)"))
            return
        }

        do {
            let key = try await socket.connect(
                url: url,
                clientKey: existing?.clientKey,
                pinnedFingerprint: existing?.certFingerprint,
                onPairingPrompt: { [weak self] in
                    self?.connection.send(.awaitingPairing)
                },
                onClose: { [weak self] in
                    self?.handleSocketClosed()
                }
            )

            // Cache the MAC while the TV is reachable — once it powers off it
            // leaves the ARP table, and that's exactly when we need it.
            let mac = existing?.macAddress ?? WakeOnLAN.arpLookup(host: currentHost)

            store.save(
                DeviceCredentials(
                    clientKey: key,
                    certFingerprint: await socket.certFingerprint ?? existing?.certFingerprint,
                    macAddress: mac,
                    lastKnownHost: currentHost,
                    displayName: displayName
                ),
                for: id
            )

            // If we adopted credentials stored under an older key, retire it.
            if let staleKey = match?.key, staleKey != id { store.forget(staleKey) }

            lock.withLock { reconnectDelay = 1 }
            connection.send(.connected)
            device.mutate { $0.isOn = true }

            await openPointerSocket()
            await startSubscriptions()

        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connection.send(.failed(message))
            scheduleReconnect()
        }
    }

    private func handleSocketClosed() {
        Task { await self.pointer.close() }
        device.mutate { $0.isOn = false }
        let shouldRetry = lock.withLock { wantsConnection }
        if shouldRetry {
            connection.send(.disconnected)
            scheduleReconnect()
        }
    }

    private func reconnectNow() async {
        await socket.close()
        await pointer.close()
        await attemptConnect()
    }

    private func scheduleReconnect() {
        lock.lock()
        guard wantsConnection, reconnectTask == nil else { lock.unlock(); return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            let stillWanted = self.lock.withLock { () -> Bool in
                self.reconnectTask = nil
                return self.wantsConnection
            }
            guard stillWanted else { return }
            await self.attemptConnect()
        }
        reconnectTask = task
        lock.unlock()
    }

    private func openPointerSocket() async {
        do {
            let response = try await socket.request(SSAP.pointerSocket)
            guard let path = response["socketPath"] as? String, let url = URL(string: path) else { return }
            let pin = store.credentials(for: id)?.certFingerprint
            try await pointer.connect(url: url, pinnedFingerprint: pin)
        } catch {
            // D-pad will fall back to SSAP-only commands; not fatal.
        }
    }

    private func startSubscriptions() async {
        try? await socket.subscribe(SSAP.volumeStatus) { [weak self] payload in
            guard let self else { return }
            // Newer firmware nests this under volumeStatus; older is flat.
            let status = (payload["volumeStatus"] as? JSONDict) ?? payload
            let volume = status["volume"] as? Int
            let muted = (status["muteStatus"] as? Bool) ?? (status["mute"] as? Bool) ?? (payload["muted"] as? Bool) ?? false
            self.device.mutate {
                if let volume, volume >= 0 { $0.volume = volume }
                $0.muted = muted
            }
        }

        try? await socket.subscribe(SSAP.foregroundApp) { [weak self] payload in
            guard let self else { return }
            let appID = payload["appId"] as? String
            self.device.mutate {
                $0.currentAppID = (appID?.isEmpty == false) ? appID : nil
                $0.isOn = (appID?.isEmpty == false)
            }
        }

        try? await socket.subscribe(SSAP.currentChannel) { [weak self] payload in
            guard let self else { return }
            let number = payload["channelNumber"] as? String
            let name = payload["channelName"] as? String
            self.device.mutate {
                $0.currentChannel = [number, name].compactMap { $0 }.joined(separator: "  ")
            }
        }

        try? await socket.subscribe(SSAP.mediaState) { [weak self] payload in
            guard let self else { return }
            let pipelines = (payload["foregroundAppInfo"] as? [JSONDict]) ?? []
            let playState = pipelines.compactMap { $0["playState"] as? String }.last
            self.device.mutate {
                switch playState {
                case "playing": $0.isMediaPlaying = true
                case "paused":  $0.isMediaPlaying = false
                default:        $0.isMediaPlaying = nil
                }
            }
        }
    }

    /// The programme currently airing on the tuned channel, from the EPG.
    public func currentProgram() async throws -> TVProgram? {
        let response = try await socket.request(SSAP.channelProgram)
        let list = (response["programList"] as? [JSONDict]) ?? []

        // Timestamps come as "2026,09,01,20,00,00" in UTC.
        func date(_ raw: Any?) -> Date? {
            guard let text = raw as? String else { return nil }
            let parts = text.split(separator: ",").compactMap { Int($0) }
            guard parts.count >= 6 else { return nil }
            var components = DateComponents()
            components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
            components.hour = parts[3]; components.minute = parts[4]; components.second = parts[5]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.date(from: components)
        }

        let now = Date()
        for entry in list {
            guard let name = entry["programName"] as? String,
                  let start = date(entry["startTime"]) else { continue }
            let end = date(entry["endTime"])
                ?? (entry["duration"] as? Double).map { start.addingTimeInterval($0) }
                ?? start.addingTimeInterval(1800)
            if start <= now, now < end {
                return TVProgram(name: name, start: start, end: end)
            }
        }
        return nil
    }

    // MARK: - Commands

    public func press(_ key: RemoteKey) async throws {
        guard let button = key.webOSButton else { throw RemoteError.unsupported }

        if await pointer.isConnected {
            do {
                try await pointer.button(button)
                return
            } catch {
                // Pointer socket went stale — re-open once, then fall through.
                await openPointerSocket()
                if await pointer.isConnected {
                    try await pointer.button(button)
                    return
                }
            }
        }

        // Fallback for the subset SSAP exposes directly.
        switch key {
        case .volumeUp:    _ = try await socket.request(SSAP.volumeUp)
        case .volumeDown:  _ = try await socket.request(SSAP.volumeDown)
        case .channelUp:   _ = try await socket.request(SSAP.channelUp)
        case .channelDown: _ = try await socket.request(SSAP.channelDown)
        case .mute:        try await setMute(!device.value.muted)
        default:           throw RemoteError.notConnected
        }
    }

    public func setVolume(_ level: Int) async throws {
        let clamped = max(0, min(100, level))
        _ = try await socket.request(SSAP.setVolume, payload: ["volume": clamped])
        device.mutate { $0.volume = clamped }
    }

    public func setMute(_ muted: Bool) async throws {
        _ = try await socket.request(SSAP.setMute, payload: ["mute": muted])
        device.mutate { $0.muted = muted }
    }

    public func openChannel(number: String) async throws {
        _ = try await socket.request(SSAP.openChannel, payload: ["channelNumber": number])
    }

    public func inputs() async throws -> [DeviceInput] {
        let response = try await socket.request(SSAP.externalInputs)
        let list = (response["devices"] as? [JSONDict]) ?? []
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let label = (entry["label"] as? String) ?? (entry["appId"] as? String) ?? id
            let connected = (entry["connected"] as? Bool) ?? true
            return DeviceInput(id: id, label: label, connected: connected)
        }
    }

    public func switchInput(id inputID: String) async throws {
        _ = try await socket.request(SSAP.switchInput, payload: ["inputId": inputID])
    }

    public func apps() async throws -> [DeviceApp] {
        let response = try await socket.request(SSAP.launchPoints)
        let list = (response["launchPoints"] as? [JSONDict]) ?? []
        return list.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let title = entry["title"] as? String else { return nil }
            let icon = (entry["icon"] as? String).flatMap { URL(string: $0) }
            // largeIcon is sometimes a filesystem path on the TV rather than
            // a served URL — only keep it when it's actually fetchable.
            let large = (entry["largeIcon"] as? String)
                .flatMap { URL(string: $0) }
                .flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            let colour = (entry["iconColor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return DeviceApp(id: id, label: title, iconURL: icon,
                             largeIconURL: large, tileColorHex: colour)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public func launchApp(id appID: String, contentTarget: String? = nil) async throws {
        var payload: JSONDict = ["id": appID]
        // system.launcher takes the deep link at the top level; the app
        // decides what to do with it (Netflix/HBO open the title directly).
        if let contentTarget { payload["contentTarget"] = contentTarget }
        _ = try await socket.request(SSAP.launch, payload: payload)
    }

    /// The tuner's channel list — numbers and names, for search.
    public func channels() async throws -> [TVChannel] {
        let response = try await socket.request(SSAP.channelList)
        let list = (response["channelList"] as? [JSONDict]) ?? []
        return list.compactMap { entry in
            guard let number = entry["channelNumber"] as? String,
                  let name = entry["channelName"] as? String,
                  let id = entry["channelId"] as? String else { return nil }
            return TVChannel(id: id, number: number, name: name)
        }
    }

    /// Launches an app through the TV's DIAL service (plain HTTP, port
    /// 36866) with a launch payload. This is the path that actually starts
    /// Netflix playback — its SSAP contentTarget is ignored on current
    /// firmware, but the DIAL `v=<videoID>` parameter plays the title
    /// directly under the last-active profile.
    public func dialLaunch(appName: String, payload: String) async throws {
        let currentHost = lock.withLock { host }
        guard let url = URL(string: "http://\(currentHost):36866/apps/\(appName)") else {
            throw RemoteError.commandFailed("Bad DIAL URL.")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(payload.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...201).contains(status) else {
            throw RemoteError.commandFailed("DIAL launch refused (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
    }

    /// Types into whatever system text field is focused (the universal
    /// search box) — one call, no on-screen keyboard walking.
    public func insertText(_ text: String) async throws {
        _ = try await socket.request(SSAP.insertText, payload: ["text": text, "replace": 0])
    }

    public func imeEnter() async throws {
        _ = try await socket.request(SSAP.imeEnter)
    }

    /// Backlight off, everything else keeps running — captures still see the
    /// UI, so the play robot can work without showing its steps.
    public func screenOff() async throws {
        _ = try await socket.request(SSAP.screenOff)
    }

    public func screenOn() async throws {
        _ = try await socket.request(SSAP.screenOn)
    }

    /// Grabs one frame of whatever's on screen. DRM'd video comes back
    /// black, but app UI overlays (subtitles, Skip Intro buttons) are in the
    /// frame — which is exactly what auto-skip needs.
    public func captureScreen() async throws -> Data {
        let response = try await socket.request(SSAP.captureScreen)
        guard let uri = response["imageUri"] as? String, let url = URL(string: uri) else {
            throw RemoteError.commandFailed("The TV didn't return a capture.")
        }
        return try await fetchIconData(from: url)
    }

    /// Sends any SSAP request and returns the raw response — the protocol
    /// exploration hatch behind `zapperctl raw`.
    public func rawRequest(_ uri: String, json: String? = nil) async throws -> String {
        var payload: JSONDict = [:]
        if let json, let data = json.data(using: .utf8),
           let parsed = try JSONSerialization.jsonObject(with: data) as? JSONDict {
            payload = parsed
        }
        let response = try await socket.request(uri, payload: payload)
        let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The unparsed launch-point entries, pretty-printed — a debugging aid
    /// for seeing what artwork and colours the TV actually advertises.
    public func rawLaunchPointsJSON() async throws -> String {
        let response = try await socket.request(SSAP.launchPoints)
        let list = (response["launchPoints"] as? [JSONDict]) ?? []
        let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Fetches the tile artwork a launch point advertises. The TV serves it
    /// from the same port and self-signed certificate as SSAP, so the stored
    /// pin applies here too.
    public func fetchIconData(from url: URL) async throws -> Data {
        let currentHost = lock.withLock { host }
        let pinned = store.credentials(for: id, host: currentHost)?.value.certFingerprint
        let delegate = CertTrustDelegate(expectedFingerprint: pinned) { _ in }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw RemoteError.commandFailed("The TV didn't return the app's icon.")
        }
        return data
    }

    public func powerOff() async throws {
        _ = try await socket.request(SSAP.turnOff)
        device.mutate { $0.isOn = false }
    }

    public func powerOn() async throws {
        guard let mac = store.credentials(for: id)?.macAddress else {
            throw RemoteError.commandFailed(
                "No MAC address saved for this TV yet — connect once while it's on, then power-on will work."
            )
        }
        try WakeOnLAN.send(mac: mac)
        let retry = lock.withLock { wantsConnection }
        if retry { scheduleReconnect() }
    }

    /// Puts a message on the TV screen — handy for confirming a fresh pairing.
    public func toast(_ message: String) async throws {
        _ = try await socket.request(SSAP.toast, payload: ["message": message])
    }
}
