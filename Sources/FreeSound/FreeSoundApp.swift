import AppKit
import CoreAudio
import SwiftUI

@main
struct FreeSoundMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnostics") {
            printDiagnostics()
            return
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func printDiagnostics() {
        do {
            let devices = try SystemAudio.devices()
            let processes = try SystemAudio.processes()
            let payload: [String: Any] = [
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                "devices": devices.map { device -> [String: Any] in
                    var item: [String: Any] = ["id": device.id, "name": device.name, "uid": device.uid,
                                               "output": device.hasOutput, "input": device.hasInput]
                    if device.hasOutput { item["volume"] = SystemAudio.volume(of: device.id) }
                    return item
                },
                "defaultOutput": try SystemAudio.defaultDevice(for: .output),
                "defaultInput": try SystemAudio.defaultDevice(for: .input),
                "defaultSoundEffects": try SystemAudio.defaultDevice(for: .soundEffects),
                "audioProcesses": processes.map { ["id": $0.id, "pid": $0.pid, "bundleID": $0.bundleID, "playing": $0.isRunningOutput] as [String: Any] },
            ]
            let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        } catch {
            fputs("FreeSound: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controller: AudioController!
    private var statusItem: NSStatusItem!
    private var window: MixerPanel!
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AudioController()
        configureMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "FreeSoundMixer"
        statusItem.isVisible = true
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "FreeSound")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.setAccessibilityLabel("FreeSound audio mixer")
            button.toolTip = "FreeSound — audio mixer"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        window = MixerPanel()
        window.backgroundColor = NSColor(MixerTheme.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.contentView = NSHostingView(rootView: MixerView(audio: controller).background(MixerTheme.background).ignoresSafeArea(.container, edges: .top))
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissUnpinnedMixer() }
        }
        showMixer()
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.saveSnapshot(to: path)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMixer()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        controller?.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func toggleMixer() {
        if window.isVisible && window.screen == MixerPanel.screen() { window.orderOut(nil) }
        else { showMixer() }
    }

    @objc private func statusItemClicked() {
        let event = NSApplication.shared.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let show = menu.addItem(withTitle: "Show FreeSound", action: #selector(showMixer), keyEquivalent: "")
            show.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit FreeSound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            // Attach only while tracking so a normal click still toggles the mixer.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleMixer()
        }
    }

    @objc private func showMixer() {
        guard let screen = MixerPanel.screen() else { return }
        window.show(on: screen)
    }

    /// Unpinned, the mixer behaves like a menu bar panel and goes away when something else is used.
    func windowDidResignKey(_ notification: Notification) {
        dismissUnpinnedMixer()
    }

    private func dismissUnpinnedMixer() {
        guard !controller.preferences.pinned, !CommandLine.arguments.contains("--snapshot") else { return }
        window.orderOut(nil)
    }

    private func configureMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let app = NSMenu()
        let show = app.addItem(withTitle: "Show FreeSound", action: #selector(showMixer), keyEquivalent: "m")
        show.keyEquivalentModifierMask = [.command, .shift]
        show.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit FreeSound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }

    private func saveSnapshot(to path: String) {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: path)); print("Saved \(path)") }
        catch { fputs("Snapshot failed: \(error)\n", stderr) }
    }
}
