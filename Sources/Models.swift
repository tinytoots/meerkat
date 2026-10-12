import Foundation

/// What a session is doing right now. Ordered loosely by how much it wants you.
enum Mood: String {
    case idle
    case working
    case attention
    case done
    case failed

    /// Higher wins when the header critter has to represent several sessions.
    var urgency: Int {
        switch self {
        case .attention: return 5
        case .failed: return 4
        case .working: return 3
        case .done: return 2
        case .idle: return 1
        }
    }

    var word: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .attention: return "needs you"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// One Claude Code session, as last reported by the hook.
struct Session: Identifiable, Equatable {
    let id: String
    var label: String
    var cwd: String
    var mood: Mood
    var detail: String
    var waitingFor: String
    var since: Date
    var updated: Date
    var tasksTotal: Int
    var tasksDone: Int
    var turns: Int

    var hasProgress: Bool { tasksTotal > 0 }

    var progress: Double {
        guard tasksTotal > 0 else { return 0 }
        return min(1, max(0, Double(tasksDone) / Double(tasksTotal)))
    }

    /// The line under the session name: what it is waiting on, or what it is doing.
    var subtitle: String {
        if mood == .attention || mood == .failed {
            if !waitingFor.isEmpty { return waitingFor }
        }
        if !detail.isEmpty { return detail }
        return mood.word
    }

    /// Decoded from one of the hook's session JSON files. Returns nil for
    /// anything malformed, so a half-written or future-version file is skipped
    /// rather than crashing the widget.
    init?(json: [String: Any]) {
        guard let id = json["session_id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.label = (json["label"] as? String) ?? "session"
        self.cwd = (json["cwd"] as? String) ?? ""
        self.mood = Mood(rawValue: (json["state"] as? String) ?? "") ?? .idle
        self.detail = (json["detail"] as? String) ?? ""
        self.waitingFor = (json["waiting_for"] as? String) ?? ""
        let sinceSeconds = (json["since"] as? Double) ?? 0
        let updatedSeconds = (json["updated"] as? Double) ?? sinceSeconds
        self.since = Date(timeIntervalSince1970: sinceSeconds)
        self.updated = Date(timeIntervalSince1970: updatedSeconds)
        self.tasksTotal = (json["tasks_total"] as? Int) ?? 0
        self.tasksDone = (json["tasks_done"] as? Int) ?? 0
        self.turns = (json["turns"] as? Int) ?? 0
    }
}

/// Short elapsed time, the way a stopwatch you glance at should read.
func shortElapsed(since date: Date, now: Date = Date()) -> String {
    // Clamped at both ends before the Int conversion: `since` is read from a
    // JSON file we do not control, and Int(_:) on a Double beyond Int64's range
    // traps outright rather than throwing.
    let seconds = Int(min(max(0, now.timeIntervalSince(date)), 3.15e9))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h \(minutes % 60)m" }
    return "\(hours / 24)d"
}


/// One plan-usage window, from whichever source last reported it.
struct UsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?

    init(id: String, label: String, percent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        // Clamped here, once, because the view hands this to Int(_:), which
        // traps on a value outside Int's range rather than throwing.
        self.percent = percent.isFinite ? min(max(percent, 0), 999) : 0
        self.resetsAt = resetsAt
    }

    /// Session first, then the week, then the per-model weeks, anything else,
    /// and spend last.
    var sortKey: Int {
        switch id {
        case "five_hour": return 0
        case "seven_day": return 1
        case "spend_limit": return 9
        default: return id.hasPrefix("model:") ? 2 : 5
        }
    }

    /// The long name, worded the way claude.ai words it, for tooltips.
    var title: String {
        switch id {
        case "five_hour": return "Current session"
        case "seven_day": return "This week (all models)"
        case "spend_limit": return "Spend limit"
        default: return id.hasPrefix("model:") ? "\(label) this week" : label
        }
    }

    /// Turn a raw key into something readable. Known windows get a proper name;
    /// anything this version of Claude Code adds later gets a tidied-up version
    /// of its own key rather than being dropped.
    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "Session"
        case "seven_day": return "Week"
        case "spend_limit": return "Spend"
        default:
            var name = key
            for suffix in ["_seven_day", "_five_hour", "_weekly", "_daily", "_limit"] {
                if name.hasSuffix(suffix) {
                    name = String(name.dropLast(suffix.count))
                    break
                }
            }
            name = name.replacingOccurrences(of: "_", with: " ")
            guard let first = name.first else { return key }
            return first.uppercased() + name.dropFirst()
        }
    }
}

/// A set of plan-usage figures, where they came from, and when.
struct UsageSnapshot: Equatable {

    enum Source: String {
        /// GET api.anthropic.com/api/oauth/usage, fetched by UsageFetcher.
        case api
        /// ~/.meerkat/usage.json, written by the status line harvester.
        case statusLine
    }

    let captured: Date
    let windows: [UsageWindow]
    let source: Source

    init(captured: Date, windows: [UsageWindow], source: Source) {
        self.captured = captured
        self.windows = windows.sorted { left, right in
            if left.sortKey != right.sortKey { return left.sortKey < right.sortKey }
            return left.id < right.id
        }
        self.source = source
    }

    /// Decoded from the status line harvester's usage.json.
    init?(json: [String: Any]) {
        guard let captured = json["captured"] as? Double,
              let raw = json["windows"] as? [String: Any],
              !raw.isEmpty
        else { return nil }

        var found: [UsageWindow] = []
        for (key, value) in raw {
            guard let entry = value as? [String: Any],
                  let percent = usageNumber(entry["used_percentage"])
            else { continue }
            found.append(
                UsageWindow(
                    id: key,
                    label: UsageWindow.label(for: key),
                    percent: percent,
                    resetsAt: usageDate(entry["resets_at"])))
        }
        guard !found.isEmpty else { return nil }
        self.init(
            captured: Date(timeIntervalSince1970: captured), windows: found, source: .statusLine)
    }

    /// Decoded from the body of GET api.anthropic.com/api/oauth/usage, the
    /// endpoint behind Claude Code's own /usage screen and claude.ai's
    /// Settings -> Usage. It is undocumented, so every field is treated as
    /// optional and anything unrecognised is skipped rather than trusted:
    ///
    ///     five_hour, seven_day   {utilization: 0-100, resets_at: ISO 8601}
    ///     limits[]               {kind: "weekly_scoped",
    ///                             scope: {model: {display_name: "Fable"}},
    ///                             percent: 0-100,
    ///                             resets_at: epoch seconds or ISO 8601}
    ///
    /// The per-model weeks ("Fable this week") exist only in limits[]. The
    /// seven_day_<codename> keys beside them are not what claude.ai shows, and
    /// Claude Code does not display them either, so they are left alone.
    init?(usageAPI json: [String: Any], captured: Date) {
        var found: [UsageWindow] = []

        for key in ["five_hour", "seven_day"] where json.keys.contains(key) {
            // Present but null means the window has not started: nothing used
            // yet and no reset scheduled, which claude.ai shows as 0%.
            let entry = json[key] as? [String: Any]
            found.append(
                UsageWindow(
                    id: key,
                    label: UsageWindow.label(for: key),
                    percent: entry.flatMap { usageNumber($0["utilization"]) } ?? 0,
                    resetsAt: entry.flatMap { usageDate($0["resets_at"]) }))
        }

        for case let limit as [String: Any] in (json["limits"] as? [Any]) ?? [] {
            guard (limit["kind"] as? String) == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String,
                  !name.isEmpty
            else { continue }
            let id = "model:" + name.lowercased()
            guard !found.contains(where: { $0.id == id }) else { continue }
            found.append(
                UsageWindow(
                    id: id,
                    label: name,
                    percent: usageNumber(limit["percent"])
                        ?? usageNumber(limit["utilization"]) ?? 0,
                    resetsAt: usageDate(limit["resets_at"])))
        }

        guard !found.isEmpty else { return nil }
        self.init(captured: captured, windows: found, source: .api)
    }
}

/// A JSON number as a Double, whether it arrived as an integer or a float.
/// JSONSerialization also hands back true/false as NSNumber; those are not
/// figures, so they are refused.
private func usageNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let double = number.doubleValue
    return double.isFinite ? double : nil
}

/// A reset time. The endpoint sends epoch seconds in some places and ISO 8601
/// in others, sometimes with microseconds, which ISO8601DateFormatter refuses,
/// so any fraction is dropped before parsing. A minute either way is noise.
private func usageDate(_ value: Any?) -> Date? {
    if let number = usageNumber(value) {
        guard number > 0 else { return nil }
        // Nothing in this century is 1e11 seconds out, so that is milliseconds.
        return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
    }
    guard let text = value as? String, !text.isEmpty else { return nil }
    let whole = text.replacingOccurrences(
        of: #"\.[0-9]+"#, with: "", options: .regularExpression)
    return isoReader.date(from: whole)
}

private let isoReader: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()
