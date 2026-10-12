import AppKit
import Combine
import SwiftUI

/// Owns the floating window: a borderless, non-activating panel that sits above
/// your other windows on every Space, remembers where you put it, and resizes
/// itself as sessions come and go.
final class PanelController {

    private let panel: NSPanel
    private let store: SessionStore
    private let hosting: NSHostingView<ContentView>
    private var cancellables: Set<AnyCancellable> = []

    private static let originKey = "panelOrigin"
    private static let topLeftKey = "panelTopLeft"
    private static let collapsedKey = "collapsed"

    init(store: SessionStore) {
        self.store = store

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: MeerkatLayout.width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.panel = panel

        // SwiftUI cannot reach its own NSWindow, so hand the collapsed view a
        // closure that nudges this panel. A drag translation grows downward
        // while a window origin grows upward, hence the subtraction.
        //
        // The menu's Hide gets one too, ordering the panel out directly as
        // hide() does, since self cannot be captured before init finishes. The
        // same goes for asking whether it is on screen.
        hosting = NSHostingView(
            rootView: ContentView(
                store: store,
                moveBy: { [weak panel] delta in
                    guard let panel = panel else { return }
                    let frame = panel.frame
                    panel.setFrameOrigin(
                        NSPoint(
                            x: frame.minX + delta.width,
                            y: frame.minY - delta.height))
                },
                hide: { [weak panel] in panel?.orderOut(nil) },
                isShown: { [weak panel] in panel?.isVisible ?? false }))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.intrinsicContentSize]
        }

        configurePanel()
        observe()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        // Only Meerkat's own Hide puts it away. App-level hiding -- Hide Others
        // in another app, or a login item launched hidden -- would otherwise
        // take the window with it, and an app with no Dock icon offers no way
        // to unhide it.
        panel.canHide = false

        // Meerkat is never the active app -- it is an accessory with a
        // non-activating panel -- and AppKit hides tooltips for inactive apps
        // by default, which would silence every hover detail.
        panel.allowsToolTipsWhenApplicationIsInactive = true

        // Visible on whichever Space you are on, and not dragged along into a
        // full-screen app's own Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // The frosted material lives in SwiftUI, so the window itself is glass.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // Drag it by any part that is not a control. resizeToFit() turns this
        // off while collapsed, where the view moves the window itself.
        panel.isMovableByWindowBackground = true

        panel.contentView = hosting
    }

    private func observe() {
        // Resize whenever the session list changes.
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeToFit() }
            .store(in: &cancellables)

        // ...and when the usage block appears, vanishes or gains a row, which
        // can happen with no session changing at all.
        store.$usage
            .map { $0?.windows.count ?? -1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeToFit() }
            .store(in: &cancellables)

        // Collapsing is a SwiftUI @AppStorage toggle, which lands in
        // UserDefaults; that is our signal to resize.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(40), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeToFit() }
            .store(in: &cancellables)

        // Remember where you leave it.
        NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveOrigin() }
            .store(in: &cancellables)
    }

    /// Whether the window is on screen, rather than put away by Hide.
    var isShown: Bool { panel.isVisible }

    /// Set once the saved position has been applied. Hiding does not move the
    /// window, so showing it again leaves it where it was.
    private var placed = false

    func show() {
        resizeToFit()
        if placed {
            // A display may have gone away while it was hidden.
            clampOnScreen()
        } else {
            restoreOrigin()
            placed = true
        }
        panel.orderFrontRegardless()
    }

    /// Puts the window away. Everything else carries on: sessions are still
    /// watched, sounds still play, and the menu bar icon still shows when one
    /// needs you.
    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    // MARK: - Geometry

    private var isCollapsed: Bool {
        UserDefaults.standard.bool(forKey: Self.collapsedKey)
    }

    /// Set while a shrink waits out a double-click; see resizeToFit.
    private var shrinkHeld = false

    /// Ask SwiftUI how tall it wants to be, and fall back to an estimate from
    /// the row counts if it has not laid out yet.
    private func resizeToFit(afterHold: Bool = false) {
        let collapsed = isCollapsed

        // Keep the two ways of moving the window mutually exclusive. Collapsed,
        // the critter's tap gesture covers the whole panel and may swallow the
        // mouse-down that background dragging needs, so SwiftUI moves the window
        // through `moveBy`. Expanded, AppKit handles it and SwiftUI does not, so
        // a drag can never be applied twice.
        panel.isMovableByWindowBackground = !collapsed

        let target: CGSize
        if collapsed {
            target = MeerkatLayout.collapsedSize
        } else {
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            if fitting.height >= 40, fitting.width >= 40 {
                target = CGSize(width: MeerkatLayout.width, height: ceil(fitting.height))
            } else {
                target = CGSize(width: MeerkatLayout.width, height: estimatedHeight())
            }
        }

        let current = panel.frame
        guard abs(current.width - target.width) > 0.5
            || abs(current.height - target.height) > 0.5
        else { return }

        // Grow downward: the top-left corner is the one you positioned.
        let origin = NSPoint(x: current.minX, y: current.maxY - target.height)
        let frame = NSRect(origin: origin, size: target)

        // Dismissing the bottom row takes the bottom edge out from under the
        // pointer, and the second click of a double-click would land on
        // whatever is behind the window. Hold such a shrink, once, for as long
        // as a double-click takes, so that click lands here instead.
        let pointer = NSEvent.mouseLocation
        if !collapsed, !afterHold, target.height < current.height,
           current.contains(pointer), !frame.contains(pointer) {
            if !shrinkHeld {
                shrinkHeld = true
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) {
                    [weak self] in
                    self?.shrinkHeld = false
                    self?.resizeToFit(afterHold: true)
                }
            }
            return
        }

        panel.setFrame(frame, display: true, animate: false)
        clampOnScreen()
    }

    private func estimatedHeight() -> CGFloat {
        var height = MeerkatLayout.headerHeight
        if let usage = store.usage {
            height += MeerkatLayout.usageHeaderHeight
                + CGFloat(usage.windows.count) * MeerkatLayout.usageRowHeight
        } else {
            height += MeerkatLayout.footerHeight
        }
        if store.sessions.isEmpty {
            height += MeerkatLayout.emptyStateHeight
        } else {
            for session in store.sessions {
                height += session.hasProgress
                    ? MeerkatLayout.rowWithProgressHeight
                    : MeerkatLayout.rowHeight
            }
        }
        return height
    }

    // MARK: - Position

    /// The top-left corner, because that is the corner resizing holds still:
    /// saving the bottom-left made the window land higher or lower on the next
    /// launch whenever the number of rows had changed.
    private func saveOrigin() {
        let frame = panel.frame
        UserDefaults.standard.set(
            ["x": Double(frame.minX), "top": Double(frame.maxY)], forKey: Self.topLeftKey)
    }

    private func restoreOrigin() {
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: Self.topLeftKey),
           let x = saved["x"] as? Double,
           let top = saved["top"] as? Double {
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        } else if let saved = defaults.dictionary(forKey: Self.originKey),
                  let x = saved["x"] as? Double,
                  let y = saved["y"] as? Double {
            // Saved by an older build, as the bottom-left corner.
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            // First launch: top-right, below the menu bar, where a sentry belongs.
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(
                NSPoint(x: visible.maxX - panel.frame.width - 22, y: visible.maxY - 14))
        }
        clampOnScreen()
    }

    /// Keep the window reachable after a display change or an unplugged monitor.
    private func clampOnScreen() {
        let frame = panel.frame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var x = frame.minX
        var y = frame.minY
        x = min(max(x, visible.minX + 4), visible.maxX - frame.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - frame.height - 4)

        if abs(x - frame.minX) > 0.5 || abs(y - frame.minY) > 0.5 {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
