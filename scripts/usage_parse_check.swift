import Foundation

/// Exercises UsageSnapshot's two parsers against canned replies, without a
/// network, a keychain or a window. Run it through scripts/usage-parse-check.sh,
/// which compiles it together with Sources/Models.swift.
///
/// The reply shapes mirror what Claude Code's own /usage code reads from
/// api.anthropic.com/api/oauth/usage. If the endpoint changes shape, add the
/// new reply here first.
@main
struct UsageParseCheck {

    static var failures = 0
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("  FAIL  \(message)")
        }
    }

    static func json(_ text: String) -> [String: Any] {
        let object = try! JSONSerialization.jsonObject(with: Data(text.utf8))
        return object as! [String: Any]
    }

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    static let now = Date(timeIntervalSince1970: 1_760_200_000)

    static func main() {
        fullReply()
        unstartedWindow()
        emptyReplies()
        millisecondsAndOddValues()
        harvesterFormat()

        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    /// Everything claude.ai shows, plus the noise around it that must be ignored.
    static func fullReply() {
        let reply = json(
            """
            {
              "five_hour": {"utilization": 16.0, "resets_at": "2026-10-12T04:10:00.123456+00:00"},
              "seven_day": {"utilization": 81, "resets_at": "2026-10-12T13:00:00Z"},
              "seven_day_oauth_apps": null,
              "seven_day_opus": null,
              "seven_day_sonnet": {"utilization": 3.0, "resets_at": "2026-10-12T13:00:00+00:00"},
              "seven_day_omelette": {"utilization": 100.0, "resets_at": "2026-10-12T13:00:00+00:00"},
              "extra_usage": {"is_enabled": false, "monthly_limit": null, "utilization": null},
              "limits": [
                {"kind": "session", "percent": 16},
                {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Fable"}},
                 "percent": 100, "resets_at": 1760274000},
                {"kind": "weekly_scoped", "scope": {}, "percent": 50},
                {"kind": "weekly_scoped", "scope": {"model": {"display_name": ""}}, "percent": 50},
                "not an object",
                {"kind": "weekly_scoped", "scope": {"model": {"display_name": "fable"}}, "percent": 1}
              ]
            }
            """)
        guard let snapshot = UsageSnapshot(usageAPI: reply, captured: now) else {
            expect(false, "full reply: parsed to nil")
            return
        }
        expect(snapshot.source == .api, "full reply: source is api")
        expect(snapshot.captured == now, "full reply: captured is the time passed in")
        expect(
            snapshot.windows.map(\.id) == ["five_hour", "seven_day", "model:fable"],
            "full reply: exactly session, week, Fable in that order, got \(snapshot.windows.map(\.id))")
        guard snapshot.windows.count == 3 else { return }

        let (session, week, fable) = (snapshot.windows[0], snapshot.windows[1], snapshot.windows[2])
        expect(session.label == "Session" && session.percent == 16, "session: label and 16%")
        expect(
            session.resetsAt == date("2026-10-12T04:10:00Z"),
            "session: ISO reset with microseconds parsed, got \(String(describing: session.resetsAt))")
        expect(session.title == "Current session", "session: tooltip title")
        expect(week.label == "Week" && week.percent == 81, "week: label and integer 81 read as 81%")
        expect(week.resetsAt == date("2026-10-12T13:00:00Z"), "week: ISO reset with Z parsed")
        expect(fable.label == "Fable" && fable.percent == 100, "Fable: label and 100% from percent")
        expect(
            fable.resetsAt == Date(timeIntervalSince1970: 1_760_274_000),
            "Fable: epoch-seconds reset parsed")
        expect(fable.title == "Fable this week", "Fable: tooltip title")
    }

    /// A window the server lists as null has not started yet. A window that is
    /// there but has no readable figure is left out, never shown as 0%.
    static func unstartedWindow() {
        let reply = json(
            """
            {"five_hour": null, "seven_day": {"utilization": 4.5, "resets_at": null}}
            """)
        guard let snapshot = UsageSnapshot(usageAPI: reply, captured: now) else {
            expect(false, "unstarted: parsed to nil")
            return
        }
        expect(snapshot.windows.map(\.id) == ["five_hour", "seven_day"], "unstarted: both rows kept")
        expect(
            snapshot.windows.first?.percent == 0 && snapshot.windows.first?.resetsAt == nil,
            "unstarted: null window shows 0% with no reset")
        expect(snapshot.windows.last?.resetsAt == nil, "unstarted: null resets_at is no reset")

        let unreadable = json(
            """
            {"five_hour": {"utilization": null, "resets_at": "2026-10-12T04:10:00Z"},
             "seven_day": {"utilization": "81"},
             "limits": [{"kind": "weekly_scoped", "scope": {"model": {"display_name": "Fable"}},
                         "resets_at": 1760274000}],
             "seven_day_opus": {"utilization": 12}}
            """)
        expect(
            UsageSnapshot(usageAPI: unreadable, captured: now) == nil,
            "rows with no readable figure are left out, not made 0%; none left is nil")
    }

    /// Nothing recognisable must be nil, so the fetcher reports an unexpected
    /// reply instead of showing an empty block.
    static func emptyReplies() {
        expect(UsageSnapshot(usageAPI: json("{}"), captured: now) == nil, "empty object is nil")
        expect(
            UsageSnapshot(usageAPI: json(#"{"limits": []}"#), captured: now) == nil,
            "empty limits only is nil")
        expect(
            UsageSnapshot(usageAPI: json(#"{"error": {"type": "rate_limit_error"}}"#), captured: now) == nil,
            "an in-band error body is nil")
    }

    static func millisecondsAndOddValues() {
        let reply = json(
            """
            {
              "five_hour": {"utilization": 1e308, "resets_at": 1760274000000},
              "seven_day": {"utilization": -5, "resets_at": "not a date"},
              "limits": [
                {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Opus"}},
                 "percent": true, "utilization": 42, "resets_at": "2026-10-12T13:00:00.5Z"}
              ]
            }
            """)
        guard let snapshot = UsageSnapshot(usageAPI: reply, captured: now),
              snapshot.windows.count == 3
        else {
            expect(false, "odd values: did not parse to three windows")
            return
        }
        let (session, week, opus) = (snapshot.windows[0], snapshot.windows[1], snapshot.windows[2])
        expect(session.percent == 999, "a huge percentage is clamped, got \(session.percent)")
        expect(
            session.resetsAt == Date(timeIntervalSince1970: 1_760_274_000),
            "a millisecond reset is read as milliseconds")
        expect(week.percent == 0, "a negative percentage is clamped to 0")
        expect(week.resetsAt == nil, "an unparseable reset is no reset")
        expect(opus.percent == 42, "a boolean percent is refused in favour of utilization")
        expect(opus.resetsAt == date("2026-10-12T13:00:00Z"), "a fractional-second ISO reset parses")
    }

    /// The status line harvester's usage.json must keep working as before.
    static func harvesterFormat() {
        let file = json(
            """
            {"captured": 1760000000,
             "windows": {"five_hour": {"used_percentage": 16, "resets_at": 1760274000},
                         "fable_seven_day": {"used_percentage": 100.0},
                         "broken": "nope"}}
            """)
        guard let snapshot = UsageSnapshot(json: file) else {
            expect(false, "harvester: parsed to nil")
            return
        }
        expect(snapshot.source == .statusLine, "harvester: source is statusLine")
        expect(
            snapshot.captured == Date(timeIntervalSince1970: 1_760_000_000), "harvester: captured")
        expect(
            snapshot.windows.map(\.label) == ["Session", "Fable"],
            "harvester: Session then Fable, got \(snapshot.windows.map(\.label))")
        expect(
            snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_760_274_000),
            "harvester: epoch reset")
        expect(UsageSnapshot(json: json(#"{"captured": 1, "windows": {}}"#)) == nil, "harvester: no windows is nil")
    }
}
