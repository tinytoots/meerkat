import AppKit
import Combine

/// Meerkat: a small sentry on your desktop that watches your Claude Code
/// sessions and stands up the moment one finishes or needs you.
///
/// There is no Dock icon and no main menu by design — it is a widget, not an
/// app you switch to. Right-click the window for the menu, including Quit.
/// Hidden, it lives on as a paw in the menu bar, and ⌃⌘M brings it back.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: SessionStore?
    private var controller: PanelController?
    private var statusItem: StatusItemController?
    private var hotKey: HotKey?
    private var chimes: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore()
        let controller = PanelController(store: store)
        self.store = store
        self.controller = controller

        statusItem = StatusItemController(store: store, panel: controller)
        hotKey = HotKey(
            keyCode: ToggleShortcut.keyCode,
            modifiers: ToggleShortcut.carbonModifiers
        ) { [weak controller] in
            controller?.toggle()
        }
        if hotKey == nil {
            // Not fatal: the menu bar icon and reopening the app do the same job.
            NSLog("Meerkat: could not register %@", ToggleShortcut.display)
        }
        chimes = Chime.follow(store)

        store.start()
        controller.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    /// Opening Meerkat again while it runs -- from Spotlight, Finder or
    /// `open` -- brings back a hidden window.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        controller?.show()
        return false
    }

    /// Hiding the window is not closing the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// .accessory keeps us out of the Dock and the app switcher.
application.setActivationPolicy(.accessory)
application.run()
