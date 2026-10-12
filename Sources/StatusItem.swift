import AppKit
import Combine
import SwiftUI

/// The paw in the menu bar: the way back to a hidden window.
///
/// Click it to show or hide Meerkat; right-click for a short menu. It turns
/// the colour of the most urgent session while one needs you or has failed,
/// so a hidden Meerkat can still tell you something is waiting. A session
/// whose row you dismissed does not count, as in the window's own header.
final class StatusItemController: NSObject {

    private let item: NSStatusItem
    private let store: SessionStore

    /// A template image, so it follows light and dark menu bars like every
    /// other icon up there.
    private let paw = NSImage(
        systemSymbolName: "pawprint.fill", accessibilityDescription: "Meerkat")
    private let panel: PanelController
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore, panel: PanelController) {
        self.store = store
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            button.image = paw
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Delivered on the next pass of the main queue, by which time the
        // store's derived values have caught up with the new list. The
        // dismissed count too: the headline depends on it, and it can change
        // while the list of shown rows does not.
        store.$sessions.map { _ in () }
            .merge(with: store.$dismissedCount.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let button = item.button else { return }
        let mood = store.headlineMood
        switch mood {
        case .attention, .failed:
            // A coloured copy rather than contentTintColor, which status bar
            // buttons ignore.
            button.image = paw?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [NSColor(mood.color)]))
        case .idle, .working, .done:
            button.image = paw
        }
        button.toolTip = "Meerkat: \(store.headline)\n"
            + "Click to show or hide (\(ToggleShortcut.display)), right-click for more."
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    /// Attached only while it is open, so a plain click stays a toggle instead
    /// of opening the menu.
    private func showMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: panel.isShown ? "Hide Meerkat" : "Show Meerkat",
            action: #selector(togglePanel), keyEquivalent: ToggleShortcut.keyEquivalent)
        toggle.keyEquivalentModifierMask = ToggleShortcut.modifierFlags
        toggle.target = self
        menu.addItem(toggle)

        // The same key the window's own menu toggles.
        let muted = UserDefaults.standard.bool(forKey: "muted")
        let mute = NSMenuItem(
            title: muted ? "Unmute sounds" : "Mute sounds",
            action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        menu.addItem(mute)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Meerkat",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func togglePanel() {
        panel.toggle()
    }

    @objc private func toggleMute() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "muted"), forKey: "muted")
    }
}
