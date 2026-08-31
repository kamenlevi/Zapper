import Foundation

/// Per-device pairing material: the client key webOS hands back after you
/// accept the on-screen prompt, plus the pinned certificate fingerprint.
public struct DeviceCredentials: Codable, Sendable {
    public var clientKey: String
    public var certFingerprint: String?
    public var macAddress: String?
    public var lastKnownHost: String?
    public var displayName: String?
}

/// Stored as a 0600 file in Application Support rather than the Keychain.
/// The Keychain would bind the item to the app's code signature, so every
/// rebuild of a locally-signed app would trigger an authorization prompt;
/// the client key only grants control of a TV on the local network, so the
/// file is the better trade here.
public final class CredentialStore: @unchecked Sendable {
    public static let shared = CredentialStore()

    private let lock = NSLock()
    private let url: URL
    private var cache: [String: DeviceCredentials]

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("devices.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: DeviceCredentials].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    public func credentials(for deviceID: String) -> DeviceCredentials? {
        lock.lock(); defer { lock.unlock() }
        return cache[deviceID]
    }

    /// Looks up by device id, falling back to whatever we last paired at this
    /// address. The CLI keys by host while the app keys by the Bonjour device
    /// id, and a TV can change DHCP address between runs — either way one
    /// on-screen pairing should be enough.
    public func credentials(for deviceID: String, host: String?) -> (key: String, value: DeviceCredentials)? {
        lock.lock(); defer { lock.unlock() }
        if let exact = cache[deviceID] { return (deviceID, exact) }
        guard let host else { return nil }
        if let match = cache.first(where: { $0.value.lastKnownHost == host }) {
            return (match.key, match.value)
        }
        return nil
    }

    public func save(_ credentials: DeviceCredentials, for deviceID: String) {
        lock.lock()
        cache[deviceID] = credentials
        let snapshot = cache
        lock.unlock()
        persist(snapshot)
    }

    public func forget(_ deviceID: String) {
        lock.lock()
        cache[deviceID] = nil
        let snapshot = cache
        lock.unlock()
        persist(snapshot)
    }

    public var allDeviceIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(cache.keys)
    }

    private func persist(_ snapshot: [String: DeviceCredentials]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }
}
