import AppKit
import ContextCore
import SwiftUI

/// Keeps the main window on the Mac's built-in display when it is created.
///
/// macOS with "Displays have separate Spaces" opens a launching app's window on the active
/// display (the one with the cursor), so a background restart moves the window to an external
/// monitor. With this preference on (default), the window is moved back to the built-in display,
/// keeping its size and clamping it to the visible area. Lid closed (no built-in display): nothing moves.
enum MainWindowScreen {
    static let preferenceKey = "openMainWindowOnBuiltInDisplay"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) == nil || UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// Where `window` (a screen rectangle) goes on a display whose visible area is `visible`:
    /// same size, shrunk to fit, centered.
    static func placement(window: CGRect, visible: CGRect) -> CGRect {
        let width = min(window.width, visible.width)
        let height = min(window.height, visible.height)
        return CGRect(x: (visible.minX + (visible.width - width) / 2).rounded(),
                      y: (visible.minY + (visible.height - height) / 2).rounded(),
                      width: width, height: height)
    }

    @MainActor static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    @MainActor private static let placed = NSHashTable<NSWindow>.weakObjects()

    /// Moves a newly created window once; later moves by the user are respected.
    @MainActor static func placeIfNeeded(_ window: NSWindow) {
        guard enabled, !placed.contains(window), let builtIn = builtInScreen() else { return }
        placed.add(window)
        guard window.screen !== builtIn else { return }
        let frame = placement(window: window.frame, visible: builtIn.visibleFrame)
        window.setFrame(frame, display: true)
        AppLog.lifecycle.notice("Main window moved to the built-in display")
    }
}

/// Attached to the main window's content; places the window when the content first lands in it.
struct MainWindowPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            // SwiftUI applies the saved frame after the content is attached, and the system may
            // choose the display when the window is first ordered in; place after both.
            DispatchQueue.main.async { MainWindowScreen.placeIfNeeded(window) }
            // Selector observers are removed automatically when the view is deallocated.
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
        }
        @objc private func windowBecameKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { MainWindowScreen.placeIfNeeded(window) }
        }
    }
}

struct MainWindowScreenSettings: View {
    @AppStorage(MainWindowScreen.preferenceKey) private var onBuiltIn = true
    var body: some View {
        Section(L10n.text("Главное окно", "Main window")) {
            Toggle(L10n.text("Открывать на встроенном экране Mac", "Open on the built-in Mac display"), isOn: $onBuiltIn)
            Text(L10n.text("При запуске и перезапуске окно появляется на экране Mac, даже если курсор на другом мониторе. Выключи, чтобы macOS выбирала монитор сама.",
                           "At launch and restart the window appears on the Mac's display, even when the cursor is on another monitor. Turn off to let macOS choose the display."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }
}
