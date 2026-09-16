import AppKit
import SwiftUI

enum MixerTheme {
    static let background = Color(red: 0.105, green: 0.116, blue: 0.125)
    static let surface = Color.white.opacity(0.045)
    static let accent = Color(red: 0.22, green: 0.83, blue: 0.64)
    static let muted = Color(red: 0.98, green: 0.38, blue: 0.49)
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.48)
    static let tertiary = Color.white.opacity(0.26)
    static let line = Color.white.opacity(0.06)
}

struct MixerView: View {
    @ObservedObject var audio: AudioController
    @State private var showSearch = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let message = audio.errorMessage {
                Notice(message: message, symbol: "exclamationmark.triangle.fill") { audio.errorMessage = nil }
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 22) {
                DeviceSection(audio: audio, role: .output)
                DeviceSection(audio: audio, role: .input)
                soundEffects
            }
            .padding(.horizontal, 20)
            applications
                .padding(.top, 26)
        }
        .frame(minWidth: 480, idealWidth: 520, maxWidth: .infinity, minHeight: 640)
        .background(MixerTheme.background)
        .foregroundStyle(MixerTheme.primary)
        .tint(MixerTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Spacer()
            Button { audio.togglePinned() } label: {
                Image(systemName: audio.preferences.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(audio.preferences.pinned ? MixerTheme.accent : MixerTheme.secondary)
            }.buttonStyle(ToolButtonStyle()).help(audio.preferences.pinned ? "Unpin" : "Keep on top")
            settingsMenu
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var soundEffects: some View {
        HStack {
            Text("Sound effects").font(.system(size: 12)).foregroundStyle(MixerTheme.secondary)
            Spacer()
            if let channel = audio.channel(for: .soundEffects) {
                Menu {
                    ForEach(audio.outputDevices) { device in
                        Button { audio.setDevice(device.id, for: .soundEffects) } label: {
                            Label(device.name, systemImage: device.id == channel.deviceID ? "checkmark" : device.symbolName)
                        }
                    }
                } label: {
                    let device = audio.devices.first { $0.id == channel.deviceID }
                    DeviceLabel(name: device?.name ?? "No device", symbol: device?.symbolName ?? "speaker.slash", quiet: true)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 14)
    }

    private var applications: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                SectionLabel("Applications")
                Spacer()
                Button { audio.toggleFavoritesFilter() } label: {
                    Image(systemName: audio.preferences.onlyFavorites ? "star.fill" : "star")
                        .foregroundStyle(audio.preferences.onlyFavorites ? MixerTheme.accent : MixerTheme.secondary)
                }.buttonStyle(ToolButtonStyle()).help("Only favorites")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSearch.toggle()
                        if !showSearch { audio.search = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(showSearch ? MixerTheme.accent : MixerTheme.secondary)
                }.buttonStyle(ToolButtonStyle()).help("Find an application")
            }
            .padding(.horizontal, 20)
            if showSearch {
                TextField("Find", text: $audio.search)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(MixerTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if audio.visibleApplications.isEmpty {
                        Text(audio.search.isEmpty ? (audio.preferences.onlyFavorites ? "No favorites yet" : "Nothing is playing") : "No matches")
                            .font(.system(size: 13)).foregroundStyle(MixerTheme.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 36)
                    } else {
                        ForEach(audio.visibleApplications) { app in
                            ApplicationRow(audio: audio, app: app, expanded: Binding(get: { expanded.contains(app.id) }, set: { value in
                                if value { expanded.insert(app.id) } else { expanded.remove(app.id) }
                            }))
                            if app.id != audio.visibleApplications.last?.id {
                                Rectangle().fill(MixerTheme.line).frame(height: 1).padding(.leading, 52)
                            }
                        }
                    }
                }
                .background(MixerTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("App controls", isOn: Binding(get: { audio.enabled }, set: audio.setControlsEnabled))
            Toggle("Launch at login", isOn: Binding(get: { audio.launchAtLogin }, set: audio.setLaunchAtLogin))
            Divider()
            Menu("Add favorite") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }, id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier {
                        Button {
                            audio.update(id) { $0.favorite.toggle() }
                            audio.refresh()
                        } label: {
                            Label(app.localizedName ?? id, systemImage: audio.settings(for: id).favorite ? "star.fill" : "star")
                        }
                    }
                }
            }
            Button("Reset app mix") { audio.resetMix() }
            Divider()
            Button("Sound settings…") { openSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
            Button("Audio capture permission…") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
            Divider()
            Button("About FreeSound") { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
            Button("Quit FreeSound") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(MixerTheme.secondary)
    }
}

/// An output or input block: the hardware volume of the device in use, then the priority list.
struct DeviceSection: View {
    @ObservedObject var audio: AudioController
    let role: SystemAudioRole

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(role == .input ? "Input" : "Output")
            VStack(spacing: 0) {
                if let channel = audio.channel(for: role) {
                    VolumeControl(value: Binding(get: { Double(channel.volume ?? 0) }, set: { audio.setSystemVolume(Float($0), channel: channel) }),
                                  muted: channel.muted == true || channel.volume == 0,
                                  available: channel.volume != nil,
                                  canMute: channel.muted != nil || channel.volume != nil,
                                  label: channel.title, toggleMute: { audio.toggleSystemMute(channel) })
                        .padding(.horizontal, 14).frame(height: 42)
                    Rectangle().fill(MixerTheme.line).frame(height: 1)
                }
                DevicePriorityList(audio: audio, role: role)
            }
            .background(MixerTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Devices in the order they should be used. Drag to reorder; the first connected one is in use.
struct DevicePriorityList: View {
    @ObservedObject var audio: AudioController
    let role: SystemAudioRole
    private let rowHeight: CGFloat = 32

    var body: some View {
        let entries = audio.priorityEntries(for: role)
        List {
            ForEach(entries) { entry in
                DeviceRow(audio: audio, role: role, entry: entry, count: entries.count)
                    .frame(height: rowHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove { audio.movePriority(for: role, fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .environment(\.defaultMinListRowHeight, rowHeight)
        .frame(height: CGFloat(max(entries.count, 1)) * rowHeight)
        .padding(.vertical, 4)
    }
}

struct DeviceRow: View {
    @ObservedObject var audio: AudioController
    let role: SystemAudioRole
    let entry: PriorityEntry
    let count: Int
    @State private var hovering = false

    private var nameColor: Color {
        if !entry.connected { return MixerTheme.tertiary }
        return entry.active ? MixerTheme.accent : MixerTheme.primary
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(entry.rank)")
                .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(entry.active ? MixerTheme.accent : MixerTheme.tertiary)
                .frame(width: 16, alignment: .trailing)
            Image(systemName: entry.device.symbol)
                .font(.system(size: 12)).foregroundStyle(nameColor.opacity(entry.connected ? 0.85 : 1))
                .frame(width: 18)
            Text(entry.device.name)
                .font(.system(size: 13, weight: entry.active ? .semibold : .regular))
                .foregroundStyle(nameColor).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if !entry.connected {
                Text("Not connected").font(.system(size: 11)).foregroundStyle(MixerTheme.tertiary)
            }
            if hovering, !entry.connected {
                Button { audio.forgetDevice(entry.device.uid, for: role) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                }.buttonStyle(.plain).foregroundStyle(MixerTheme.secondary).help("Forget this device")
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MixerTheme.tertiary)
                .opacity(hovering && count > 1 ? 1 : 0)
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .contentShape(Rectangle())
        .background(hovering && entry.connected && !entry.active ? Color.white.opacity(0.035) : .clear)
        .onHover { hovering = $0 }
        .onTapGesture { if entry.connected, !entry.active { audio.useDevice(entry.device.uid, for: role) } }
        .contextMenu {
            if entry.connected, !entry.active { Button("Use now") { audio.useDevice(entry.device.uid, for: role) } }
            Button("Move to top") { audio.movePriorityToTop(for: role, uid: entry.device.uid) }.disabled(entry.rank == 1)
            Button("Move up") { audio.movePriority(for: role, uid: entry.device.uid, by: -1) }.disabled(entry.rank == 1)
            Button("Move down") { audio.movePriority(for: role, uid: entry.device.uid, by: 1) }.disabled(entry.rank == count)
            if !entry.connected {
                Divider()
                Button("Forget") { audio.forgetDevice(entry.device.uid, for: role) }
            }
        }
        .help(entry.connected ? (entry.active ? "In use" : "Click to use now, drag to change priority") : "Not connected. It will be used again when it comes back, if nothing above it is connected.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.rank). \(entry.device.name)\(entry.active ? ", in use" : "")\(entry.connected ? "" : ", not connected")")
    }
}

struct ApplicationRow: View {
    @ObservedObject var audio: AudioController
    let app: AudioApplication
    @Binding var expanded: Bool
    @State private var hovering = false
    private var settings: AppAudioSettings { audio.settings(for: app.id) }
    private var active: Bool { audio.enabled && !app.processIDs.isEmpty }
    private var routeAvailable: Bool { settings.outputUID == nil || audio.device(uid: settings.outputUID) != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                    else { Image(systemName: "app.fill").font(.system(size: 26)).frame(width: 28, height: 28) }
                    if app.isPlaying {
                        Circle().fill(MixerTheme.accent).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(MixerTheme.background, lineWidth: 2)).offset(x: 2, y: 2)
                    }
                }
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if settings.outputUID != nil {
                    Image(systemName: routeAvailable ? "arrow.turn.up.right" : "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(routeAvailable ? MixerTheme.accent : .orange)
                        .help(routeAvailable ? "Playing on \(routeName)" : "\(routeName) is not connected, using the system output")
                }
                Button { audio.update(app.id) { $0.favorite.toggle() } } label: {
                    Image(systemName: settings.favorite ? "star.fill" : "star").font(.system(size: 11))
                        .foregroundStyle(settings.favorite ? MixerTheme.accent : MixerTheme.tertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).opacity(settings.favorite || hovering ? 1 : 0)
                .accessibilityLabel(settings.favorite ? "Remove \(app.name) from favorites" : "Favorite \(app.name)")
                .help(settings.favorite ? "Remove favorite" : "Favorite")
                Spacer(minLength: 6)
                VolumeControl(value: Binding(get: { Double(settings.volume) }, set: { value in audio.update(app.id) { $0.volume = Float(value) } }),
                              muted: settings.muted, available: !app.processIDs.isEmpty, canMute: !app.processIDs.isEmpty, maximum: settings.boost ? 2 : 1,
                              showValueWhenDisabled: true, label: app.name, toggleMute: { audio.update(app.id) { $0.muted.toggle() } })
                    .frame(width: 180)
                Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 20, height: 24)
                }.buttonStyle(.plain).foregroundStyle(MixerTheme.tertiary).accessibilityLabel("\(app.name) options").help("Output, balance and boost")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            if let message = audio.appErrors[app.id] {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry") { audio.retry(app.id) }.controlSize(.small)
                    Button("Permission…") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }.controlSize(.small)
                }.padding(.horizontal, 14).padding(.bottom, 12)
            }
            if expanded { details }
        }
    }

    private var routeName: String {
        guard let uid = settings.outputUID else { return "System output" }
        return audio.deviceName(uid: uid) ?? "Unavailable device"
    }

    private var details: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("Output").font(.system(size: 11)).foregroundStyle(MixerTheme.secondary).frame(width: 50, alignment: .leading)
                Menu {
                    Button { audio.update(app.id) { $0.outputUID = nil } } label: {
                        Label("System output", systemImage: settings.outputUID == nil ? "checkmark" : "arrow.turn.up.right")
                    }
                    Divider()
                    ForEach(audio.outputDevices) { device in
                        Button { audio.update(app.id) { $0.outputUID = device.uid } } label: {
                            Label(device.name, systemImage: settings.outputUID == device.uid ? "checkmark" : device.symbolName)
                        }
                    }
                } label: {
                    DeviceLabel(name: routeName, symbol: settings.outputUID == nil ? "arrow.turn.up.right" : routeAvailable ? "headphones" : "exclamationmark.triangle")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 200).disabled(app.processIDs.isEmpty)
                Spacer()
                Button("Reset") {
                    audio.update(app.id) { let favorite = $0.favorite; $0 = AppAudioSettings(favorite: favorite) }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(MixerTheme.secondary).disabled(!settings.needsProcessing && !settings.boost)
            }
            HStack(spacing: 12) {
                Text("Balance").font(.system(size: 11)).foregroundStyle(MixerTheme.secondary).frame(width: 50, alignment: .leading)
                HStack(spacing: 6) {
                    Text("L").font(.system(size: 10)).foregroundStyle(MixerTheme.tertiary)
                    Slider(value: Binding(get: { Double(settings.balance) }, set: { value in audio.update(app.id) { $0.balance = Float(value) } }), in: -1...1)
                        .controlSize(.mini).frame(width: 120).disabled(app.processIDs.isEmpty).accessibilityLabel("\(app.name) balance")
                    Text("R").font(.system(size: 10)).foregroundStyle(MixerTheme.tertiary)
                }
                if abs(settings.balance) > 0.001 {
                    Button("Center") { audio.update(app.id) { $0.balance = 0 } }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(MixerTheme.secondary)
                }
                Spacer()
                Toggle("Boost", isOn: Binding(get: { settings.boost }, set: { value in audio.update(app.id) { $0.boost = value } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).foregroundStyle(MixerTheme.secondary)
                    .disabled(app.processIDs.isEmpty).help("Allow up to 200%")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.black.opacity(0.14))
    }
}

struct VolumeControl: View {
    @Binding var value: Double
    let muted: Bool
    let available: Bool
    let canMute: Bool
    var maximum: Double = 1
    var showValueWhenDisabled = false
    let label: String
    let toggleMute: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleMute) {
                Image(systemName: muted ? "speaker.slash.fill" : value > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill")
                    .font(.system(size: 12)).foregroundStyle(muted ? MixerTheme.muted : MixerTheme.secondary).frame(width: 18)
            }.buttonStyle(.plain).disabled(!canMute).accessibilityLabel("\(muted ? "Unmute" : "Mute") \(label)").help(muted ? "Unmute" : "Mute")
            Slider(value: $value, in: 0...maximum)
                .controlSize(.mini).tint(muted ? MixerTheme.muted : MixerTheme.accent)
                .disabled(!available).accessibilityLabel("\(label) volume")
                .accessibilityValue(available || showValueWhenDisabled ? "\(Int(value * 100)) percent" : "Device has fixed volume")
            Text(available || showValueWhenDisabled ? "\(Int((value * 100).rounded()))%" : "Fixed")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(available ? MixerTheme.primary.opacity(0.8) : MixerTheme.tertiary).frame(width: 38, alignment: .trailing)
        }
    }
}

struct DeviceLabel: View {
    let name: String
    let symbol: String
    var quiet = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(MixerTheme.secondary)
            Text(name).font(.system(size: quiet ? 12 : 11, weight: quiet ? .regular : .medium))
                .foregroundStyle(quiet ? MixerTheme.secondary : MixerTheme.primary).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(MixerTheme.secondary)
        }
        .padding(.horizontal, quiet ? 0 : 9).frame(height: 26)
        .background(quiet ? Color.clear : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).tracking(0.9)
            .foregroundStyle(MixerTheme.secondary)
    }
}

struct Notice: View {
    let message: String
    let symbol: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(MixerTheme.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).frame(width: 28, height: 28)
            .foregroundStyle(MixerTheme.secondary)
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

private func openSettings(_ url: String) {
    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
}
