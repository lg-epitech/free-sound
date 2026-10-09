import AppKit

/// A menu-bar overlay that accepts keyboard input without activating FreeSound.
@MainActor
final class MixerPanel: NSPanel {
    static let width: CGFloat = 440
    static let height: CGFloat = 720
    static let screenInset: CGFloat = 8

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "FreeSound"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The status item's backing window can still belong to the previously used display.
    static func screen(at point: NSPoint = NSEvent.mouseLocation) -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
    }

    static func anchoredFrame(in visibleFrame: NSRect) -> NSRect {
        let height = max(1, min(Self.height, visibleFrame.height - screenInset * 2))
        return NSRect(x: visibleFrame.maxX - width - screenInset,
                      y: visibleFrame.maxY - height - screenInset,
                      width: width, height: height)
    }

    func show(on screen: NSScreen) {
        setFrame(Self.anchoredFrame(in: screen.visibleFrame), display: true)
        // Taking key focus here can restore a previously focused window on another workspace.
        // Controls can make this nonactivating panel key when the user interacts with it.
        orderFrontRegardless()
    }
}
