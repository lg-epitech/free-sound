import AppKit
import Combine
import CoreAudio
import ServiceManagement

struct SystemChannel: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let role: SystemAudioRole
    var deviceID: AudioObjectID
    var volume: Float?
    var muted: Bool?
    var input: Bool { id == "input" }
}

struct AudioApplication: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processIDs: [AudioObjectID]
    var isPlaying: Bool
}

@MainActor
final class AudioController: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var channels: [SystemChannel] = []
    @Published var applications: [AudioApplication] = []
    @Published var preferences = AudioPreferences.load()
    @Published var errorMessage: String?
    @Published var appErrors: [String: String] = [:]
    @Published var levels: [String: Float] = [:]
    @Published var controlledApps: Set<String> = []
    @Published var search = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private struct ManagedEngine {
        let engine: ProcessAudioEngine
        let signature: RouteSignature
    }
    private struct RouteSignature: Equatable {
        let processes: [AudioObjectID]
        let deviceID: AudioObjectID
        let sampleRate: Double?
    }
    private var attemptedRoutes: [String: RouteSignature] = [:]
    private var sleeping = false
    private var engines: [String: ManagedEngine] = [:]
    private var refreshTimer: Timer?
    private var meterTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var volumeBeforeMute: [AudioObjectID: Float] = [:]

    var outputDevices: [AudioDevice] { devices.filter(\.hasOutput) }
    var inputDevices: [AudioDevice] { devices.filter(\.hasInput) }
    var enabled: Bool { preferences.controlsEnabled }
    var visibleApplications: [AudioApplication] {
        applications.filter {
            (!preferences.onlyFavorites || settings(for: $0.id).favorite) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            let lhs = settings(for: $0.id).favorite
            let rhs = settings(for: $1.id).favorite
            if lhs != rhs { return lhs }
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readMeters() }
        }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }
        if let meterTimer { RunLoop.main.add(meterTimer, forMode: .common) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.stopEngines() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.refresh() }
        })
    }

    func settings(for id: String) -> AppAudioSettings { preferences.apps[id] ?? AppAudioSettings() }

    func update(_ id: String, _ mutation: (inout AppAudioSettings) -> Void) {
        var settings = settings(for: id)
        mutation(&settings)
        settings.normalize()
        preferences.apps[id] = settings
        preferences.save()
        appErrors[id] = nil
        reconcileEngines()
    }

    func setControlsEnabled(_ value: Bool) {
        preferences.controlsEnabled = value
        preferences.save()
        appErrors.removeAll()
        if value { reconcileEngines() } else { stopEngines() }
    }

    func togglePinned() {
        preferences.pinned.toggle()
        preferences.save()
        NotificationCenter.default.post(name: .freeSoundPinChanged, object: nil)
    }

    func toggleFavoritesFilter() {
        preferences.onlyFavorites.toggle()
        preferences.save()
    }

    func resetMix() {
        for id in preferences.apps.keys {
            let favorite = preferences.apps[id]?.favorite ?? false
            preferences.apps[id] = AppAudioSettings(favorite: favorite)
        }
        preferences.save()
        appErrors.removeAll()
        stopEngines()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { errorMessage = "Couldn’t change launch at login: \(error.localizedDescription)" }
    }

    func setSystemVolume(_ value: Float, channel: SystemChannel) {
        do {
            try SystemAudio.setVolume(value, of: channel.deviceID, input: channel.input)
            if value > 0, channel.muted == true {
                try SystemAudio.setMuted(false, of: channel.deviceID, input: channel.input)
            }
            refreshChannels()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleSystemMute(_ channel: SystemChannel) {
        do {
            if let muted = channel.muted {
                try SystemAudio.setMuted(!muted, of: channel.deviceID, input: channel.input)
            } else if let volume = channel.volume {
                if volume > 0 {
                    volumeBeforeMute[channel.deviceID] = volume
                    try SystemAudio.setVolume(0, of: channel.deviceID, input: channel.input)
                } else {
                    try SystemAudio.setVolume(volumeBeforeMute[channel.deviceID] ?? 0.25, of: channel.deviceID, input: channel.input)
                }
            }
            refreshChannels()
        } catch { errorMessage = error.localizedDescription }
    }

    func setDevice(_ id: AudioObjectID, channel: SystemChannel) {
        do {
            try SystemAudio.setDefaultDevice(id, for: channel.role)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() {
        do {
            devices = try SystemAudio.devices()
            refreshChannels()
            applications = discoverApplications(try SystemAudio.processes())
            reconcileEngines()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshChannels() {
        let definitions: [(String, String, String, SystemAudioRole)] = [
            ("output", "Output", "speaker.wave.2.fill", .output),
            ("input", "Input", "mic.fill", .input),
            ("effects", "Sound effects", "bell.fill", .soundEffects),
        ]
        channels = definitions.map { id, title, symbol, role in
            let device = (try? SystemAudio.defaultDevice(for: role)) ?? 0
            return SystemChannel(id: id, title: title, symbol: symbol, role: role, deviceID: device,
                                 volume: id == "effects" ? nil : SystemAudio.volume(of: device, input: id == "input"),
                                 muted: id == "effects" ? nil : SystemAudio.isMuted(device, input: id == "input"))
        }
    }

    private func discoverApplications(_ processes: [AudioProcessInfo]) -> [AudioApplication] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let normal = running.filter { $0.activationPolicy == .regular }
        let owners = running.filter { app in
            guard let path = app.bundleURL?.path else { return false }
            return path.hasSuffix(".app") && !path.contains(".app/Contents/")
        }
        var grouped: [String: AudioApplication] = [:]
        for process in processes where process.pid != ProcessInfo.processInfo.processIdentifier {
            let exact = running.first { $0.processIdentifier == process.pid }
            let owner = normal.first { $0.processIdentifier == process.pid }
                ?? owners.filter { app in
                    guard let bundle = app.bundleIdentifier else { return false }
                    let identifier = process.bundleID.lowercased()
                    if identifier == bundle.lowercased() || identifier.hasPrefix(bundle.lowercased() + ".") { return true }
                    if let root = app.bundleURL?.path, let executable = exact?.executableURL?.path {
                        return executable.hasPrefix(root + "/")
                    }
                    return false
                }.max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
                ?? exact
            guard let owner, owner.activationPolicy == .regular || owner.bundleURL?.path.contains(".app") == true else { continue }
            let id = owner.bundleIdentifier ?? (process.bundleID.isEmpty ? "pid.\(process.pid)" : process.bundleID)
            guard id != Bundle.main.bundleIdentifier, !id.hasPrefix("app.freesound.") else { continue }
            if id.hasPrefix("com.apple."), owner.activationPolicy != .regular,
               !process.isRunningOutput, !settings(for: id).favorite { continue }
            if grouped[id] == nil {
                grouped[id] = AudioApplication(id: id, name: owner.localizedName ?? id, icon: owner.icon, processIDs: [], isPlaying: false)
            }
            grouped[id]?.processIDs.append(process.id)
            let wasPlaying = grouped[id]?.isPlaying ?? false
            grouped[id]?.isPlaying = wasPlaying || process.isRunningOutput
        }
        for app in normal {
            guard let id = app.bundleIdentifier, settings(for: id).favorite, grouped[id] == nil else { continue }
            grouped[id] = AudioApplication(id: id, name: app.localizedName ?? id, icon: app.icon, processIDs: [], isPlaying: false)
        }
        return grouped.values.map { app in
            var result = app
            result.processIDs.sort()
            return result
        }
    }

    private func reconcileEngines() {
        guard enabled && !sleeping else { return }
        let wanted = Set(applications.filter { settings(for: $0.id).needsProcessing && !$0.processIDs.isEmpty }.map(\.id))
        for id in Array(engines.keys) where !wanted.contains(id) {
            engines.removeValue(forKey: id)?.engine.stop()
            levels[id] = nil
            attemptedRoutes[id] = nil
        }
        let defaultOutput = channels.first { $0.id == "output" }?.deviceID
        for app in applications where wanted.contains(app.id) {
            let settings = settings(for: app.id)
            guard let output = outputDevices.first(where: { $0.uid == settings.outputUID })
                    ?? outputDevices.first(where: { $0.id == defaultOutput }) else {
                engines.removeValue(forKey: app.id)?.engine.stop()
                attemptedRoutes[app.id] = nil
                appErrors[app.id] = "Connect an output device to control this app."
                continue
            }
            let signature = RouteSignature(processes: app.processIDs, deviceID: output.id, sampleRate: SystemAudio.sampleRate(of: output.id))
            if attemptedRoutes[app.id] != signature {
                appErrors[app.id] = nil
                attemptedRoutes[app.id] = signature
            }
            if let current = engines[app.id], current.signature != signature {
                current.engine.stop()
                engines[app.id] = nil
                appErrors[app.id] = nil
            }
            if engines[app.id] == nil && appErrors[app.id] == nil {
                do {
                    let engine = ProcessAudioEngine(processIDs: app.processIDs, outputDeviceID: output.id, outputUID: output.uid)
                    engine.setGain(settings.volume)
                    engine.setMuted(settings.muted)
                    engine.setBalance(settings.balance)
                    try engine.start()
                    engines[app.id] = ManagedEngine(engine: engine, signature: signature)
                } catch {
                    appErrors[app.id] = error.localizedDescription
                }
            }
            engines[app.id]?.engine.setGain(settings.volume)
            engines[app.id]?.engine.setMuted(settings.muted)
            engines[app.id]?.engine.setBalance(settings.balance)
        }
        controlledApps = Set(engines.keys)
    }

    func retry(_ id: String) {
        appErrors[id] = nil
        reconcileEngines()
    }

    private func readMeters() {
        var next: [String: Float] = [:]
        for (id, managed) in engines {
            next[id] = max(managed.engine.peakLevel, (levels[id] ?? 0) * 0.78)
        }
        if !next.isEmpty || !levels.isEmpty { levels = next }
    }

    private func stopEngines() {
        for managed in engines.values { managed.engine.stop() }
        engines.removeAll()
        attemptedRoutes.removeAll()
        levels.removeAll()
        controlledApps.removeAll()
    }

    func shutdown() {
        refreshTimer?.invalidate()
        meterTimer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        stopEngines()
    }
}

extension Notification.Name {
    static let freeSoundPinChanged = Notification.Name("FreeSound.pinChanged")
}
