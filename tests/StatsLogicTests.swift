import Foundation

@main
enum StatsLogicTests {

    static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Wednesday 2026-10-28 18:00 UTC
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 18))!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        func turn(_ s: Date, _ e: Date, pill: String = "integration_claude", project: String = "app",
                  session: String? = "s1", added: Int = 0, removed: Int = 0, wait: Double? = nil,
                  files: [String: Int]? = nil) -> RecapTurn {
            RecapTurn(pillId: pill, project: project, start: s, end: e, filesChanged: files?.count ?? 0,
                      linesAdded: added, linesRemoved: removed, commandsRun: 0, questions: 0,
                      sessionId: session, files: files, waitSeconds: wait)
        }

        print("Time merging and per-day buckets")
        do {
            // Two overlapping turns in different sessions: 10:00–11:00 and 10:30–11:30 → 90 min.
            let turns = [turn(at(28, 10), at(28, 11), session: "a", added: 10),
                         turn(at(28, 10, 30), at(28, 11, 30), pill: "agent_codex", session: "b", removed: 4)]
            let s = AgentStats.compute(turns: turns, decisions: [], period: .week, now: now, calendar: cal)
            check("90 active minutes", near(s.activeMinutes, 90))
            check("7 day bars", s.days.count == 7)
            check("today holds the minutes", near(s.days.last!.minutes, 90))
            check("two sessions", s.sessionCount == 2)
            check("each agent 60 min", s.agents.count == 2 && s.agents.allSatisfy { near($0.minutes, 60) })
            check("heatmap Wed 10h = 60", near(s.heatmap[2][10], 60))
            check("heatmap Wed 11h = 30", near(s.heatmap[2][11], 30))
            check("lines on today", s.days.last!.added == 10 && s.days.last!.removed == 4)
        }

        print("Turn across midnight")
        do {
            let turns = [turn(at(27, 23, 30), at(28, 0, 30))]
            let s = AgentStats.compute(turns: turns, decisions: [], period: .week, now: now, calendar: cal)
            check("30 min yesterday", near(s.days[5].minutes, 30))
            check("30 min today", near(s.days[6].minutes, 30))
        }

        print("Today period cuts older work")
        do {
            let turns = [turn(at(27, 10), at(27, 12)), turn(at(28, 9), at(28, 9, 20))]
            let s = AgentStats.compute(turns: turns, decisions: [], period: .today, now: now, calendar: cal)
            check("20 min today", near(s.activeMinutes, 20))
            check("1 turn", s.turnCount == 1)
        }

        print("Sessions: working vs waiting, top files")
        do {
            let turns = [turn(at(28, 10), at(28, 10, 10), wait: 120, files: ["a.swift": 30, "b.swift": 5]),
                         turn(at(28, 10, 20), at(28, 10, 30), wait: 60, files: ["a.swift": 10])]
            let session = AgentStats.sessions(from: turns).first!
            check("2 turns", session.turns == 2)
            check("30 min long", near(session.duration, 1800))
            check("waiting 180 s", near(session.waitingSeconds, 180))
            check("working 1020 s", near(session.workingSeconds, 1020))
            check("a.swift first with 40", session.topFiles.first?.name == "a.swift" && session.topFiles.first?.lines == 40)
        }

        print("Legacy turns without a session stand alone")
        do {
            let turns = [turn(at(28, 10), at(28, 11), session: nil), turn(at(28, 12), at(28, 13), session: nil)]
            check("an hour apart → 2 sessions", AgentStats.sessions(from: turns).count == 2)
            let close = [turn(at(28, 10), at(28, 10, 5), session: nil), turn(at(28, 10, 20), at(28, 10, 30), session: nil),
                         turn(at(28, 10, 25), at(28, 10, 40), project: "other", session: nil)]
            let grouped = AgentStats.sessions(from: close)
            check("close turns of one project merge", grouped.count == 2 && grouped.contains { $0.turns == 2 && $0.project == "app" })
        }

        print("Streaks and records")
        do {
            // Days 24, 25, 26 and 27, 28 (today): one 5-day run; plus day 20 alone.
            let days = [20, 24, 25, 26, 27, 28]
            let turns = days.map { turn(at($0, 9), at($0, 10), session: "d\($0)", added: $0 == 25 ? 500 : 1) }
            let r = AgentStats.records(turns: turns, now: now, calendar: cal)
            check("current streak 5", r.currentStreak == 5)
            check("longest streak 5", r.longestStreak == 5)
            check("biggest diff on the 25th", r.biggestDiff?.id == "d25")
            // No work today yet: yesterday's streak still counts.
            let r2 = AgentStats.records(turns: Array(turns.dropLast()), now: now, calendar: cal)
            check("streak kept until today ends", r2.currentStreak == 4)
            let r3 = AgentStats.records(turns: [turn(at(20, 9), at(20, 10))], now: now, calendar: cal)
            check("old work → streak 0", r3.currentStreak == 0 && r3.longestStreak == 1)
        }

        print("Approvals and command labels")
        do {
            check("git subcommand", AgentStats.commandLabel(tool: "Bash", command: "git status -s") == "git status")
            check("cd prefix dropped", AgentStats.commandLabel(tool: "Bash", command: "cd app && npm test") == "npm test")
            check("flag not a subcommand", AgentStats.commandLabel(tool: "Bash", command: "git --version") == "git")
            check("plain tool", AgentStats.commandLabel(tool: "Edit", command: "/a/b.swift") == "Edit")
            var decisions = (0..<5).map { i in
                RecapDecision(pillId: "integration_claude", date: at(28, 10, i), decision: "allow",
                              tool: "Bash", command: "npm test", waitSeconds: 10)
            }
            decisions.append(RecapDecision(pillId: "integration_claude", date: at(28, 11), decision: "deny",
                                           tool: "Bash", command: "rm -rf build", waitSeconds: 40))
            decisions.append(RecapDecision(pillId: "integration_claude", date: at(1, 11), decision: "allow"))
            let s = AgentStats.compute(turns: [], decisions: decisions, period: .week, now: now, calendar: cal)
            check("5 allowed in the week", s.allowed == 5)
            check("1 denied", s.denied == 1)
            check("average wait 15 s", near(s.averageWaitSeconds ?? 0, 15))
            check("npm test suggests Always", s.commands.first?.command == "npm test" && s.commands.first!.suggestsAlways)
            check("rm not suggested", s.commands.first { $0.command == "rm" }?.suggestsAlways == false)
        }

        print("Plan forecast")
        do {
            let t = now
            // +10 % per 30 min, at 50 % now → 100 % in 2.5 h; reset in 4 h.
            let samples = (0...3).map { i in PlanSample(date: t.addingTimeInterval(Double(i - 3) * 600), pct: 45 + Double(i) * 10 / 3) }
            let f = PlanForecast.make(samples: samples, current: 50, resetsAt: t.addingTimeInterval(4 * 3600), label: "5h", now: t)
            if case .hitsLimit(let at) = f { check("hits in ~2.5 h", near(at.timeIntervalSince(t), 9000, 60)) }
            else { check("hits the limit", false) }
            let f2 = PlanForecast.make(samples: samples, current: 50, resetsAt: t.addingTimeInterval(3600), label: "5h", now: t)
            check("resets first", f2 == .resetsFirst(at: t.addingTimeInterval(3600)))
            let flat = samples.map { PlanSample(date: $0.date, pct: 50) }
            check("flat → resets first",
                  PlanForecast.make(samples: flat, current: 50, resetsAt: nil, label: "5h", now: t) == .resetsFirst(at: nil))
            check("one sample → not enough",
                  PlanForecast.make(samples: [samples[0]], current: 50, resetsAt: nil, label: "5h", now: t) == .notEnoughData)
            check("at 100 → now",
                  PlanForecast.make(samples: [], current: 100, resetsAt: nil, label: "Week", now: t) == .hitsLimit(at: t))
        }

        print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

// RecapStore's weekly summary names the top agent from the catalog.
struct PillCatalogStubDefinition { let name: String }
enum PillCatalog { static func definition(for id: String) -> PillCatalogStubDefinition? { nil } }
