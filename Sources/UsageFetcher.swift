import AppKit
import Foundation

/// Why the plan-usage block shows what it shows.
enum UsageStatus: Equatable {
    case starting
    case ok
    /// Turned off from the menu.
    case disabled
    /// No Claude Code sign-in in the login keychain.
    case notSignedIn
    /// The login keychain is locked, so nothing can read from it.
    case keychainLocked
    /// The stored token has expired or was refused. Claude Code renews it the
    /// next time it runs; Meerkat deliberately does not.
    case signInExpired
    /// The endpoint asked us to back off.
    case rateLimited(until: Date)
    /// Anything else: offline, a server error, a reply we could not read.
    case unavailable(String)

    /// A few words for the line under the header.
    var summary: String {
        switch self {
        case .starting: return "checking…"
        case .ok: return ""
        case .disabled: return "off"
        case .notSignedIn: return "not signed in"
        case .keychainLocked: return "keychain locked"
        case .signInExpired: return "sign-in expired"
        case .rateLimited(let until): return "retry \(UsageStatus.clock.string(from: until))"
        case .unavailable(let reason): return reason
        }
    }

    /// A sentence for a tooltip.
    var explanation: String {
        switch self {
        case .starting:
            return "Checking plan usage."
        case .ok:
            return "Plan usage is current."
        case .disabled:
            return "Plan usage is turned off. Right-click -> Turn on plan usage."
        case .notSignedIn:
            return "No Claude Code sign-in was found in your login keychain. "
                + "Sign in to Claude Code with your Claude plan."
        case .keychainLocked:
            return "Your login keychain is locked, so Meerkat cannot read your "
                + "Claude Code sign-in. Unlocking your Mac unlocks it."
        case .signInExpired:
            return "Your Claude Code sign-in has expired. Claude Code renews it "
                + "the next time it runs; Meerkat picks that up on its own."
        case .rateLimited(let until):
            return "The usage endpoint asked Meerkat to slow down. Next try at "
                + "\(UsageStatus.clock.string(from: until))."
        case .unavailable(let reason):
            return "Could not load plan usage: \(reason)."
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()
}

/// Fetches plan usage the way Claude Code's own /usage screen does: the
/// signed-in account's OAuth token from the login keychain, then one GET to
/// api.anthropic.com/api/oauth/usage. That is the only source that has all of
/// claude.ai's rows, the per-model weekly limits included, and it works whether
/// you use the terminal, the VS Code extension or the desktop app.
///
/// The token is the sensitive part, so it is handled narrowly. It is read fresh
/// for every request through /usr/bin/security -- the same tool, item and
/// account Claude Code itself uses, which is why macOS does not ask for
/// permission -- kept only for the length of that one request, and never logged
/// or written anywhere. A locked keychain is noticed first and skipped, the way
/// Claude Code does it, so Meerkat never raises an unlock dialog. Meerkat never
/// refreshes the token, either: a refresh rotates it, which would quietly sign
/// Claude Code out. An expired token just waits for Claude Code to renew it.
///
/// The endpoint is undocumented and may change shape; UsageSnapshot parses it
/// defensively, and anything it cannot read surfaces as a status, not a crash.
final class UsageFetcher {

    /// Called on the main queue after every attempt. The snapshot is nil
    /// unless that attempt produced fresh figures.
    var onUpdate: ((UsageSnapshot?, UsageStatus) -> Void)?

    /// UserDefaults key for the menu's off switch.
    static let disabledKey = "usageFetchDisabled"

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Where Claude Code keeps its sign-in. A Claude Code started with
    /// CLAUDE_CONFIG_DIR appends a hash of that path to the service name; that
    /// setup is not supported here.
    private let keychainService = "Claude Code-credentials"

    /// How often to look when nothing prompts us to. A turn finishing prompts
    /// an earlier look, so this only has to cover the quiet stretches.
    private let interval: TimeInterval = 180

    /// Never ask more often than this, however many turns finish at once.
    private let minimumGap: TimeInterval = 45

    /// After the keychain failed to answer at all -- most likely a dialog
    /// someone else raised -- leave it alone for a good while.
    private let keychainQuietPeriod: TimeInterval = 30 * 60

    /// Where the last attempt is recorded for scripts/check-usage.sh. Figures
    /// and status only; never the token.
    private let statusFile: URL

    private let worker = DispatchQueue(label: "local.meerkat.usage")
    private let session: URLSession

    // Everything below is touched only on the main queue.
    private var pending: DispatchWorkItem?
    private var pendingAt: Date?
    private var inFlight = false
    private var lastAttempt = Date.distantPast
    private var notBefore = Date.distantPast
    private var backoff: TimeInterval = 0
    private var lastGood: UsageSnapshot?
    /// Windows the last reply carried that the bars do not show, for
    /// check-usage.sh. Figures only.
    private var lastUnshown: [String: Double] = [:]
    private var wakeObserver: NSObjectProtocol?

    init(stateDirectory: URL) {
        statusFile = stateDirectory.appendingPathComponent("usage-api.json")

        // Ephemeral: no cookies, no cache, no credential store. Nothing about
        // these requests outlives them.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
    }

    deinit {
        stop()
    }

    func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The numbers have moved while we slept. Give the network a few
            // seconds to come back first.
            self?.schedule(after: 8)
        }
        schedule(after: 1)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        pendingAt = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Something probably moved the numbers, like a turn finishing. Look soon,
    /// but not sooner than minimumGap after the last look.
    func refreshSoon() {
        let wait = minimumGap - Date().timeIntervalSince(lastAttempt)
        schedule(after: max(2, wait))
    }

    /// The menu's refresh. A look already under way answers it, and keeps
    /// any sooner look that is already pending.
    func refreshNow() {
        guard !inFlight else { return }
        schedule(after: 0, replacingSooner: true)
    }

    /// The menu's off switch. Off takes effect at once: whatever is pending is
    /// cancelled and whatever is in flight is dropped when it lands. On looks
    /// straight away, unless the endpoint asked us to back off, which holds.
    func setDisabled(_ off: Bool) {
        UserDefaults.standard.set(off, forKey: Self.disabledKey)
        if off {
            pending?.cancel()
            pending = nil
            pendingAt = nil
            lastGood = nil
            lastUnshown = [:]
            onUpdate?(nil, .disabled)
            record(.disabled)
        } else {
            onUpdate?(nil, notBefore > Date() ? .rateLimited(until: notBefore) : .starting)
            schedule(after: 0, replacingSooner: true)
        }
    }

    private var isDisabled: Bool {
        // UserDefaults is thread-safe, so the worker may ask too.
        UserDefaults.standard.bool(forKey: Self.disabledKey)
    }

    // MARK: - Scheduling

    /// Arrange the next look. An already-pending look that is sooner is kept,
    /// unless `replacingSooner`; a back-off the server asked for always holds.
    ///
    /// Everything here runs on the wall clock -- pendingAt, notBefore and the
    /// timer itself -- so a look that fell due while the Mac slept runs on
    /// wake instead of waiting out the rest of its delay in awake time.
    private func schedule(after delay: TimeInterval, replacingSooner: Bool = false) {
        let now = Date()
        let when = max(now.addingTimeInterval(max(0, delay)), notBefore)
        if !replacingSooner, let pendingAt = pendingAt, pendingAt > now, pendingAt <= when {
            return
        }

        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending = nil
            self.pendingAt = nil
            self.fetch()
        }
        pending = item
        pendingAt = when
        DispatchQueue.main.asyncAfter(
            wallDeadline: .now() + max(0, when.timeIntervalSinceNow), execute: item)
    }

    // MARK: - Fetching

    private func fetch() {
        // A look already under way will answer this one too.
        guard !inFlight else { return }

        if isDisabled {
            finish(nil, .disabled, retryAfter: interval)
            return
        }

        inFlight = true
        lastAttempt = Date()

        worker.async { [weak self] in
            guard let self = self else { return }
            let read = self.readToken()
            DispatchQueue.main.async {
                switch read {
                case .failure(let status, let retry):
                    if status == .notSignedIn { self.lastGood = nil }
                    self.finish(nil, status, retryAfter: retry ?? self.interval)
                case .success(let token):
                    // Turned off while the keychain was being read: send nothing.
                    if self.isDisabled {
                        self.finish(nil, .disabled, retryAfter: self.interval)
                    } else {
                        self.request(with: token)
                    }
                }
            }
        }
    }

    private enum TokenRead {
        case success(String)
        /// With how long to wait before trying again, when that should differ
        /// from the usual interval.
        case failure(UsageStatus, retryAfter: TimeInterval?)
    }

    /// Reads the access token out of Claude Code's keychain item. Runs on the
    /// worker queue: `security` can block.
    private func readToken() -> TokenRead {
        // Reading an item from a locked keychain makes `security` raise an
        // unlock dialog, and every later look would raise it again. Ask first
        // whether the keychain is locked, the way Claude Code does:
        // show-keychain-info answers 36 for a locked keychain without any UI.
        let lock = runSecurity(["show-keychain-info"])
        if lock.status == 36 {
            return .failure(.keychainLocked, retryAfter: nil)
        }

        let read = runSecurity([
            "find-generic-password", "-a", keychainAccount(), "-w", "-s", keychainService,
        ])
        if read.killed {
            // It sat there past the watchdog, which means something is waiting
            // on a person. Do not keep summoning that.
            return .failure(.unavailable("keychain did not answer"), retryAfter: keychainQuietPeriod)
        }
        switch read.status {
        case 0:
            break
        case 44:  // errSecItemNotFound
            return .failure(.notSignedIn, retryAfter: nil)
        case 36:  // errSecInteractionNotAllowed: locked after all
            return .failure(.keychainLocked, retryAfter: nil)
        case 128:  // the user cancelled a dialog
            return .failure(.unavailable("keychain access cancelled"), retryAfter: keychainQuietPeriod)
        default:
            return .failure(.unavailable("keychain error \(read.status)"), retryAfter: nil)
        }

        // The item holds JSON: {"claudeAiOauth": {"accessToken", "expiresAt",
        // ...}}. An item without claudeAiOauth is an API-key sign-in, which has
        // no plan and so no plan usage.
        guard let object = try? JSONSerialization.jsonObject(with: read.output),
              let json = object as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return .failure(.notSignedIn, retryAfter: nil) }

        // expiresAt is epoch milliseconds. Sending a token we know is dead
        // would only earn a 401. Look again fairly soon, so the bars come back
        // promptly once Claude Code has renewed it.
        if let expires = oauth["expiresAt"] as? NSNumber,
           expires.doubleValue / 1000 < Date().timeIntervalSince1970 + 30 {
            return .failure(.signInExpired, retryAfter: 60)
        }
        return .success(token)
    }

    /// Runs /usr/bin/security with a 10-second watchdog. Its stderr goes
    /// nowhere: the only interesting thing it says there is an error we
    /// already get as the exit status.
    private func runSecurity(_ arguments: [String]) -> (status: Int32, output: Data, killed: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, Data(), false)
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data, process.terminationReason == .uncaughtSignal)
    }

    /// The keychain account Claude Code files its item under: your user name,
    /// or a fixed fallback when that has characters it does not accept.
    private func keychainAccount() -> String {
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if name.isEmpty || name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "claude-code-user"
        }
        return name
    }

    private func request(with token: String) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Meerkat/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            let captured = Date()
            DispatchQueue.main.async {
                self?.handle(data: data, response: response, error: error, captured: captured)
            }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, captured: Date) {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                finish(nil, .unavailable("offline"), retryAfter: interval)
            default:
                finish(nil, .unavailable("network error \(error.code.rawValue)"), retryAfter: interval)
            }
            return
        }
        guard let http = response as? HTTPURLResponse else {
            finish(nil, .unavailable("no reply"), retryAfter: interval)
            return
        }

        switch http.statusCode {
        case 200:
            guard let data = data,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any],
                  let snapshot = UsageSnapshot(usageAPI: json, captured: captured)
            else {
                finish(nil, .unavailable("unexpected reply"), retryAfter: interval)
                return
            }
            backoff = 0
            lastGood = snapshot
            lastUnshown = UsageFetcher.unshownWindows(in: json, shown: snapshot)
            finish(snapshot, .ok, retryAfter: interval)

        case 401:
            finish(nil, .signInExpired, retryAfter: interval)

        case 403:
            finish(nil, .unavailable("refused (403)"), retryAfter: interval * 5)

        case 429:
            // Honour Retry-After when it is given in seconds; otherwise back off
            // exponentially from five minutes, capped at half an hour.
            let asked = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            backoff = min(max(backoff * 2, 300), 1800)
            let wait = min(max(asked ?? backoff, 60), 3600)
            let until = Date().addingTimeInterval(wait)
            notBefore = until
            finish(nil, .rateLimited(until: until), retryAfter: wait, replacingSooner: true)

        default:
            finish(nil, .unavailable("server error \(http.statusCode)"), retryAfter: interval)
        }
    }

    private func finish(
        _ snapshot: UsageSnapshot?, _ status: UsageStatus,
        retryAfter delay: TimeInterval, replacingSooner: Bool = false
    ) {
        inFlight = false
        if isDisabled {
            // Off, possibly flipped while this look was under way: whatever it
            // found is dropped, and nothing more is scheduled until it is
            // turned back on.
            lastGood = nil
            lastUnshown = [:]
            onUpdate?(nil, .disabled)
            record(.disabled)
            return
        }
        onUpdate?(snapshot, status)
        record(status)
        schedule(after: delay, replacingSooner: replacingSooner)
    }

    /// Top-level windows with a figure that the bars leave out, such as
    /// seven_day_sonnet, so check-usage.sh can say they exist.
    private static func unshownWindows(in json: [String: Any], shown: UsageSnapshot) -> [String: Double] {
        let shownIDs = Set(shown.windows.map(\.id))
        var unshown: [String: Double] = [:]
        for (key, value) in json where !shownIDs.contains(key) {
            if let entry = value as? [String: Any],
               let number = entry["utilization"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID() {
                unshown[key] = number.doubleValue
            }
        }
        return unshown
    }

    /// Leaves a note of the last attempt for scripts/check-usage.sh, in the
    /// harvester's own window format so one reader handles both.
    private func record(_ status: UsageStatus) {
        var note: [String: Any] = [
            "attempted": Date().timeIntervalSince1970,
            "status": status == .ok ? "ok" : status.explanation,
        ]
        if let good = lastGood {
            note["captured"] = good.captured.timeIntervalSince1970
            var windows: [String: Any] = [:]
            for window in good.windows {
                var entry: [String: Any] = [
                    "label": window.label,
                    "used_percentage": window.percent,
                ]
                if let resets = window.resetsAt {
                    entry["resets_at"] = resets.timeIntervalSince1970
                }
                windows[window.id] = entry
            }
            note["windows"] = windows
            if !lastUnshown.isEmpty { note["not_shown"] = lastUnshown }
        }
        let url = statusFile
        worker.async {
            guard let data = try? JSONSerialization.data(
                withJSONObject: note, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
