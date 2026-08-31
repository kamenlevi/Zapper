import Foundation
import CryptoKit
import Network

/// One Spotify search result, ready to deep-link into the TV app.
public struct SpotifyItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case artist, track, album, playlist
    }

    public let id: String
    public let kind: Kind
    public let name: String
    /// The line under the name: artist for tracks/albums, owner for playlists.
    public let detail: String
    /// spotify:artist:… — what the TV app accepts as a content target.
    public let uri: String
    /// True when it came from the signed-in user's own playlists.
    public let isOwn: Bool
}

/// Spotify Web API client using Authorization Code + PKCE — the user signs
/// in once in the browser, and a refresh token keeps the session alive. No
/// client secret involved; the only setup is a (free) app's Client ID.
///
/// Credentials live next to the TV pairing file, 0600, not the Keychain —
/// same trade-off as `CredentialStore`.
public final class SpotifyClient: @unchecked Sendable {
    public static let shared = SpotifyClient()

    private struct Stored: Codable {
        var clientID: String
        var refreshToken: String?
        var accessToken: String?
        var expiresAt: Date?
        var displayName: String?
    }

    private let lock = NSLock()
    private let url: URL
    private var stored: Stored?
    private var playlistsCache: (items: [SpotifyItem], at: Date)?

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("spotify.json")
        if let data = try? Data(contentsOf: url) {
            self.stored = try? JSONDecoder().decode(Stored.self, from: data)
        }
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored?.refreshToken != nil
    }

    public var displayName: String? {
        lock.lock(); defer { lock.unlock() }
        return stored?.displayName
    }

    public var clientID: String? {
        lock.lock(); defer { lock.unlock() }
        return stored?.clientID
    }

    public func setClientID(_ id: String) {
        lock.lock()
        stored = Stored(clientID: id)
        lock.unlock()
        persist()
    }

    public func disconnect() {
        lock.lock()
        let id = stored?.clientID
        stored = id.map { Stored(clientID: $0) }
        playlistsCache = nil
        lock.unlock()
        persist()
    }

    private func persist() {
        lock.lock(); defer { lock.unlock() }
        guard let stored, let data = try? JSONEncoder().encode(stored) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Authorization (PKCE)

    private static let redirectPort: UInt16 = 8917
    private static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/callback" }

    /// Runs the whole sign-in dance: builds the consent URL, hands it to
    /// `openURL` (browser), catches the redirect on a loopback socket and
    /// exchanges the code. Times out after three minutes.
    public func connect(openURL: @Sendable @escaping (URL) -> Void) async throws {
        guard let clientID else {
            throw RemoteError.commandFailed("Set a Spotify Client ID first.")
        }

        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(bytes: 16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: "playlist-read-private playlist-read-collaborative"),
        ]

        async let redirect = Self.catchRedirect(port: Self.redirectPort, expectedState: state)
        openURL(components.url!)
        let code = try await redirect

        let token = try await requestToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        lock.lock()
        stored?.refreshToken = token.refresh
        stored?.accessToken = token.access
        stored?.expiresAt = token.expiresAt
        lock.unlock()
        persist()

        // Best effort: a name for the settings menu.
        if let me = try? await api("me") as? [String: Any],
           let name = me["display_name"] as? String {
            lock.lock(); stored?.displayName = name; lock.unlock()
            persist()
        }
    }

    private struct Token { let access: String; let refresh: String?; let expiresAt: Date }

    private func requestToken(form: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw RemoteError.commandFailed("Spotify token request failed (\(status)): \(body)")
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        return Token(
            access: access,
            refresh: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(expires - 60)
        )
    }

    private func validToken() async throws -> String {
        lock.lock()
        let current = stored
        lock.unlock()
        guard let current, let refresh = current.refreshToken else {
            throw RemoteError.commandFailed("Spotify isn't connected.")
        }
        if let access = current.accessToken, let expiry = current.expiresAt, expiry > Date() {
            return access
        }
        let token = try await requestToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": current.clientID,
        ])
        lock.lock()
        stored?.accessToken = token.access
        stored?.expiresAt = token.expiresAt
        if let newRefresh = token.refresh { stored?.refreshToken = newRefresh }
        lock.unlock()
        persist()
        return token.access
    }

    private func api(_ path: String, query: [String: String] = [:]) async throws -> Any {
        let token = try await validToken()
        var components = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { .init(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Search

    /// Top results across artists, tracks, albums and public playlists, with
    /// the user's own matching playlists ranked first — the same shape the
    /// Spotify app's search page gives you. Pass `kind` when the user
    /// qualified the query ("kissland album") to search that type alone.
    public func search(_ text: String, kind: SpotifyItem.Kind? = nil) async throws -> [SpotifyItem] {
        async let ownTask = myPlaylists()
        let response = try await api("search", query: [
            "q": text,
            "type": kind?.rawValue ?? "artist,track,album,playlist",
            "limit": kind == nil ? "3" : "6",
        ]) as? [String: Any] ?? [:]

        func items(_ box: String, _ kind: SpotifyItem.Kind, detail: ([String: Any]) -> String) -> [SpotifyItem] {
            let list = ((response[box] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            return list.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                let uri = (item["uri"] as? String) ?? "spotify:\(kind.rawValue):\(id)"
                return SpotifyItem(id: id, kind: kind, name: name, detail: detail(item), uri: uri, isOwn: false)
            }
        }

        let artists = items("artists", .artist) { _ in "Artist" }
        let tracks = items("tracks", .track) { item in
            let names = ((item["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return names.isEmpty ? "Song" : names.joined(separator: ", ")
        }
        let albums = items("albums", .album) { item in
            let names = ((item["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return names.isEmpty ? "Album" : "Album · \(names.joined(separator: ", "))"
        }
        let playlists = items("playlists", .playlist) { item in
            let owner = ((item["owner"] as? [String: Any])?["display_name"] as? String) ?? "Playlist"
            return "Playlist · \(owner)"
        }

        let lower = text.lowercased()
        let own = ((try? await ownTask) ?? []).filter { $0.name.lowercased().contains(lower) }

        var out: [SpotifyItem]
        if let kind {
            // A qualified query: that type only, own playlists still first.
            out = kind == .playlist ? Array(own.prefix(3)) : []
            switch kind {
            case .artist:   out += artists
            case .track:    out += tracks
            case .album:    out += albums
            case .playlist: out += playlists
            }
        } else {
            // The user's own playlists first, then an artist when the query
            // looks like one, then songs, playlists, albums.
            out = Array(own.prefix(2))
            if let artist = artists.first, artist.name.lowercased().hasPrefix(lower) {
                out.append(artist)
            }
            out += tracks
            out += artists
            out += playlists
            out += albums
        }
        // The same playlist can arrive as "yours" and again from public
        // search — identical URIs make identical UI rows, so keep the first.
        var seenURIs = Set<String>()
        return out.filter { seenURIs.insert($0.uri).inserted }
    }

    /// The signed-in user's playlists, cached for five minutes.
    public func myPlaylists() async throws -> [SpotifyItem] {
        lock.lock()
        if let cache = playlistsCache, Date().timeIntervalSince(cache.at) < 300 {
            lock.unlock()
            return cache.items
        }
        lock.unlock()

        let response = try await api("me/playlists", query: ["limit": "50"]) as? [String: Any] ?? [:]
        let list = (response["items"] as? [[String: Any]]) ?? []
        let items: [SpotifyItem] = list.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return SpotifyItem(
                id: id, kind: .playlist, name: name, detail: "Your playlist",
                uri: (item["uri"] as? String) ?? "spotify:playlist:\(id)", isOwn: true
            )
        }
        lock.lock()
        playlistsCache = (items, Date())
        lock.unlock()
        return items
    }

    // MARK: - Loopback redirect catcher

    /// A one-shot HTTP listener that waits for Spotify's redirect and pulls
    /// the authorization code out of it.
    private static func catchRedirect(port: UInt16, expectedState: String) async throws -> String {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)

        let code: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let resumed = Locked(false)
                    listener.newConnectionHandler = { connection in
                        connection.start(queue: .global())
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                            let request = String(decoding: data ?? Data(), as: UTF8.self)
                            let result = Self.parseRedirect(request, expectedState: expectedState)
                            let page = result.message
                            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n" +
                                "<html><body style='font-family:sans-serif;padding:2em'>\(page)</body></html>"
                            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                            guard resumed.exchange(true) == false else { return }
                            if let value = result.code {
                                continuation.resume(returning: value)
                            } else {
                                continuation.resume(throwing: RemoteError.commandFailed(result.message))
                            }
                        }
                    }
                    listener.start(queue: .global())
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 180_000_000_000)
                throw RemoteError.commandFailed("Spotify sign-in timed out.")
            }
            defer { group.cancelAll(); listener.cancel() }
            guard let first = try await group.next() else {
                throw RemoteError.commandFailed("Spotify sign-in failed.")
            }
            return first
        }
        return code
    }

    private static func parseRedirect(_ request: String, expectedState: String) -> (code: String?, message: String) {
        guard let line = request.split(separator: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(target))
        else { return (nil, "Malformed redirect from Spotify.") }
        let query = components.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == expectedState else {
            return (nil, "State mismatch — try connecting again.")
        }
        if let error = query.first(where: { $0.name == "error" })?.value {
            return (nil, "Spotify said: \(error)")
        }
        guard let code = query.first(where: { $0.name == "code" })?.value else {
            return (nil, "No code in Spotify's redirect.")
        }
        return (code, "✓ Zapper is connected to Spotify. You can close this tab.")
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A tiny lock-boxed value for one-shot continuation guarding.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func exchange(_ new: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = new; return old
    }
}
