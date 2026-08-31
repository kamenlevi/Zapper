import Foundation
import CryptoKit

typealias JSONDict = [String: Any]

/// LG webOS TVs present a self-signed certificate on port 3001. Rather than
/// trusting anything the host offers forever, we record the certificate's
/// SHA-256 the first time we pair and require it to match on every later
/// connection — so a device that later answers on that IP can't silently
/// take over the session.
final class CertTrustDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String?
    private let onObserve: @Sendable (String) -> Void

    init(expectedFingerprint: String?, onObserve: @escaping @Sendable (String) -> Void) {
        self.expectedFingerprint = expectedFingerprint
        self.onObserve = onObserve
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        if let expected = expectedFingerprint, expected != fingerprint {
            // Pin mismatch: refuse rather than fall back to trusting it.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        onObserve(fingerprint)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// A single SSAP (Simple Service Access Protocol) websocket to a webOS TV.
///
/// The protocol is JSON-over-websocket: every request carries an `id`, and the
/// TV echoes that `id` back on its response. Subscriptions reuse the same id
/// and push repeatedly, so one-shot replies and streams are tracked separately.
actor WebOSSocket {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var counter = 0

    private var pending: [String: CheckedContinuation<JSONDict, Error>] = [:]
    private var subscriptions: [String: (JSONDict) -> Void] = [:]
    private var receiveLoop: Task<Void, Never>?

    /// Set once the TV hands back (or re-confirms) our client key.
    private(set) var clientKey: String?
    private(set) var certFingerprint: String?

    private var registrationContinuation: CheckedContinuation<String, Error>?
    private var onPairingPrompt: (@Sendable () -> Void)?
    private var onClose: (@Sendable () -> Void)?

    // MARK: - Connection

    /// Opens the socket and completes the `register` handshake.
    /// Returns the client key to persist for next time.
    ///
    /// - Parameter onPairingPrompt: called when the TV puts its
    ///   "allow this device?" dialog on screen, so the UI can say so.
    func connect(
        url: URL,
        clientKey: String?,
        pinnedFingerprint: String?,
        onPairingPrompt: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> String {
        await close()

        self.clientKey = clientKey
        self.onPairingPrompt = onPairingPrompt
        self.onClose = onClose

        // The delegate runs off-actor, so hand the observed fingerprint back
        // through a lock-free box rather than touching actor state directly.
        let box = FingerprintBox()
        let delegate = CertTrustDelegate(expectedFingerprint: pinnedFingerprint) { fp in
            box.value = fp
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        startReceiveLoop()

        let key = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.registrationContinuation = cont
            Task { try? await self.sendRegistration() }
        }

        self.certFingerprint = box.value
        self.clientKey = key
        return key
    }

    func close() async {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil

        for (_, cont) in pending { cont.resume(throwing: RemoteError.notConnected) }
        pending.removeAll()
        subscriptions.removeAll()
        registrationContinuation?.resume(throwing: RemoteError.notConnected)
        registrationContinuation = nil
    }

    var isConnected: Bool { task != nil }

    // MARK: - Requests

    @discardableResult
    func request(_ uri: String, payload: JSONDict? = nil) async throws -> JSONDict {
        guard task != nil else { throw RemoteError.notConnected }
        counter += 1
        let id = "req_\(counter)"

        var message: JSONDict = ["id": id, "type": "request", "uri": uri]
        if let payload { message["payload"] = payload }

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await self.transmit(message) }
                catch {
                    if let c = self.takePending(id) { c.resume(throwing: error) }
                }
            }
        }
    }

    /// Subscribes to a URI. The handler fires on every push until `close()`.
    func subscribe(_ uri: String, handler: @escaping (JSONDict) -> Void) async throws {
        guard task != nil else { throw RemoteError.notConnected }
        counter += 1
        let id = "sub_\(counter)"
        subscriptions[id] = handler
        try await transmit(["id": id, "type": "subscribe", "uri": uri])
    }

    // MARK: - Internals

    private func takePending(_ id: String) -> CheckedContinuation<JSONDict, Error>? {
        defer { pending[id] = nil }
        return pending[id]
    }

    private func sendRegistration() async throws {
        var payload = WebOSHandshake.payload
        if let clientKey { payload["client-key"] = clientKey }
        try await transmit(["id": "register_0", "type": "register", "payload": payload])
    }

    private func transmit(_ dict: JSONDict) async throws {
        guard let task else { throw RemoteError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteError.commandFailed("could not encode request")
        }
        try await task.send(.string(text))
    }

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let task = await self.task else { return }
                do {
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    await self.handleDisconnect(error)
                    return
                }
            }
        }
    }

    private func handleDisconnect(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        registrationContinuation?.resume(throwing: error)
        registrationContinuation = nil
        task = nil
        onClose?()
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
        @unknown default:    return
        }

        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSONDict
        else { return }

        let id = root["id"] as? String ?? ""
        let type = root["type"] as? String ?? ""
        let payload = root["payload"] as? JSONDict ?? [:]

        if id == "register_0" {
            handleRegistration(type: type, payload: payload, root: root)
            return
        }

        switch type {
        case "error":
            let reason = root["error"] as? String ?? "unknown error"
            if let cont = takePending(id) { cont.resume(throwing: RemoteError.commandFailed(reason)) }
        default:
            if let cont = takePending(id) {
                cont.resume(returning: payload)
            } else if let handler = subscriptions[id] {
                handler(payload)
            }
        }
    }

    private func handleRegistration(type: String, payload: JSONDict, root: JSONDict) {
        switch type {
        case "response":
            // Interim reply: the TV has put the pairing prompt on screen.
            if (payload["pairingType"] as? String) == "PROMPT" {
                onPairingPrompt?()
            }
        case "registered":
            let key = payload["client-key"] as? String ?? clientKey ?? ""
            registrationContinuation?.resume(returning: key)
            registrationContinuation = nil
        case "error":
            let reason = root["error"] as? String ?? "rejected"
            let err: Error = reason.localizedCaseInsensitiveContains("cancel")
                ? RemoteError.pairingRejected
                : RemoteError.handshakeFailed(reason)
            registrationContinuation?.resume(throwing: err)
            registrationContinuation = nil
        default:
            break
        }
    }
}

/// Tiny mutable box so the URLSession delegate (which runs on its own queue)
/// can hand the observed certificate fingerprint back to the actor.
final class FingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
