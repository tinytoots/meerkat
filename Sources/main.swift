import AppKit

/// Meerkat: a small sentry on your desktop that watches your Claude Code
/// sessions and stands up the moment one finishes or needs you.
///
/// There is no Dock icon and no main menu by design — it is a widget, not an
/// app you switch to. Right-click the window for the menu, including Quit.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: SessionStore?
    private var controller: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore()
        let controller = PanelController(store: store)
        self.store = store
        self.controller = controller

        store.start()
        controller.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    /// Nothing to re-open; the panel is always there.
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
