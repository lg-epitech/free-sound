import AppKit

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

MainActor.assumeIsolated {
    let desktop = NSRect(x: 0, y: 50, width: 1440, height: 826)
    let frame = MixerPanel.anchoredFrame(in: desktop)
    expect(frame.maxX == 1432 && frame.maxY == 868, "Panel stays eight points inside the top-right visible corner")
    expect(frame.size == NSSize(width: 440, height: 720), "Panel has its intended size on a normal display")

    let leftDisplay = NSRect(x: -1920, y: -200, width: 1920, height: 1056)
    let leftFrame = MixerPanel.anchoredFrame(in: leftDisplay)
    expect(leftDisplay.contains(leftFrame), "Displays left of and below the primary display use global coordinates")
    expect(leftFrame.maxX == -8 && leftFrame.maxY == 848, "A different display gets its own top-right anchor")

    let compactDisplay = NSRect(x: 1440, y: 0, width: 1024, height: 600)
    let compactFrame = MixerPanel.anchoredFrame(in: compactDisplay)
    expect(compactDisplay.contains(compactFrame) && compactFrame.height == 584, "Short displays constrain the panel to the visible area")
    expect(MixerPanel.anchoredFrame(in: desktop).height == 720, "Reopening on a larger display restores the intended height")
    print("PASS: mixer panel placement checks")

    // Opt-in: briefly shows a real panel. Keep CI and normal audio checks off the desktop.
    if CommandLine.arguments.contains("--presentation") {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let screen = MixerPanel.screen() else { fatalError("Presentation checks require a display") }
        let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let panel = MixerPanel()
        let field = NSTextField(string: "Keyboard input")
        panel.contentView = field
        for _ in 0..<2 {
            panel.show(on: screen)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            expect(panel.isVisible && !panel.isKeyWindow, "Opening the overlay preserves keyboard focus")
            expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp, "Showing the panel preserves the frontmost app")
            expect(!panel.isMainWindow && !panel.isMovable, "Panel is an immovable overlay, not a main window")
            expect(panel.frame == MixerPanel.anchoredFrame(in: screen.visibleFrame), "Visible panel uses the current display anchor")
            panel.orderOut(nil)
            expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp, "Hiding the panel preserves the frontmost app")
        }
        panel.show(on: screen)
        panel.makeKey()
        expect(panel.isKeyWindow && panel.makeFirstResponder(field), "Interacting with search can give it keyboard focus")
        expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp, "Keyboard interaction does not activate FreeSound")
        panel.orderOut(nil)
        panel.show(on: screen)
        expect(panel.isVisible && !panel.isKeyWindow, "Reopening after keyboard interaction still preserves keyboard focus")
        expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp, "Reopening after keyboard interaction preserves the frontmost app")
        panel.orderOut(nil)
        print("PASS: live panel presentation, focus, keyboard, and reopen checks")
    }
}
