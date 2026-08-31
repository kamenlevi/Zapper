import Foundation

/// A button on a physical remote, named in device-neutral terms.
/// Each `RemoteDevice` maps these onto whatever its own protocol calls them.
public enum RemoteKey: String, Sendable, CaseIterable {
    case up, down, left, right, ok, back, home, exit, menu, info
    case play, pause, stop, rewind, fastForward
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case red, green, yellow, blue
    case guide, dash
    case num0, num1, num2, num3, num4, num5, num6, num7, num8, num9

    public static func digit(_ d: Int) -> RemoteKey? {
        RemoteKey(rawValue: "num\(d)")
    }
}

/// What a given device is actually able to do. The UI hides controls a device
/// can't honour rather than presenting buttons that silently do nothing.
public struct RemoteCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let dpad          = RemoteCapabilities(rawValue: 1 << 0)
    public static let absoluteVolume = RemoteCapabilities(rawValue: 1 << 1)
    public static let channels      = RemoteCapabilities(rawValue: 1 << 2)
    public static let inputs        = RemoteCapabilities(rawValue: 1 << 3)
    public static let apps          = RemoteCapabilities(rawValue: 1 << 4)
    public static let power         = RemoteCapabilities(rawValue: 1 << 5)
    public static let wakeOnLAN     = RemoteCapabilities(rawValue: 1 << 6)
    public static let pointer       = RemoteCapabilities(rawValue: 1 << 7)
    public static let textEntry     = RemoteCapabilities(rawValue: 1 << 8)
}

public struct DeviceInput: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let connected: Bool
    public init(id: String, label: String, connected: Bool = true) {
        self.id = id; self.label = label; self.connected = connected
    }
}

public struct TVChannel: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: String
    public let name: String
    public init(id: String, number: String, name: String) {
        self.id = id; self.number = number; self.name = name
    }
}

public struct DeviceApp: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let iconURL: URL?
    /// Bigger tile artwork, when the launch point advertises one over HTTP.
    public let largeIconURL: URL?
    /// The brand background the TV composes its own home-row tile with.
    public let tileColorHex: String?
    public init(id: String, label: String, iconURL: URL? = nil,
                largeIconURL: URL? = nil, tileColorHex: String? = nil) {
        self.id = id; self.label = label; self.iconURL = iconURL
        self.largeIconURL = largeIconURL; self.tileColorHex = tileColorHex
    }

    public var bestIconURL: URL? { largeIconURL ?? iconURL }
}

/// Live state pushed up from the device so the UI can reflect reality
/// instead of guessing from what it last sent.
public struct DeviceState: Equatable, Sendable {
    public var isOn: Bool = false
    public var volume: Int? = nil
    public var muted: Bool = false
    public var currentAppID: String? = nil
    public var currentAppLabel: String? = nil
    public var currentChannel: String? = nil
    public init() {}
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    /// The TV is showing its on-screen "allow this device?" prompt.
    case awaitingPairing
    case connected
    case failed(String)
}

public enum RemoteError: LocalizedError {
    case notConnected
    case pairingRejected
    case handshakeFailed(String)
    case commandFailed(String)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .notConnected:            return "Not connected to the device."
        case .pairingRejected:         return "The TV refused the pairing request."
        case .handshakeFailed(let m):  return "Handshake failed: \(m)"
        case .commandFailed(let m):    return "Command failed: \(m)"
        case .unsupported:             return "This device doesn't support that command."
        }
    }
}

/// One controllable device. `WebOSDevice` implements this today; an Apple TV
/// (Companion-link) or a HomeKit-paired set would slot in beside it without
/// the UI layer changing.
public protocol RemoteDevice: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var host: String { get }
    var capabilities: RemoteCapabilities { get }

    /// Async streams the UI observes. Both replay their current value on subscribe.
    var connectionStates: AsyncStream<ConnectionState> { get }
    var deviceStates: AsyncStream<DeviceState> { get }

    func connect() async
    func disconnect() async

    func press(_ key: RemoteKey) async throws
    func setVolume(_ level: Int) async throws
    func setMute(_ muted: Bool) async throws
    func openChannel(number: String) async throws
    func inputs() async throws -> [DeviceInput]
    func switchInput(id: String) async throws
    func apps() async throws -> [DeviceApp]
    func launchApp(id: String, contentTarget: String?) async throws
    func channels() async throws -> [TVChannel]
    func powerOff() async throws
    func powerOn() async throws
}
