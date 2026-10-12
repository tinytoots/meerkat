import Combine
import Darwin
import Foundation

/// Reads the session files the hook writes and keeps them live.
///
/// Two mechanisms, deliberately: a kernel watch on the directory so a finished
/// turn shows up the instant the hook writes it, and a slow timer as a backstop
/// for the cases a vnode watch misses (the directory being recreated, a file
/// replaced by rename on some filesystems) and to tick the elapsed clocks.
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [Session] = []

    /// Set when a session has just finished, so the view can bounce and chime.
    @Published private(set) var celebratedAt: Date?

    /// Set when a session has just started needing you.
    @Published private(set) var alertedAt: Date?

    /// The plan-usage figures to show: the usage endpoint's while they are
    /// reasonably fresh, otherwise whatever the status line harvester last
    /// wrote, otherwise nil.
    @Published private(set) var usage: UsageSnapshot?

    /// How the last look at the usage endpoint went.
    @Published private(set) var usageStatus: UsageStatus = .starting

    private var fetchedUsage: UsageSnapshot?
    private var harvestedUsage: UsageSnapshot?
    private let usageFetcher: UsageFetcher

    /// The endpoint is the fuller source -- it alone has the per-model weeks --
    /// so it wins for this long even when a terminal status line has written
    /// something a little newer. Past this, the newer of the two wins.
    private let fetchedUsageTrustedFor: TimeInterval = 30 * 60

    private let directory: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var reloadWorkItem: DispatchWorkItem?

    /// Last known mood per session, for spotting the transitions worth a sound.
    private var previousMoods: [String: Mood] = [:]

    /// A finished session stays on screen this long, so a result does not
    /// vanish before you have looked at it.
    private let doneLingers: TimeInterval = 15 * 60

    /// An idle session is not news; drop it from the list after a while.
    private let idleLingers: TimeInterval = 30 * 60

    /// Any file this stale is debris from a session that died without telling us.
    private let debrisAfter: TimeInterval = 12 * 60 * 60

    init(directory: URL? = nil) {
        if let directory = directory {
            self.directory = directory
        } else {
            let base = ProcessInfo.processInfo.environment["MEERKAT_HOME"]
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".meerkat")
            self.directory = URL(fileURLWithPath: base).appendingPathComponent("sessions")
        }
        usageFetcher = UsageFetcher(stateDirectory: self.directory.deletingLastPathComponent())
    }

    func start() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        usageFetcher.onUpdate = { [weak self] snapshot, status in
            self?.applyFetchedUsage(snapshot, status)
        }
        usageFetcher.start()
        reload()
        startWatching()
        // .common rather than the default mode: a plain scheduledTimer stops
        // firing while you drag the window or hold a menu open, which is exactly
        // when the elapsed clocks are being read.
        let backstop = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(backstop, forMode: .common)
        timer = backstop
    }

    deinit {
        stop()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopWatching()
        usageFetcher.stop()
    }

    var stateDirectory: URL { directory }

    /// Look at the usage endpoint now, for the menu's refresh.
    func refreshUsage() {
        usageFetcher.refreshNow()
    }

    /// The menu's switch for plan usage. Off hides the bars from both sources
    /// at once and stops every keychain read and request.
    func setPlanUsage(enabled: Bool) {
        usageFetcher.setDisabled(!enabled)
        publishUsage()
    }

    // MARK: - Watching

    private func startWatching() {
        stopWatching()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // Watching the directory only reports entries appearing, vanishing or
        // being renamed -- NOT an existing file being rewritten in place. The
        // instant-update path therefore depends on the hook writing a temp file
        // and renaming it over the old one, which is what meerkat-hook.py does.
        // If that ever changes to an in-place write, updates silently fall back
        // to the 3-second backstop.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main)
        // `source` is captured strongly on purpose, so the flags always belong
        // to the source that fired. That is a reference cycle, which
        // stopWatching() breaks deliberately by clearing the handler before it
        // cancels. Reading self.watcher instead would be a bug: during a re-arm a
        // queued handler would read the NEW source and see flags of 0, misreading
        // a real delete as an ordinary write.
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Our directory was moved or removed. Re-establish the watch on
                // whatever is at that path now.
                self.scheduleReload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    try? FileManager.default.createDirectory(
                        at: self.directory, withIntermediateDirectories: true)
                    self.startWatching()
                }
            } else {
                self.scheduleReload()
            }
        }
        // Close the descriptor this source owns, captured by value. Reading it
        // back off `self` would be wrong: cancel handlers run asynchronously, so
        // a re-armed watch could have replaced the stored value by then and we
        // would close the live descriptor instead of the dead one.
        source.setCancelHandler {
            close(fd)
        }
        watcher = source
        source.resume()
    }

    private func stopWatching() {
        // Clearing the handler releases its strong capture of the source, which
        // is what keeps the cycle noted above from leaking a watch per re-arm.
        watcher?.setEventHandler(handler: nil)
        watcher?.cancel()
        watcher = nil
    }

    /// A single turn can rewrite several files in a burst. Coalesce so we parse
    /// once rather than once per write.
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    // MARK: - Loading

    private func reload() {
        let now = Date()
        var found: [Session] = []

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            guard name.hasSuffix(".json") else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any],
                  let session = Session(json: json)
            else { continue }

            let age = now.timeIntervalSince(session.updated)
            if age > debrisAfter { continue }
            if session.mood == .done && age > doneLingers { continue }
            if session.mood == .idle && age > idleLingers { continue }
            found.append(session)
        }

        // Most recently active first, but anything that wants you goes to the top.
        found.sort { left, right in
            if left.mood.urgency != right.mood.urgency {
                return left.mood.urgency > right.mood.urgency
            }
            return left.updated > right.updated
        }

        detectTransitions(in: found)

        if found != sessions {
            sessions = found
        }

        reloadUsage()
    }

    /// Reads whatever the status line harvester last wrote. Cheap enough to do
    /// on every pass: one small file, and usually absent.
    private func reloadUsage() {
        let url = directory.deletingLastPathComponent()
            .appendingPathComponent("usage.json")
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data),
           let json = object as? [String: Any] {
            harvestedUsage = UsageSnapshot(json: json)
        } else {
            harvestedUsage = nil
        }
        publishUsage()
    }

    private func applyFetchedUsage(_ snapshot: UsageSnapshot?, _ status: UsageStatus) {
        if let snapshot = snapshot {
            fetchedUsage = snapshot
        } else if status == .disabled || status == .notSignedIn {
            // Off, or signed out: the last figures belong to a sign-in that is
            // no longer in use, so stop showing them. Anything else is a blip,
            // and the last figures stay up, marked stale by their age.
            fetchedUsage = nil
        }
        if usageStatus != status { usageStatus = status }
        publishUsage()
    }

    private func publishUsage() {
        let chosen: UsageSnapshot?
        if UserDefaults.standard.bool(forKey: UsageFetcher.disabledKey) {
            // Off means off: no bars from either source.
            chosen = nil
        } else if let fetched = fetchedUsage, let harvested = harvestedUsage {
            let fetchedIsFresh = Date().timeIntervalSince(fetched.captured) < fetchedUsageTrustedFor
            chosen = fetchedIsFresh || fetched.captured >= harvested.captured ? fetched : harvested
        } else {
            chosen = fetchedUsage ?? harvestedUsage
        }
        if usage != chosen { usage = chosen }
    }

    private func detectTransitions(in found: [Session]) {
        var nextMoods: [String: Mood] = [:]
        var justFinished = false
        var justNeedsYou = false

        for session in found {
            nextMoods[session.id] = session.mood
            let before = previousMoods[session.id]
            guard let before = before else {
                // First sighting. Do not chime for a session that was already
                // finished when the widget launched.
                continue
            }
            if before != session.mood {
                if session.mood == .done { justFinished = true }
                if session.mood == .attention || session.mood == .failed { justNeedsYou = true }
            }
        }

        previousMoods = nextMoods

        if justFinished {
            celebratedAt = Date()
            // A finished turn is what moves the usage numbers.
            usageFetcher.refreshSoon()
        }
        if justNeedsYou { alertedAt = Date() }
    }

    // MARK: - Derived

    /// The mood the header critter wears: whichever session wants you most.
    var headlineMood: Mood {
        sessions.max(by: { $0.mood.urgency < $1.mood.urgency })?.mood ?? .idle
    }

    /// A one-line summary for the header, e.g. "2 working · 1 needs you".
    var headline: String {
        if sessions.isEmpty { return "no sessions" }
        var counts: [Mood: Int] = [:]
        for session in sessions { counts[session.mood, default: 0] += 1 }
        let order: [Mood] = [.attention, .failed, .working, .done, .idle]
        let parts = order.compactMap { mood -> String? in
            guard let count = counts[mood], count > 0 else { return nil }
            return "\(count) \(mood.word)"
        }
        return parts.joined(separator: " · ")
    }
}
