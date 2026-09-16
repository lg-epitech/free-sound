import AppKit
import SwiftUI

enum MixerTheme {
    static let background = Color(red: 0.105, green: 0.116, blue: 0.125)
    static let surface = Color(red: 0.145, green: 0.157, blue: 0.169)
    static let accent = Color(red: 0.22, green: 0.83, blue: 0.64)
    static let muted = Color(red: 0.98, green: 0.38, blue: 0.49)
    static let secondary = Color.white.opacity(0.47)
    static let line = Color.white.opacity(0.07)
}

struct MixerView: View {
    @ObservedObject var audio: AudioController
    @State private var showSearch = false
    @State private var showInfo = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    if let message = audio.errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { audio.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    systemSection
                    applicationSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            footer
        }
        .frame(minWidth: 730, idealWidth: 730, maxWidth: .infinity, minHeight: 480)
        .background(MixerTheme.background)
        .foregroundStyle(.white.opacity(0.94))
        .tint(MixerTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(MixerTheme.accent)
                .frame(width: 40, height: 40)
                .background(MixerTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("FreeSound").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("A little more control.").font(.system(size: 11)).foregroundStyle(MixerTheme.secondary)
            }
            Spacer()
            Button { audio.togglePinned() } label: {
                Image(systemName: audio.preferences.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(audio.preferences.pinned ? MixerTheme.accent : MixerTheme.secondary)
            }.buttonStyle(ToolButtonStyle()).help(audio.preferences.pinned ? "Unpin mixer" : "Keep mixer on top")
            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(ToolButtonStyle()).help("About FreeSound")
                .popover(isPresented: $showInfo) { about.padding(20).frame(width: 325) }
            settingsMenu
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 23)
    }

    private var systemSection: some View {
        VStack(spacing: 0) {
            HStack {
                Label("System", systemImage: "hifispeaker.2").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Volume").frame(width: 185, alignment: .leading)
                Text("Device").frame(width: 210, alignment: .leading)
            }.foregroundStyle(MixerTheme.secondary).font(.system(size: 11)).padding(.horizontal, 17).padding(.vertical, 15)
            Rectangle().fill(MixerTheme.line).frame(height: 1)
            ForEach(audio.channels) { channel in
                SystemChannelRow(audio: audio, channel: channel)
                if channel.id != audio.channels.last?.id {
                    Rectangle().fill(MixerTheme.line).frame(height: 1).padding(.leading, 52)
                }
            }
        }
        .background(MixerTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(MixerTheme.line))
    }

    private var applicationSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Applications", systemImage: "square.stack.3d.up").font(.system(size: 13, weight: .semibold))
                Text("\(audio.applications.count)")
                    .font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.07), in: Capsule())
                Spacer()
                Button { audio.toggleFavoritesFilter() } label: {
                    Image(systemName: audio.preferences.onlyFavorites ? "star.fill" : "star")
                        .foregroundStyle(audio.preferences.onlyFavorites ? MixerTheme.accent : MixerTheme.secondary)
                }.buttonStyle(.plain).help("Show only favorites")
                Button { withAnimation(.easeInOut(duration: 0.15)) { showSearch.toggle(); if !showSearch { audio.search = "" } } } label: {
                    Image(systemName: "magnifyingglass")
                }.buttonStyle(.plain).padding(.leading, 10).help("Find an application")
            }.foregroundStyle(MixerTheme.secondary).padding(.horizontal, 17).padding(.vertical, 15)
            if showSearch {
                TextField("Find an application", text: $audio.search).textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            Rectangle().fill(MixerTheme.line).frame(height: 1)
            if !audio.enabled {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 20)).foregroundStyle(MixerTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Give every app its own volume.").font(.system(size: 12, weight: .semibold))
                        Text("macOS asks for audio access on your first adjustment.")
                            .font(.system(size: 11)).foregroundStyle(MixerTheme.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("Enable app controls") { audio.setControlsEnabled(true) }
                        .buttonStyle(.borderedProminent).controlSize(.small).foregroundStyle(MixerTheme.background)
                }.padding(16).background(MixerTheme.accent.opacity(0.045))
                Rectangle().fill(MixerTheme.line).frame(height: 1)
            }
            if audio.visibleApplications.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: audio.preferences.onlyFavorites ? "star" : "music.note")
                        .font(.system(size: 25, weight: .light)).foregroundStyle(MixerTheme.secondary)
                    Text(audio.search.isEmpty ? (audio.preferences.onlyFavorites ? "Your favorites go here" : "Waiting for a little sound") : "No matching applications")
                        .font(.system(size: 13, weight: .medium))
                    Text(audio.preferences.onlyFavorites ? "Star an app, or add one below." : "Play audio in an app and it will appear here.")
                        .font(.system(size: 11)).foregroundStyle(MixerTheme.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 34)
            } else {
                ForEach(audio.visibleApplications) { app in
                    ApplicationRow(audio: audio, app: app, expanded: Binding(get: { expanded.contains(app.id) }, set: { value in
                        if value { expanded.insert(app.id) } else { expanded.remove(app.id) }
                    }))
                    if app.id != audio.visibleApplications.last?.id {
                        Rectangle().fill(MixerTheme.line).frame(height: 1).padding(.leading, 53)
                    }
                }
            }
        }
        .background(MixerTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(MixerTheme.line))
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
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
            } label: { Label("Add favorite", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            Spacer()
            Circle().fill(audio.enabled ? MixerTheme.accent : MixerTheme.secondary).frame(width: 5, height: 5)
            Text(audio.enabled ? (audio.controlledApps.isEmpty ? "Ready to mix" : "Mixing \(audio.controlledApps.count) app\(audio.controlledApps.count == 1 ? "" : "s")") : "System controls ready")
                .font(.system(size: 10)).foregroundStyle(MixerTheme.secondary)
            Rectangle().fill(MixerTheme.line).frame(width: 1, height: 12).padding(.horizontal, 4)
            Text("Free. Always.").font(.system(size: 10, weight: .medium)).foregroundStyle(MixerTheme.secondary)
        }
        .padding(.horizontal, 25).padding(.vertical, 15)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill(MixerTheme.line).frame(height: 1) }
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("App controls", isOn: Binding(get: { audio.enabled }, set: audio.setControlsEnabled))
            Toggle("Launch at login", isOn: Binding(get: { audio.launchAtLogin }, set: audio.setLaunchAtLogin))
            Divider()
            Button("Reset app mix") { audio.resetMix() }
            Button("Refresh devices and apps") { audio.refresh() }
            Divider()
            Button("Sound settings…") { openSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
            Button("Audio capture permission…") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
            Divider()
            Button("Quit FreeSound") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: { Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 24, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(MixerTheme.secondary)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("FreeSound", systemImage: "waveform").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(MixerTheme.accent)
            Text("Your Mac’s audio, in one place.").font(.system(size: 13, weight: .semibold))
            Text("Free and open source. Built with native macOS audio APIs. No account, subscription, or audio driver to install.")
            Text("Per-app controls need Screen & System Audio Recording permission. Audio is processed on your Mac and is never recorded or uploaded.")
            Text("Version 0.1.0 • macOS 14.2+").font(.system(size: 10)).foregroundStyle(MixerTheme.secondary)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}

struct SystemChannelRow: View {
    @ObservedObject var audio: AudioController
    let channel: SystemChannel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: channel.symbol).font(.system(size: 18)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 28)
            Text(channel.title).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            if channel.id == "effects" {
                Text("Uses device volume").font(.system(size: 10)).foregroundStyle(MixerTheme.secondary)
                    .frame(width: 190, alignment: .leading)
            } else {
                VolumeControl(value: Binding(get: { Double(channel.volume ?? 0) }, set: { audio.setSystemVolume(Float($0), channel: channel) }),
                              muted: channel.muted == true || channel.volume == 0,
                              available: channel.volume != nil,
                              canMute: channel.muted != nil || channel.volume != nil,
                              label: channel.title, toggleMute: { audio.toggleSystemMute(channel) })
                    .frame(width: 190)
            }
            Menu {
                ForEach(channel.input ? audio.inputDevices : audio.outputDevices) { device in
                    Button { audio.setDevice(device.id, channel: channel) } label: {
                        Label(device.name, systemImage: device.id == channel.deviceID ? "checkmark" : device.symbolName)
                    }
                }
            } label: {
                DeviceLabel(name: audio.devices.first { $0.id == channel.deviceID }?.name ?? "No device",
                            symbol: audio.devices.first { $0.id == channel.deviceID }?.symbolName ?? "speaker.slash")
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 206)
        }.padding(.horizontal, 16).padding(.vertical, 15)
    }
}

struct ApplicationRow: View {
    @ObservedObject var audio: AudioController
    let app: AudioApplication
    @Binding var expanded: Bool
    private var settings: AppAudioSettings { audio.settings(for: app.id) }
    private var active: Bool { audio.enabled && !app.processIDs.isEmpty }
    private var color: Color { settings.muted ? MixerTheme.muted : MixerTheme.accent }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { audio.update(app.id) { $0.favorite.toggle() } } label: {
                    Image(systemName: settings.favorite ? "star.fill" : "star").font(.system(size: 11))
                        .foregroundStyle(settings.favorite ? MixerTheme.accent : .white.opacity(0.18))
                }.buttonStyle(.plain).accessibilityLabel(settings.favorite ? "Remove \(app.name) from favorites" : "Favorite \(app.name)")
                    .help(settings.favorite ? "Remove favorite" : "Favorite \(app.name)")
                ZStack(alignment: .bottomTrailing) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30) }
                    else { Image(systemName: "app.fill").font(.system(size: 27)).frame(width: 30, height: 30) }
                    Circle().fill(app.isPlaying ? MixerTheme.accent : .gray).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(MixerTheme.surface, lineWidth: 2)).offset(x: 2, y: 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(audio.appErrors[app.id] != nil ? "Needs attention" : settings.muted && active ? "Muted" : app.isPlaying ? "Playing" : "Idle")
                        .font(.system(size: 9)).foregroundStyle(audio.appErrors[app.id] != nil ? .orange : MixerTheme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VolumeControl(value: Binding(get: { Double(settings.volume) }, set: { value in audio.update(app.id) { $0.volume = Float(value) } }),
                              muted: settings.muted, available: active, canMute: active, maximum: settings.boost ? 2 : 1,
                              showValueWhenDisabled: true, label: app.name, toggleMute: { audio.update(app.id) { $0.muted.toggle() } })
                    .frame(width: 190)
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
                    DeviceLabel(name: routeName, symbol: settings.outputUID == nil ? "arrow.turn.up.right" : "headphones")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 176).disabled(!active)
                Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 17, height: 25)
                }.buttonStyle(.plain).foregroundStyle(MixerTheme.secondary).accessibilityLabel("\(app.name) audio options").help("\(app.name) audio options")
            }.padding(.horizontal, 15).padding(.vertical, 13)
            if let message = audio.appErrors[app.id] {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry") { audio.retry(app.id) }.controlSize(.small)
                    Button("Permission…") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }.controlSize(.small)
                }.padding(.horizontal, 18).padding(.bottom, 13)
            }
            if expanded { details }
        }
    }

    private var routeName: String {
        guard let uid = settings.outputUID else { return "System output" }
        return audio.outputDevices.first { $0.uid == uid }?.name ?? "Unavailable · using system"
    }

    private var details: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Text("Balance").font(.system(size: 11)).foregroundStyle(MixerTheme.secondary)
                Text("L").font(.system(size: 10)).foregroundStyle(MixerTheme.secondary)
                Slider(value: Binding(get: { Double(settings.balance) }, set: { value in audio.update(app.id) { $0.balance = Float(value) } }), in: -1...1)
                    .controlSize(.mini).frame(width: 125).disabled(!active).accessibilityLabel("\(app.name) balance")
                Text("R").font(.system(size: 10)).foregroundStyle(MixerTheme.secondary)
                Button("Center") { audio.update(app.id) { $0.balance = 0 } }.controlSize(.mini).disabled(!active)
                Spacer()
                Toggle("Boost up to 200%", isOn: Binding(get: { settings.boost }, set: { value in audio.update(app.id) { $0.boost = value } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).disabled(!active)
            }
            HStack(spacing: 9) {
                if audio.controlledApps.contains(app.id) {
                    LevelMeter(level: audio.levels[app.id] ?? 0, color: color).frame(width: 95, height: 4)
                    Text("Output level").font(.system(size: 9)).foregroundStyle(MixerTheme.secondary)
                } else {
                    Text("Original audio passes through until you adjust a control.").font(.system(size: 10)).foregroundStyle(MixerTheme.secondary)
                }
                Spacer()
                Button("Reset app") {
                    audio.update(app.id) { let favorite = $0.favorite; $0 = AppAudioSettings(favorite: favorite) }
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(MixerTheme.accent)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14).background(Color.black.opacity(0.13))
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
                    .font(.system(size: 12)).foregroundStyle(muted ? MixerTheme.muted : .white.opacity(0.65)).frame(width: 18)
            }.buttonStyle(.plain).disabled(!canMute).accessibilityLabel("\(muted ? "Unmute" : "Mute") \(label)").help("\(muted ? "Unmute" : "Mute") \(label)")
            Slider(value: $value, in: 0...maximum)
                .controlSize(.mini).tint(muted ? MixerTheme.muted : MixerTheme.accent)
                .disabled(!available).accessibilityLabel("\(label) volume")
                .accessibilityValue(available || showValueWhenDisabled ? "\(Int(value * 100)) percent" : "Device has fixed volume")
            Text(available || showValueWhenDisabled ? "\(Int((value * 100).rounded()))%" : "Fixed")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(available ? .white.opacity(0.78) : MixerTheme.secondary).frame(width: 35, alignment: .trailing)
        }.help(available ? "Adjust \(label.lowercased()) volume" : showValueWhenDisabled ? "Enable app controls and play audio to adjust this app" : "Volume is controlled by this device")
    }
}

struct DeviceLabel: View {
    let name: String
    let symbol: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(MixerTheme.secondary).frame(width: 15)
            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(MixerTheme.secondary)
        }.padding(.horizontal, 10).frame(height: 29)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct LevelMeter: View {
    let level: Float
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }.accessibilityLabel("Audio output level").accessibilityValue("\(Int(level * 100)) percent")
    }
}

struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14)).frame(width: 29, height: 29)
            .foregroundStyle(MixerTheme.secondary)
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

private func openSettings(_ url: String) {
    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
}
