import AppKit
import Combine
import SwiftUI

extension Mood {
    /// One palette, shared by the critter and the session dots, so a colour
    /// always means the same thing.
    var color: Color {
        switch self {
        case .idle: return Color(red: 0.58, green: 0.60, blue: 0.64)
        case .working: return Color(red: 0.95, green: 0.70, blue: 0.25)
        case .attention: return Color(red: 0.95, green: 0.45, blue: 0.20)
        case .done: return Color(red: 0.35, green: 0.76, blue: 0.48)
        case .failed: return Color(red: 0.88, green: 0.36, blue: 0.36)
        }
    }
}

/// System sounds, held for the life of the process. An NSSound created and
/// dropped at the call site can be released part-way through playing.
private enum Chime {
    static let finished = NSSound(named: NSSound.Name("Glass"))
    static let needsYou = NSSound(named: NSSound.Name("Tink"))

    static func play(_ sound: NSSound?) {
        guard let sound = sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

/// claude.ai's own usage page: where the footer link goes when Meerkat has no
/// figures of its own to show, and the source to check them against.
let usageSettingsURL = URL(string: "https://claude.ai/settings/usage")!

struct ContentView: View {

    @ObservedObject var store: SessionStore

    /// Nudges the window by a delta. Supplied by the panel controller, because
    /// SwiftUI has no handle on its own NSWindow.
    var moveBy: (CGSize) -> Void = { _ in }

    @AppStorage("muted") private var muted = false
    @AppStorage("collapsed") private var collapsed = false
    @AppStorage(UsageFetcher.disabledKey) private var usageFetchDisabled = false

    @State private var phase: Double = 0
    @State private var now = Date()

    /// Where the mouse was, in screen coordinates, at the last step of a drag
    /// of the collapsed critter.
    @State private var lastDragMouse: NSPoint?

    /// 12 fps is plenty for a sway and a blink, and costs nothing measurable.
    private let ticker = Timer.publish(every: 1.0 / 12.0, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Group {
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
        .onReceive(ticker) { _ in
            phase += 1.0 / 12.0
            now = Date()
        }
        .onChange(of: store.celebratedAt) { _ in chime(Chime.finished) }
        .onChange(of: store.alertedAt) { _ in chime(Chime.needsYou) }
        .contextMenu { menu }
    }

    // MARK: - Collapsed

    private var collapsedBody: some View {
        MeerkatCritter(mood: store.headlineMood, phase: phase, bounce: bounce)
            .frame(width: 62, height: 78)
            .padding(8)
            .onTapGesture { collapsed = false }
            // A 3pt threshold keeps a click to expand from registering as a drag.
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        // Screen coordinates, not the gesture's translation:
                        // the gesture measures in the view's own space, which
                        // moves with the window being dragged, so the window
                        // trailed the cursor at about half speed. Screen y
                        // grows upward and moveBy takes a drag-style delta
                        // that grows downward, hence last - mouse.
                        let mouse = NSEvent.mouseLocation
                        if let last = lastDragMouse {
                            moveBy(CGSize(width: mouse.x - last.x, height: last.y - mouse.y))
                        }
                        lastDragMouse = mouse
                    }
                    .onEnded { _ in lastDragMouse = nil }
            )
            .help("\(store.headline) — click to expand, drag to move")
    }

    // MARK: - Expanded

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            usageBlock
            if store.sessions.isEmpty {
                emptyState
            } else {
                ForEach(store.sessions) { session in
                    Divider().opacity(0.4)
                    SessionRow(session: session, now: now, phase: phase)
                }
            }
        }
        .frame(width: MeerkatLayout.width, alignment: .leading)
    }

    /// Plan usage: one bar per window claude.ai shows -- the current session,
    /// the week, and each model with a weekly limit of its own. With no figures
    /// yet, a single line that says why, and opens claude.ai's own page.
    @ViewBuilder
    private var usageBlock: some View {
        if let snapshot = store.usage {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("PLAN USAGE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.2)
                    Spacer(minLength: 0)
                    Text(freshness(snapshot.captured))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(stale(snapshot.captured) ? Color.orange : .secondary)
                }
                .foregroundStyle(.secondary)

                ForEach(snapshot.windows) { window in
                    UsageRow(window: window, now: now)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .help(usageHelp(snapshot))
        } else {
            Button {
                NSWorkspace.shared.open(usageSettingsURL)
            } label: {
                HStack(spacing: 5) {
                    Text("Plan usage")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                    Spacer(minLength: 0)
                    Text(store.usageStatus.summary)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help(store.usageStatus.explanation + "\n\nClick to open Settings -> Usage on claude.ai.")
        }
    }

    private func usageHelp(_ snapshot: UsageSnapshot) -> String {
        var lines: [String] = []
        switch snapshot.source {
        case .api:
            lines.append("From claude.ai: the same figures as Settings -> Usage.")
        case .statusLine:
            lines.append("From a terminal session's status line.")
        }
        lines.append("Checked \(freshness(snapshot.captured)).")
        if store.usageStatus != .ok && store.usageStatus != .starting {
            lines.append("Last check: \(store.usageStatus.explanation)")
        }
        lines.append("Right-click -> Refresh plan usage to check now.")
        return lines.joined(separator: "\n")
    }

    /// How long ago the figures were captured, phrased for a glance.
    private func freshness(_ captured: Date) -> String {
        let age = now.timeIntervalSince(captured)
        if age < 90 { return "just now" }
        return shortElapsed(since: captured, now: now) + " ago"
    }

    /// Past this, the numbers have probably moved and the label turns amber.
    private func stale(_ captured: Date) -> Bool {
        now.timeIntervalSince(captured) > 600
    }

    private var header: some View {
        HStack(spacing: 8) {
            MeerkatCritter(mood: store.headlineMood, phase: phase, bounce: bounce)
                .frame(width: 44, height: 56)
                .onTapGesture { collapsed = true }
                .help("Click to shrink to just the meerkat")

            VStack(alignment: .leading, spacing: 1) {
                Text("MEERKAT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Text(store.headline)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 9)
    }

    private var emptyState: some View {
        Text("On watch. Nothing running.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    // MARK: - Behaviour

    /// A short damped hop after a session finishes.
    private var bounce: Double {
        guard let at = store.celebratedAt else { return 0 }
        let t = now.timeIntervalSince(at)
        guard t >= 0, t < 1.1 else { return 0 }
        // One arc up and down, fading out. sin(pi*u) * (1-u) peaks at about
        // 0.579 rather than 1, so normalise by that to actually reach full
        // height at the top of the hop.
        let u = t / 1.1
        return min(1, sin(u * Double.pi) * (1 - u) / 0.579)
    }

    private func chime(_ sound: NSSound?) {
        guard !muted else { return }
        Chime.play(sound)
    }

    @ViewBuilder
    private var menu: some View {
        Button(collapsed ? "Expand" : "Collapse") { collapsed.toggle() }
        Button(muted ? "Unmute sounds" : "Mute sounds") { muted.toggle() }
        Divider()
        if !usageFetchDisabled {
            Button("Refresh plan usage") { store.refreshUsage() }
        }
        Button(usageFetchDisabled ? "Turn on plan usage" : "Turn off plan usage") {
            store.setPlanUsage(enabled: usageFetchDisabled)
        }
        Button("Open plan usage on claude.ai") { NSWorkspace.shared.open(usageSettingsURL) }
        Button("Reveal state folder") {
            NSWorkspace.shared.open(store.stateDirectory)
        }
        Divider()
        Button("Quit Meerkat") { NSApp.terminate(nil) }
    }
}

/// One session: a status dot, its name, what it is doing, and progress if it
/// has published any tasks.
struct SessionRow: View {
    let session: Session
    let now: Date
    let phase: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                dot
                Text(session.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(session.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 15)

            if session.hasProgress {
                progressBar.padding(.leading, 15).padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: MeerkatLayout.width, alignment: .leading)
        .help(tooltip)
    }

    /// The dot breathes while a session is working, so a busy row is obvious
    /// even in peripheral vision. A finished session gets a tick instead, so
    /// done reads as done without decoding a colour.
    @ViewBuilder
    private var dot: some View {
        if session.mood == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(session.mood.color)
                .frame(width: 8, height: 8)
        } else {
            let pulse: Double =
                (session.mood == .working || session.mood == .attention)
                ? 0.55 + 0.45 * abs(sin(phase * 2.2))
                : 1.0
            // `opacity` takes a Double, so no CGFloat creeps in here.
            Circle()
                .fill(session.mood.color.opacity(pulse))
                .frame(width: 8, height: 8)
        }
    }

    /// Progress while working; otherwise the state in words, so whether a
    /// session is finished never rests on the dot alone. Both with how long.
    private var trailing: String {
        let elapsed = shortElapsed(since: session.since, now: now)
        switch session.mood {
        case .working:
            return session.hasProgress
                ? "\(session.tasksDone)/\(session.tasksTotal) · \(elapsed)"
                : elapsed
        case .attention, .done, .failed:
            return "\(session.mood.word) · \(elapsed)"
        case .idle:
            return elapsed
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(session.mood.color.opacity(0.85))
                    .frame(width: max(2, geo.size.width * CGFloat(session.progress)))
            }
        }
        .frame(height: 3)
        .padding(.trailing, 2)
    }

    private var tooltip: String {
        var lines = [session.label]
        if !session.cwd.isEmpty { lines.append(session.cwd) }
        lines.append("\(session.mood.word) for \(shortElapsed(since: session.since, now: now))")
        if session.hasProgress {
            lines.append("tasks: \(session.tasksDone) of \(session.tasksTotal)")
        }
        if session.turns > 0 { lines.append("turns: \(session.turns)") }
        if !session.detail.isEmpty { lines.append(session.detail) }
        return lines.joined(separator: "\n")
    }
}

/// One plan-usage window: a label, a bar, the percentage, and when it resets.
struct UsageRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    if !hasReset {
                        Capsule()
                            .fill(color)
                            .frame(width: max(2, geo.size.width * CGFloat(fraction)))
                    }
                }
            }
            .frame(height: 4)

            Text(hasReset ? "—" : "\(Int(window.percent.rounded()))%")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(!hasReset && window.percent >= 90 ? color : .secondary)
                .frame(width: 34, alignment: .trailing)

            Text(resetText)
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .help(tooltip)
    }

    /// The figure was read before this window's reset, so it is no longer the
    /// current one -- a pre-reset 97% would be wrong in red. Show a dash until
    /// a fresh look replaces it.
    private var hasReset: Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }

    /// When the window resets, the way claude.ai puts it: a time if that is
    /// later today, a weekday and time if not.
    private var resetText: String {
        if hasReset { return "reset" }
        guard let resets = window.resetsAt else { return "" }
        let sameDay = Calendar.current.isDate(resets, inSameDayAs: now)
        return (sameDay ? UsageRow.timeOnly : UsageRow.dayAndTime).string(from: resets)
    }

    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()

    private var fraction: Double {
        min(1, max(0, window.percent / 100))
    }

    /// Green while there is room, amber when it is worth noticing, red when
    /// the window is nearly gone.
    private var color: Color {
        if window.percent >= 90 { return Mood.failed.color }
        if window.percent >= 70 { return Mood.working.color }
        return Mood.done.color
    }

    private var tooltip: String {
        guard let resets = window.resetsAt else {
            return "\(window.title): \(String(format: "%.1f", window.percent))% used"
        }
        if hasReset {
            return "\(window.title): reset \(UsageRow.dayAndTime.string(from: resets)); "
                + "waiting for a fresh figure"
        }
        return "\(window.title): \(String(format: "%.1f", window.percent))% used\n"
            + "resets \(UsageRow.dayAndTime.string(from: resets)), "
            + "in \(shortElapsed(since: now, now: resets))"
    }
}

/// Sizes the window controller needs to know about too.
enum MeerkatLayout {
    static let width: CGFloat = 288
    static let collapsedSize = CGSize(width: 78, height: 94)
    static let headerHeight: CGFloat = 74
    static let footerHeight: CGFloat = 35
    static let usageRowHeight: CGFloat = 17
    static let usageHeaderHeight: CGFloat = 33
    static let rowHeight: CGFloat = 48
    static let rowWithProgressHeight: CGFloat = 56
    static let emptyStateHeight: CGFloat = 38
}
