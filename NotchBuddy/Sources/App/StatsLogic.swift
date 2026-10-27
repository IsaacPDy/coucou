import Foundation

// The numbers behind the Stats page, worked out from what RecapStore and PlanHistory keep.
// Foundation only, so it can be tested alone (tests/StatsLogicTests.swift).

enum StatsPeriod: String, CaseIterable, Identifiable {
    case today, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return String(localized: "Today")
        case .week:  return String(localized: "7 days")
        case .month: return String(localized: "30 days")
        }
    }

    var dayCount: Int {
        switch self {
        case .today: return 1
        case .week:  return 7
        case .month: return 30
        }
    }

    func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
    }
}

struct AgentStats {
    struct Day: Identifiable {
        var date: Date
        var minutes: Double = 0
        var added = 0
        var removed = 0
        var id: Date { date }
    }

    struct Share: Identifiable {
        var key: String       // pill id or project name
        var minutes: Double
        var turns: Int
        var id: String { key }
    }

    struct CommandCount: Identifiable {
        var command: String
        var approved: Int
        var denied: Int
        var id: String { command }
        /// Approved again and again, never denied: worth a place on the "Always" list.
        var suggestsAlways: Bool { approved >= 5 && denied == 0 }
    }

    struct Session: Identifiable {
        var id: String
        var pillId: String
        var project: String
        var start: Date
        var end: Date
        var turns: Int
        var workingSeconds: Double
        var waitingSeconds: Double
        var added: Int
        var removed: Int
        var topFiles: [(name: String, lines: Int)]
        var duration: Double { end.timeIntervalSince(start) }
        var diffSize: Int { added + removed }
    }

    struct Records {
        var currentStreak = 0
        var longestStreak = 0
        var longestSession: Session?
        var biggestDiff: Session?
        var busiestDay: Day?
    }

    // Totals over the period
    var activeMinutes: Double = 0
    var turnCount = 0
    var sessionCount = 0
    var added = 0
    var removed = 0
    var filesChanged = 0
    var commandsRun = 0

    var days: [Day] = []
    var agents: [Share] = []
    var projects: [Share] = []
    /// Minutes of work per weekday (0 = Monday) and hour (0–23).
    var heatmap: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)

    // Approvals over the period
    var allowed = 0
    var always = 0
    var denied = 0
    var averageWaitSeconds: Double?
    var commands: [CommandCount] = []

    var sessions: [Session] = []
    /// Over everything recorded, not just the period.
    var records = Records()

    var hasData: Bool { turnCount > 0 || allowed + always + denied > 0 }

    // MARK: - Computing

    static func compute(turns allTurns: [RecapTurn], decisions allDecisions: [RecapDecision],
                        period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) -> AgentStats {
        var stats = AgentStats()
        let start = period.start(now: now, calendar: calendar)
        let turns = allTurns.filter { $0.end > start && $0.end > $0.start }
        let decisions = allDecisions.filter { $0.date >= start }

        // Time, merged so parallel sessions are not counted twice, cut to the period.
        let merged = mergeIntervals(turns.map { (max($0.start, start), min($0.end, now)) })
        stats.activeMinutes = merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 60
        stats.turnCount = turns.count
        stats.added = turns.reduce(0) { $0 + $1.linesAdded }
        stats.removed = turns.reduce(0) { $0 + $1.linesRemoved }
        stats.filesChanged = turns.reduce(0) { $0 + $1.filesChanged }
        stats.commandsRun = turns.reduce(0) { $0 + $1.commandsRun }

        // One bar per day.
        stats.days = (0..<period.dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { Day(date: $0) }
        }
        for interval in merged {
            for (bucket, seconds) in split(interval, by: .day, calendar: calendar) {
                if let i = stats.days.firstIndex(where: { $0.date == bucket }) { stats.days[i].minutes += seconds / 60 }
            }
        }
        for turn in turns {
            let day = calendar.startOfDay(for: turn.end)
            if let i = stats.days.firstIndex(where: { $0.date == day }) {
                stats.days[i].added += turn.linesAdded
                stats.days[i].removed += turn.linesRemoved
            }
        }

        // When you code: weekday × hour.
        for interval in merged {
            for (bucket, seconds) in split(interval, by: .hour, calendar: calendar) {
                let weekday = (calendar.component(.weekday, from: bucket) + 5) % 7   // Monday = 0
                stats.heatmap[weekday][calendar.component(.hour, from: bucket)] += seconds / 60
            }
        }

        stats.agents = shares(turns, key: \.pillId, start: start, now: now)
        stats.projects = shares(turns.filter { !$0.project.isEmpty }, key: \.project, start: start, now: now)

        // Approvals.
        stats.allowed = decisions.filter { $0.decision == "allow" }.count
        stats.always = decisions.filter { $0.decision == "always" }.count
        stats.denied = decisions.filter { $0.decision == "deny" }.count
        let waits = decisions.compactMap(\.waitSeconds)
        stats.averageWaitSeconds = waits.isEmpty ? nil : waits.reduce(0, +) / Double(waits.count)
        var counts: [String: CommandCount] = [:]
        for d in decisions where d.decision != "ask" {
            guard let label = commandLabel(tool: d.tool, command: d.command) else { continue }
            var c = counts[label] ?? CommandCount(command: label, approved: 0, denied: 0)
            if d.decision == "deny" { c.denied += 1 } else { c.approved += 1 }
            counts[label] = c
        }
        stats.commands = counts.values.sorted { ($0.approved, $1.command) > ($1.approved, $0.command) }

        stats.sessions = sessions(from: turns).sorted { $0.end > $1.end }
        stats.sessionCount = stats.sessions.count
        stats.records = records(turns: allTurns, now: now, calendar: calendar)
        return stats
    }

    /// "git status" → "git status", "cd app && npm test" → "npm test", Edit → "Edit".
    static func commandLabel(tool: String?, command: String?) -> String? {
        guard let tool, !tool.isEmpty else { return nil }
        guard tool == "Bash" || tool == "Execute", let command else { return tool }
        let segment = command
            .components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("cd ") } ?? command
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return tool }
        // These are only half a command without their subcommand.
        let twoWord: Set<String> = ["git", "npm", "npx", "pnpm", "yarn", "bun", "cargo", "go", "swift",
                                    "docker", "kubectl", "make", "brew", "gh", "uv", "pip", "pip3",
                                    "xcodebuild", "python", "python3", "node", "deno"]
        if twoWord.contains(first), words.count > 1, !words[1].hasPrefix("-") { return "\(first) \(words[1])" }
        return first
    }

    static func sessions(from turns: [RecapTurn]) -> [Session] {
        var groups: [String: [RecapTurn]] = [:]
        for turn in turns { if let id = turn.sessionId { groups[id, default: []].append(turn) } }
        // Turns recorded before sessions were kept: same agent and project, less than
        // 30 minutes apart, count as one session.
        var legacyEnd: [String: Date] = [:]
        var legacyIndex: [String: Int] = [:]
        for turn in turns.filter({ $0.sessionId == nil }).sorted(by: { $0.start < $1.start }) {
            let base = "legacy|\(turn.pillId)|\(turn.project)"
            if let end = legacyEnd[base], turn.start.timeIntervalSince(end) <= 30 * 60 {
                legacyEnd[base] = max(end, turn.end)
            } else {
                legacyIndex[base, default: -1] += 1
                legacyEnd[base] = turn.end
            }
            groups["\(base)|\(legacyIndex[base]!)", default: []].append(turn)
        }
        return groups.map { id, turns in
            let sorted = turns.sorted { $0.start < $1.start }
            let waiting = turns.reduce(0) { $0 + ($1.waitSeconds ?? 0) }
            let busy = turns.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            var files: [String: Int] = [:]
            for turn in turns { for (name, lines) in turn.files ?? [:] { files[name, default: 0] += lines } }
            return Session(
                id: id,
                pillId: sorted.last?.pillId ?? "",
                project: sorted.last?.project ?? "",
                start: sorted.first?.start ?? Date(),
                end: sorted.map(\.end).max() ?? Date(),
                turns: turns.count,
                workingSeconds: max(0, busy - waiting),
                waitingSeconds: waiting,
                added: turns.reduce(0) { $0 + $1.linesAdded },
                removed: turns.reduce(0) { $0 + $1.linesRemoved },
                topFiles: files.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map { ($0.key, $0.value) }
            )
        }
    }

    static func records(turns: [RecapTurn], now: Date, calendar: Calendar) -> Records {
        var records = Records()
        let days = Set(turns.map { calendar.startOfDay(for: $0.start) })
        // Today still counts as on the streak until it's over.
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        while days.contains(day) {
            records.currentStreak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var run = 0
        var previous: Date?
        for d in days.sorted() {
            if let p = previous, calendar.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            records.longestStreak = max(records.longestStreak, run)
            previous = d
        }

        let all = sessions(from: turns)
        records.longestSession = all.max { $0.duration < $1.duration }
        records.biggestDiff = all.filter { $0.diffSize > 0 }.max { $0.diffSize < $1.diffSize }

        var minutesByDay: [Date: Double] = [:]
        for interval in mergeIntervals(turns.filter { $0.end > $0.start }.map { ($0.start, $0.end) }) {
            for (bucket, seconds) in split(interval, by: .day, calendar: calendar) { minutesByDay[bucket, default: 0] += seconds / 60 }
        }
        records.busiestDay = minutesByDay.max { $0.value < $1.value }.map { Day(date: $0.key, minutes: $0.value) }
        return records
    }

    // MARK: - Helpers

    private static func shares(_ turns: [RecapTurn], key: KeyPath<RecapTurn, String>, start: Date, now: Date) -> [Share] {
        Dictionary(grouping: turns, by: { $0[keyPath: key] }).map { k, group in
            let merged = mergeIntervals(group.map { (max($0.start, start), min($0.end, now)) })
            return Share(key: k, minutes: merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 60, turns: group.count)
        }
        .sorted { ($0.minutes, $1.key) > ($1.minutes, $0.key) }
    }

    static func mergeIntervals(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        var merged: [(Date, Date)] = []
        for (s, e) in intervals.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, s <= last.1 {
                merged[merged.count - 1].1 = max(last.1, e)
            } else {
                merged.append((s, e))
            }
        }
        return merged
    }

    /// The seconds of an interval in each day or hour it touches, keyed by the bucket's start.
    static func split(_ interval: (Date, Date), by unit: Calendar.Component, calendar: Calendar) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        var cursor = interval.0
        while cursor < interval.1 {
            guard let bucket = calendar.dateInterval(of: unit, for: cursor) else { break }
            let end = min(bucket.end, interval.1)
            out.append((bucket.start, end.timeIntervalSince(cursor)))
            cursor = end
        }
        return out
    }
}

// MARK: - Plan usage forecast

struct PlanSample: Codable, Equatable {
    var date: Date
    var pct: Double
    var resetsAt: Date?
}

enum PlanForecast: Equatable {
    /// At this pace the limit is reached before the window resets.
    case hitsLimit(at: Date)
    /// The window resets before the limit (resetsAt nil when the provider didn't say).
    case resetsFirst(at: Date?)
    case notEnoughData

    /// The length of a usage window, from its label ("5h", "Week").
    static func windowLength(_ label: String) -> TimeInterval? {
        switch label {
        case "5h":   return 5 * 3600
        case "Week": return 7 * 86400
        default:     return nil
        }
    }

    /// The pace over the last stretch of the current window (90 minutes for 5 h, a day for the week),
    /// carried forward in a straight line.
    static func make(samples: [PlanSample], current: Double, resetsAt: Date?, label: String, now: Date = Date()) -> PlanForecast {
        if current >= 100 { return .hitsLimit(at: now) }
        let length = windowLength(label) ?? 7 * 86400
        let lookback: TimeInterval = length <= 5 * 3600 ? 90 * 60 : 86400
        var from = now.addingTimeInterval(-lookback)
        if let resetsAt { from = max(from, resetsAt.addingTimeInterval(-length)) }
        let recent = samples.filter { $0.date >= from && $0.date <= now }
        guard let first = recent.first, let last = recent.last,
              last.date.timeIntervalSince(first.date) >= 10 * 60 else { return .notEnoughData }

        // Least squares slope, in percent per second.
        let t0 = first.date.timeIntervalSince1970
        let xs = recent.map { $0.date.timeIntervalSince1970 - t0 }
        let ys = recent.map(\.pct)
        let n = Double(recent.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let den = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard den > 0 else { return .notEnoughData }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / den
        guard slope > 0 else { return .resetsFirst(at: resetsAt) }

        let hit = now.addingTimeInterval((100 - current) / slope)
        if let resetsAt, hit >= resetsAt { return .resetsFirst(at: resetsAt) }
        return .hitsLimit(at: hit)
    }
}
