import Foundation
import Network

/// A device found on the network, before we've connected to it.
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public let id: String            // stable across DHCP changes
    public let name: String
    public let host: String
    public let model: String?
    public let kind: Kind

    /// True for entries recovered from saved pairings rather than seen live —
    /// they stand in while a TV is powered off, and are superseded as soon as
    /// the real advertisement arrives.
    public let isProvisional: Bool

    public enum Kind: String, Sendable {
        case webOS
        case appleTV                 // recognised, not yet driveable
        case unknown
    }
}

/// Browses Bonjour for controllable TVs.
///
/// macOS gives third-party apps no access to the HomeKit database — the
/// HomeKit framework is iOS/watchOS/tvOS only — so we find the same devices
/// the Home app shows by the advertisement they broadcast on the LAN.
public final class Discovery: @unchecked Sendable {

    public let devices = StateBroadcaster<[DiscoveredDevice]>([])

    private let lock = NSLock()
    private var browsers: [NWBrowser] = []
    private var found: [String: DiscoveredDevice] = [:]
    private var resolving: Set<String> = []

    public init() {}

    public func start() {
        stop()
        seedFromSavedCredentials()
        browse(type: "_airplay._tcp")
    }

    public func stop() {
        lock.lock()
        let running = browsers
        browsers.removeAll()
        lock.unlock()
        for browser in running { browser.cancel() }
    }

    /// A TV that's currently powered off stops advertising, so fall back to
    /// whatever we successfully connected to last time.
    private func seedFromSavedCredentials() {
        let store = CredentialStore.shared
        var seeded: [String: DiscoveredDevice] = [:]
        for deviceID in store.allDeviceIDs {
            guard let creds = store.credentials(for: deviceID),
                  let host = creds.lastKnownHost else { continue }
            seeded[deviceID] = DiscoveredDevice(
                id: deviceID,
                name: creds.displayName ?? "TV",
                host: host,
                model: nil,
                kind: .webOS,
                isProvisional: true
            )
        }
        guard !seeded.isEmpty else { return }
        lock.lock(); found.merge(seeded) { current, _ in current }; lock.unlock()
        publish()
    }

    private func browse(type: String) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: type, domain: nil),
            using: parameters
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results { self.consider(result) }
        }

        browser.stateUpdateHandler = { state in
            if case .failed = state { browser.cancel() }
        }

        lock.lock(); browsers.append(browser); lock.unlock()
        browser.start(queue: .global(qos: .utility))
    }

    private func consider(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }
        guard case .bonjour(let txt) = result.metadata else { return }

        let manufacturer = txt["manufacturer"] ?? ""
        let model = txt["model"]
        let deviceID = txt["deviceid"]

        let kind: DiscoveredDevice.Kind
        if manufacturer.localizedCaseInsensitiveContains("LG")
            || name.localizedCaseInsensitiveContains("webOS") {
            kind = .webOS
        } else if (model ?? "").hasPrefix("AppleTV") {
            kind = .appleTV
        } else {
            return  // Macs and iPhones also advertise _airplay; ignore them.
        }

        let id = deviceID ?? "\(name).\(type)\(domain)"

        lock.lock()
        let alreadyResolving = resolving.contains(id)
        if !alreadyResolving { resolving.insert(id) }
        lock.unlock()
        guard !alreadyResolving else { return }

        resolveHost(for: result.endpoint) { [weak self] host in
            guard let self else { return }
            self.lock.lock()
            self.resolving.remove(id)
            if let host {
                self.found[id] = DiscoveredDevice(
                    id: id, name: name, host: host, model: model,
                    kind: kind, isProvisional: false
                )
            }
            self.lock.unlock()
            if host != nil { self.publish() }
        }
    }

    /// NWBrowser reports a service name, not an address. Opening a connection
    /// to the endpoint and reading the resolved path is the supported way to
    /// turn one into a host we can dial.
    private func resolveHost(for endpoint: NWEndpoint, completion: @escaping @Sendable (String?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let finished = FingerprintBox()   // reused as a one-shot guard

        let finish: @Sendable (String?) -> Void = { host in
            guard finished.value == nil else { return }
            finished.value = "done"
            connection.cancel()
            completion(host)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint else {
                    finish(nil); return
                }
                switch host {
                case .ipv4(let address):
                    // Strip the "%en0" scope suffix if present.
                    finish("\(address)".components(separatedBy: "%").first)
                case .ipv6(let address):
                    finish("\(address)".components(separatedBy: "%").first)
                case .name(let name, _):
                    finish(name)
                @unknown default:
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))

        // Don't let a half-open connection hold the slot forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { finish(nil) }
    }

    private func publish() {
        lock.lock()
        let all = Array(found.values)
        lock.unlock()

        // Drop placeholder entries for any host we can now see for real.
        let liveHosts = Set(all.filter { !$0.isProvisional }.map(\.host))
        let snapshot = all
            .filter { !($0.isProvisional && liveHosts.contains($0.host)) }
            .sorted { $0.name < $1.name }

        devices.send(snapshot)
    }
}
