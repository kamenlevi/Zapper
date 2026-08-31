import Foundation
import SwiftUI
import ZapperKit

/// Bridges ZapperKit's async streams into observable state for the popover,
/// and owns the currently selected device.
@MainActor
final class RemoteController: ObservableObject {

    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var state = DeviceState()
    @Published private(set) var inputs: [DeviceInput] = []
    @Published private(set) var apps: [DeviceApp] = []
    @Published var selectedDeviceID: String?
    @Published var transientMessage: String?

    /// The three quick-launch slots, resolved against the TV's app list when
    /// it arrives. A nil slot renders as a placeholder until then.
    @Published private(set) var quickApps: [DeviceApp?] = [nil, nil, nil]
    /// Tile artwork by app id, loaded from the disk cache at startup so the
    /// tiles render even while the TV is still connecting.
    @Published private(set) var quickIcons: [String: NSImage] = [:]
    /// Brand background per app id (hex), from the TV's `iconColor` — with
    /// the icon's own corner pixel as fallback so unknown apps still blend.
    @Published private(set) var quickColors: [String: String] = [:]

    /// Volume the user is actively dragging, so the slider doesn't fight the
    /// TV's own status pushes mid-gesture.
    @Published var scrubbingVolume: Double?

    // Search state; the matching logic lives in Search.swift.
    @Published var searchText = ""
    @Published var suggestions: [Suggestion] = []
    @Published var selectedIndex = 0
    var channelsList: [TVChannel] = []
    var contentTask: Task<Void, Never>?

    private let discovery = Discovery()
    private var device: WebOSDevice?
    private var observations: [Task<Void, Never>] = []
    private var messageResetTask: Task<Void, Never>?

    private let lastDeviceKey = "Zapper.lastDeviceID"
    private let quickLaunchKey = "Zapper.quickLaunchAppIDs"
    private let tileColorsKey = "Zapper.tileColorsByAppID"
    private let defaultQuickIDs = ["com.webos.app.livetv", "netflix", "com.wbd.stream"]

    var currentDevice: DiscoveredDevice? {
        discovered.first { $0.id == selectedDeviceID }
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var statusText: String {
        switch connection {
        case .connected:
            return state.isOn ? "On" : "Standby"
        case .connecting:      return "Connecting…"
        case .awaitingPairing: return "Accept on TV"
        case .disconnected:    return "Offline"
        case .failed:          return "Unreachable"
        }
    }

    // MARK: - Lifecycle

    func start() {
        loadCachedQuickLaunch()
        observations.append(Task { [weak self] in
            guard let self else { return }
            for await found in self.discovery.devices.stream() {
                self.discovered = found
                self.autoSelectIfNeeded()
            }
        })
        discovery.start()
    }

    private func autoSelectIfNeeded() {
        if let chosen = selectedDeviceID {
            if let current = discovered.first(where: { $0.id == chosen }) {
                // Re-attach if the chosen device moved to a new address.
                if let device, device.host != current.host { device.updateHost(current.host) }
                return
            }
            // The selected entry vanished — usually a placeholder replaced by
            // the real advertisement for the same TV. Follow it over.
            if let successor = discovered.first(where: { $0.host == device?.host }) {
                select(successor)
                return
            }
            selectedDeviceID = nil
        }
        let remembered = UserDefaults.standard.string(forKey: lastDeviceKey)
        let choice = discovered.first { $0.id == remembered }
            ?? discovered.first { $0.kind == .webOS }
        guard let choice else { return }
        select(choice)
    }

    func select(_ found: DiscoveredDevice) {
        guard found.kind == .webOS else {
            transientMessage = "\(found.name) isn't supported yet."
            return
        }
        selectedDeviceID = found.id
        UserDefaults.standard.set(found.id, forKey: lastDeviceKey)

        let previous = device
        Task { await previous?.disconnect() }
        observations.dropFirst().forEach { $0.cancel() }
        observations = Array(observations.prefix(1))

        let next = WebOSDevice(id: found.id, displayName: found.name, host: found.host)
        device = next
        inputs = []
        apps = []

        observations.append(Task { [weak self] in
            guard let self else { return }
            for await value in next.connectionStates {
                self.connection = value
                if case .connected = value { await self.loadCatalogues() }
                if case .failed(let message) = value { self.flash(message) }
            }
        })
        observations.append(Task { [weak self] in
            guard let self else { return }
            for await value in next.deviceStates { self.state = value }
        })

        Task { await next.connect() }
    }

    func reconnect() {
        guard let found = currentDevice else {
            discovery.start()
            return
        }
        select(found)
    }

    func forgetPairing() {
        guard let device else { return }
        Task {
            await device.unpair()
            flash("Pairing forgotten.")
        }
    }

    private func loadCatalogues() async {
        guard let device else { return }
        inputs = (try? await device.inputs()) ?? []
        apps = (try? await device.apps()) ?? []
        channelsList = (try? await device.channels()) ?? []
        refreshQuickLaunch()
    }

    // MARK: - Quick launch

    private var quickIDs: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: quickLaunchKey) ?? defaultQuickIDs
        // Pad or trim so the row is always exactly three slots.
        return Array((stored + defaultQuickIDs).prefix(3))
    }

    /// Before the TV has answered: put up whatever we know from last time —
    /// cached icons and colours from disk, ids as stand-in labels.
    private func loadCachedQuickLaunch() {
        quickApps = quickIDs.map { DeviceApp(id: $0, label: $0) }
        quickColors = (UserDefaults.standard.dictionary(forKey: tileColorsKey) as? [String: String]) ?? [:]
        for id in quickIDs {
            if let image = IconCache.load(appID: id) { quickIcons[id] = image }
        }
    }

    /// Once the app list is in: swap in real labels and fetch missing artwork.
    private func refreshQuickLaunch() {
        quickApps = quickIDs.map { id in
            apps.first { $0.id == id } ?? DeviceApp(id: id, label: id)
        }
        for case let app? in quickApps {
            if let hex = app.tileColorHex { quickColors[app.id] = hex }
        }
        UserDefaults.standard.set(quickColors, forKey: tileColorsKey)
        fetchMissingQuickIcons()
    }

    func setQuickApp(_ app: DeviceApp, slot: Int) {
        guard quickApps.indices.contains(slot) else { return }
        var ids = quickIDs
        ids[slot] = app.id
        UserDefaults.standard.set(ids, forKey: quickLaunchKey)
        refreshQuickLaunch()
    }

    private func fetchMissingQuickIcons() {
        guard let device else { return }
        for case let app? in quickApps where quickIcons[app.id] == nil {
            if let cached = IconCache.load(appID: app.id) {
                quickIcons[app.id] = cached
                continue
            }
            guard let url = app.bestIconURL else { continue }
            Task { [weak self] in
                guard let data = try? await device.fetchIconData(from: url),
                      let image = NSImage(data: data) else { return }
                IconCache.save(data, appID: app.id)
                guard let self else { return }
                self.quickIcons[app.id] = image
                // No colour from the TV: blend with the artwork's own edge
                // so the tile still reads as one solid card.
                if self.quickColors[app.id] == nil,
                   let hex = IconCache.edgeColorHex(of: image) {
                    self.quickColors[app.id] = hex
                    UserDefaults.standard.set(self.quickColors, forKey: self.tileColorsKey)
                }
            }
        }
    }

    // MARK: - Commands

    private func run(_ label: String, _ work: @escaping (WebOSDevice) async throws -> Void) {
        guard let device else { flash("No TV selected."); return }
        Task {
            do { try await work(device) }
            catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                flash(message)
            }
        }
    }

    func press(_ key: RemoteKey) {
        run("press") { try await $0.press(key) }
    }

    func setVolume(_ level: Int) {
        run("volume") { try await $0.setVolume(level) }
    }

    func toggleMute() {
        let target = !state.muted
        run("mute") { try await $0.setMute(target) }
    }

    func openChannel(_ number: String) {
        guard !number.isEmpty else { return }
        run("channel") { try await $0.openChannel(number: number) }
    }

    func switchInput(_ input: DeviceInput) {
        run("input") { try await $0.switchInput(id: input.id) }
    }

    func launch(_ app: DeviceApp, contentTarget: String? = nil) {
        run("launch") { try await $0.launchApp(id: app.id, contentTarget: contentTarget) }
    }

    func togglePower() {
        guard let device else { return }
        Task {
            do {
                if state.isOn, isConnected {
                    try await device.powerOff()
                } else {
                    try await device.powerOn()
                    flash("Wake signal sent.")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                flash(message)
            }
        }
    }

    private func flash(_ message: String) {
        transientMessage = message
        messageResetTask?.cancel()
        messageResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}
