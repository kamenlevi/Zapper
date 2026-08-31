import Foundation

/// The remote-input socket. The TV hands out a second websocket URL whose
/// protocol is not JSON but newline-delimited `key:value` pairs terminated by
/// a blank line — this is what actually delivers D-pad and OK presses.
actor PointerSocket {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    func connect(url: URL, pinnedFingerprint: String?) async throws {
        await close()

        let delegate = CertTrustDelegate(expectedFingerprint: pinnedFingerprint) { _ in }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // Draining incoming frames keeps the socket healthy; the TV sends
        // little here, but an unread socket eventually stalls.
        Task { [weak self] in
            while true {
                guard let self, let t = await self.task else { return }
                guard (try? await t.receive()) != nil else { return }
            }
        }
    }

    var isConnected: Bool { task != nil }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func button(_ name: String) async throws {
        try await send(type: "button", fields: ["name": name])
    }

    func move(dx: Double, dy: Double, drag: Bool = false) async throws {
        try await send(type: "move", fields: [
            "dx": String(Int(dx.rounded())),
            "dy": String(Int(dy.rounded())),
            "down": drag ? "1" : "0",
        ])
    }

    func click() async throws {
        try await send(type: "click", fields: [:])
    }

    func scroll(dx: Double, dy: Double) async throws {
        try await send(type: "scroll", fields: [
            "dx": String(Int(dx.rounded())),
            "dy": String(Int(dy.rounded())),
        ])
    }

    private func send(type: String, fields: [String: String]) async throws {
        guard let task else { throw RemoteError.notConnected }
        var lines = ["type:\(type)"]
        for (k, v) in fields { lines.append("\(k):\(v)") }
        let message = lines.joined(separator: "\n") + "\n\n"
        try await task.send(.string(message))
    }
}

extension RemoteKey {
    /// webOS button names for the remote-input socket.
    var webOSButton: String? {
        switch self {
        case .up:          return "UP"
        case .down:        return "DOWN"
        case .left:        return "LEFT"
        case .right:       return "RIGHT"
        case .ok:          return "ENTER"
        case .back:        return "BACK"
        case .home:        return "HOME"
        case .exit:        return "EXIT"
        case .menu:        return "MENU"
        case .info:        return "INFO"
        case .play:        return "PLAY"
        case .pause:       return "PAUSE"
        case .stop:        return "STOP"
        case .rewind:      return "REWIND"
        case .fastForward: return "FASTFORWARD"
        case .volumeUp:    return "VOLUMEUP"
        case .volumeDown:  return "VOLUMEDOWN"
        case .mute:        return "MUTE"
        case .channelUp:   return "CHANNELUP"
        case .channelDown: return "CHANNELDOWN"
        case .red:         return "RED"
        case .green:       return "GREEN"
        case .yellow:      return "YELLOW"
        case .blue:        return "BLUE"
        case .guide:       return "GUIDE"
        case .dash:        return "DASH"
        case .num0:        return "0"
        case .num1:        return "1"
        case .num2:        return "2"
        case .num3:        return "3"
        case .num4:        return "4"
        case .num5:        return "5"
        case .num6:        return "6"
        case .num7:        return "7"
        case .num8:        return "8"
        case .num9:        return "9"
        }
    }
}
