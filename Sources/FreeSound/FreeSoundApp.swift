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
    private var window: NSWindow!
    private var pinObserver: NSObjectProtocol?
    private static let width: CGFloat = 440
    private static let screenInset: CGFloat = 8

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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 720),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "FreeSound"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.backgroundColor = NSColor(MixerTheme.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Self.width, height: 520)
        window.maxSize = NSSize(width: Self.width, height: 1600)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: MixerView(audio: controller).background(MixerTheme.background).ignoresSafeArea(.container, edges: .top))
        updatePin()
        pinObserver = NotificationCenter.default.addObserver(forName: .freeSoundPinChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePin() }
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

    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func toggleMixer() {
        if window.isVisible && window.isKeyWindow { window.orderOut(nil) }
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
        anchorWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Sits just under the menu bar in the top right corner of the screen that holds the menu bar item.
    private func anchorWindow() {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let height = min(window.frame.height, area.height - Self.screenInset * 2)
        let origin = NSPoint(x: area.maxX - Self.width - Self.screenInset, y: area.maxY - height - Self.screenInset)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
    }

    /// Unpinned, the mixer behaves like a menu bar panel and goes away when something else is used.
    func windowDidResignKey(_ notification: Notification) {
        guard !controller.preferences.pinned, !CommandLine.arguments.contains("--snapshot") else { return }
        window.orderOut(nil)
    }

    private func updatePin() { window.level = controller.preferences.pinned ? .floating : .normal }

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
