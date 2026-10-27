#if !APPSTORE
import Charts
import SwiftUI

/// The Stats page of the Coucou window: what your agents did, your plan usage and memory.
/// Everything is read from files on this Mac (RecapStore, PlanHistory), nothing is sent.
struct HubStatsPage: View {
    @AppStorage("hubStatsPeriod") private var period: StatsPeriod = .week
    @State private var stats = AgentStats()
    @ObservedObject private var plans = PlanHistory.shared
    @ObservedObject private var memory = MemoryMonitor.shared
    @ObservedObject private var usage = AIUsageMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("", selection: $period) {
                        ForEach(StatsPeriod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    Spacer()
                    Button {
                        reload()
                        usage.refresh(force: true, ignoringPillState: true)
                    } label: {
                        Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }

                tiles
                if stats.hasData {
                    HStack(alignment: .top, spacing: 14) {
                        StatsCard(title: String(localized: "Coding time per day")) { TimeChart(days: stats.days) }
                        StatsCard(title: String(localized: "Lines added and removed")) { LinesChart(days: stats.days) }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        StatsCard(title: String(localized: "By agent")) {
                            ShareList(shares: stats.agents, name: Self.agentName, color: Self.agentColor)
                        }
                        StatsCard(title: String(localized: "By project")) {
                            ShareList(shares: stats.projects, name: { $0 }, color: { _ in HubTheme.accent })
                        }
                    }
                    StatsCard(title: String(localized: "When you code")) { Heatmap(values: stats.heatmap) }
                    ApprovalsCard(stats: stats)
                } else {
                    StatsCard(title: String(localized: "Agents")) {
                        Text("No agent activity in this period yet. Coucou counts each turn of Claude Code, Codex and your other agents once it ends.")
                            .font(.system(size: 13))
                            .foregroundColor(HubTheme.secondary)
                    }
                }
                RecordsCard(records: stats.records)
                PlanUsageCard(plans: plans, usage: usage)
                if !stats.sessions.isEmpty { SessionsCard(sessions: stats.sessions) }
                MemoryCard(memory: memory)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .onAppear {
            reload()
            memory.start()
            usage.refresh(ignoringPillState: true)
        }
        .onDisappear { memory.stop() }
        .onChange(of: period) { _, _ in reload() }
    }

    private func reload() {
        stats = AgentStats.compute(turns: RecapStore.shared.allTurns,
                                   decisions: RecapStore.shared.allDecisions, period: period)
    }

    private var tiles: some View {
        HStack(spacing: 14) {
            StatTile(label: String(localized: "Coding time"), value: Self.duration(minutes: stats.activeMinutes),
                     note: HubStatsPage.count(stats.turnCount, String(localized: "turn"), String(localized: "turns")))
            StatTile(label: String(localized: "Sessions"), value: "\(stats.sessionCount)",
                     note: String(localized: "\(stats.commandsRun) commands run"))
            StatTile(label: String(localized: "Lines"), value: "+\(stats.added.formatted()) −\(stats.removed.formatted())",
                     note: String(localized: "\(stats.filesChanged) files changed"))
            StatTile(label: String(localized: "Streak"), value: HubStatsPage.days(stats.records.currentStreak),
                     note: String(localized: "Best: \(HubStatsPage.days(stats.records.longestStreak))"))
        }
    }

    // MARK: - Formatting

    static func agentName(_ id: String) -> String { PillCatalog.definition(for: id)?.name ?? id }
    static func agentColor(_ id: String) -> Color { Color(hex: PillCatalog.definition(for: id)?.defaultColor ?? "#FB923C") }

    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return String(localized: "\(total) min") }
        if total % 60 == 0 { return String(localized: "\(total / 60) h") }
        return String(localized: "\(total / 60) h \(total % 60) min")
    }

    static func duration(seconds: Double) -> String {
        seconds < 60 ? String(localized: "\(Int(seconds.rounded())) s") : duration(minutes: seconds / 60)
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n == 1 ? one : many)"
    }

    static func days(_ n: Int) -> String { count(n, String(localized: "day"), String(localized: "days")) }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

// MARK: - Building blocks

private struct StatsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(HubTheme.body)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(HubTheme.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundColor(HubTheme.muted)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
        .accessibilityElement(children: .combine)
    }
}

private struct TimeChart: View {
    let days: [AgentStats.Day]

    var body: some View {
        Chart(days) { day in
            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes))
                .foregroundStyle(HubTheme.accent)
                .cornerRadius(3)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(HubTheme.line)
                AxisValueLabel { if let m = value.as(Double.self) { Text(HubStatsPage.duration(minutes: m)) } }
            }
        }
        .chartXAxis { dayAxis(days.count) }
        .frame(height: 160)
    }
}

private struct LinesChart: View {
    let days: [AgentStats.Day]

    var body: some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Lines", day.added))
                    .foregroundStyle(HubTheme.green)
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Lines", -day.removed))
                    .foregroundStyle(HubTheme.red)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(HubTheme.line)
                AxisValueLabel { if let n = value.as(Int.self) { Text(abs(n).formatted(.number.notation(.compactName))) } }
            }
        }
        .chartXAxis { dayAxis(days.count) }
        .frame(height: 160)
    }
}

private func dayAxis(_ count: Int) -> some AxisContent {
    AxisMarks(values: .stride(by: .day, count: count > 10 ? 5 : 1)) { _ in
        AxisValueLabel(format: count == 1 ? .dateTime.hour() : .dateTime.weekday(.abbreviated).day())
    }
}

private struct ShareList: View {
    let shares: [AgentStats.Share]
    let name: (String) -> String
    let color: (String) -> Color

    var body: some View {
        let total = max(1, shares.reduce(0) { $0 + $1.minutes })
        VStack(alignment: .leading, spacing: 10) {
            if shares.isEmpty {
                Text("Nothing yet").font(.system(size: 12.5)).foregroundColor(HubTheme.muted)
            }
            ForEach(shares.prefix(6)) { share in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name(share.key)).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text(HubStatsPage.duration(minutes: share.minutes))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundColor(HubTheme.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill(HubTheme.field)
                            .overlay(alignment: .leading) {
                                Capsule().fill(color(share.key))
                                    .frame(width: max(4, geo.size.width * share.minutes / total))
                            }
                    }
                    .frame(height: 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name(share.key)), \(HubStatsPage.duration(minutes: share.minutes)), \(HubStatsPage.count(share.turns, String(localized: "turn"), String(localized: "turns")))")
            }
        }
    }
}

private struct Heatmap: View {
    let values: [[Double]]

    private static let weekdays: [String] = {
        var cal = Calendar.current
        cal.locale = .current
        // Monday first, like the data.
        let symbols = cal.shortWeekdaySymbols
        return Array(symbols[1...] + symbols[..<1])
    }()

    var body: some View {
        let top = max(1, values.flatMap { $0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 3) {
                    Text(Self.weekdays[day])
                        .font(.system(size: 10.5))
                        .foregroundColor(HubTheme.muted)
                        .frame(width: 34, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let v = values[day][hour]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(v > 0 ? HubTheme.accent.opacity(0.18 + 0.82 * v / top) : HubTheme.field)
                            .frame(height: 16)
                            .help("\(Self.weekdays[day]) \(hour):00 — \(HubStatsPage.duration(minutes: v))")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.summary(day: day, row: values[day]))
            }
            HStack(spacing: 3) {
                Color.clear.frame(width: 34, height: 1)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.system(size: 9.5))
                        .foregroundColor(HubTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// For VoiceOver: the day's total and its busiest hour.
    private static func summary(day: Int, row: [Double]) -> String {
        let total = row.reduce(0, +)
        guard total > 0, let peak = row.indices.max(by: { row[$0] < row[$1] }) else {
            return "\(weekdays[day]): " + String(localized: "no activity")
        }
        return "\(weekdays[day]): \(HubStatsPage.duration(minutes: total)), " + String(localized: "busiest at \(peak):00")
    }
}

// MARK: - Approvals

private struct ApprovalsCard: View {
    let stats: AgentStats

    var body: some View {
        StatsCard(title: String(localized: "Approvals")) {
            HStack(spacing: 24) {
                figure(String(localized: "Allowed"), stats.allowed, HubTheme.green)
                figure(String(localized: "Always"), stats.always, HubTheme.accent)
                figure(String(localized: "Denied"), stats.denied, HubTheme.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats.averageWaitSeconds.map { HubStatsPage.duration(seconds: $0) } ?? "—")
                        .font(.system(size: 20, weight: .bold))
                    Text("Average wait for you").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
            }
            if !stats.commands.isEmpty {
                Divider().overlay(HubTheme.line)
                Text("Most approved").font(.system(size: 12, weight: .medium)).foregroundColor(HubTheme.secondary)
                ForEach(stats.commands.prefix(8)) { c in
                    HStack(spacing: 8) {
                        Text(c.command)
                            .font(.system(size: 12.5, design: .monospaced))
                            .lineLimit(1)
                        if c.suggestsAlways {
                            Text("Could be on Always")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(HubTheme.onAccent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(HubTheme.accent))
                                .help(String(localized: "You approved this every time. Choose Always next time it asks, so it stops waiting on you."))
                        }
                        Spacer()
                        Text("\(c.approved) ✓").foregroundColor(HubTheme.green)
                        if c.denied > 0 { Text("\(c.denied) ✕").foregroundColor(HubTheme.red) }
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func figure(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 20, weight: .bold)).foregroundColor(color)
            Text(label).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Records

private struct RecordsCard: View {
    let records: AgentStats.Records

    var body: some View {
        StatsCard(title: String(localized: "Streaks and records")) {
            HStack(alignment: .top, spacing: 14) {
                record(String(localized: "Current streak"), HubStatsPage.days(records.currentStreak), nil)
                record(String(localized: "Longest streak"), HubStatsPage.days(records.longestStreak), nil)
                record(String(localized: "Longest session"),
                       records.longestSession.map { HubStatsPage.duration(seconds: $0.duration) } ?? "—",
                       records.longestSession.map(caption))
                record(String(localized: "Biggest diff"),
                       records.biggestDiff.map { "+\($0.added.formatted()) −\($0.removed.formatted())" } ?? "—",
                       records.biggestDiff.map(caption))
                record(String(localized: "Busiest day"),
                       records.busiestDay.map { HubStatsPage.duration(minutes: $0.minutes) } ?? "—",
                       records.busiestDay.map { $0.date.formatted(date: .abbreviated, time: .omitted) })
            }
        }
    }

    private func caption(_ s: AgentStats.Session) -> String {
        let name = s.project.isEmpty ? HubStatsPage.agentName(s.pillId) : s.project
        return "\(name) · \(s.start.formatted(date: .abbreviated, time: .omitted))"
    }

    private func record(_ label: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
            Text(value).font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            if let note { Text(note).font(.system(size: 11)).foregroundColor(HubTheme.muted).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Plan usage

private struct PlanUsageCard: View {
    @ObservedObject var plans: PlanHistory
    @ObservedObject var usage: AIUsageMonitor
    @AppStorage(PlanHistory.alertKey) private var alerts = true

    var body: some View {
        let providers = [usage.claude, usage.codex].compactMap { $0 }.filter { !$0.windows.isEmpty }
        StatsCard(title: String(localized: "Plan usage")) {
            if providers.isEmpty {
                Text("No plan usage read yet. Open Claude Desktop, or turn on Plan usage in Agents, and the readings will show here.")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
            }
            ForEach(providers, id: \.name) { provider in
                ForEach(provider.windows, id: \.label) { window in
                    PlanWindowRow(provider: provider.name, window: window,
                                  samples: plans.samples(provider: provider.name, window: window.label))
                }
            }
            Toggle(String(localized: "Warn me at 80 %"), isOn: $alerts)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5))
        }
    }
}

private struct PlanWindowRow: View {
    let provider: String
    let window: UsageWindow
    let samples: [PlanSample]

    var body: some View {
        let now = Date()
        let pct = window.effectivePct(at: now)
        let length = PlanForecast.windowLength(window.label) ?? 7 * 86400
        // The current window, or the last day of the week's.
        let from = now.addingTimeInterval(-min(length, 86400))
        let shown = samples.filter { $0.date >= from }
        let forecast = PlanForecast.make(samples: samples, current: pct, resetsAt: window.resetsAt, label: window.label, now: now)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(provider) · \(window.label == "5h" ? String(localized: "5 hours") : String(localized: "Week"))")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("\(Int(pct.rounded())) %")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundColor(Color(hex: ClaudePlanGauge.color(for: pct)))
            }
            if shown.count >= 2 {
                Chart {
                    ForEach(shown, id: \.date) { s in
                        LineMark(x: .value("Time", s.date), y: .value("Used", s.pct))
                            .foregroundStyle(HubTheme.accent)
                            .interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Alert", PlanHistory.alertThreshold))
                        .foregroundStyle(HubTheme.red.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 80, 100]) { value in
                        AxisGridLine().foregroundStyle(HubTheme.line)
                        AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
                    }
                }
                .frame(height: 90)
                .accessibilityLabel(String(localized: "\(provider) usage over time"))
            }
            Text(Self.describe(forecast))
                .font(.system(size: 12))
                .foregroundColor(forecastIsBad(forecast) ? HubTheme.red : HubTheme.secondary)
        }
        .padding(.vertical, 4)
    }

    private func forecastIsBad(_ f: PlanForecast) -> Bool {
        if case .hitsLimit = f { return true }
        return false
    }

    static func describe(_ forecast: PlanForecast) -> String {
        func time(_ d: Date) -> String {
            d.formatted(date: Calendar.current.isDateInToday(d) ? .omitted : .abbreviated, time: .shortened)
        }
        switch forecast {
        case .hitsLimit(let at):
            return at <= Date().addingTimeInterval(60)
                ? String(localized: "You've reached the limit.")
                : String(localized: "At this pace you'll hit the limit at about \(time(at)).")
        case .resetsFirst(let at?):
            return String(localized: "At this pace it resets at \(time(at)) before you hit the limit.")
        case .resetsFirst(nil):
            return String(localized: "At this pace you won't hit the limit.")
        case .notEnoughData:
            return String(localized: "A forecast shows once Coucou has a few readings.")
        }
    }
}

// MARK: - Sessions

private struct SessionsCard: View {
    let sessions: [AgentStats.Session]
    @State private var open: String?

    var body: some View {
        StatsCard(title: String(localized: "Sessions")) {
            ForEach(sessions.prefix(15)) { s in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { open = open == s.id ? nil : s.id }
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(HubStatsPage.agentColor(s.pillId)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.project.isEmpty ? HubStatsPage.agentName(s.pillId) : s.project)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(HubStatsPage.agentName(s.pillId)) · \(s.start.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundColor(HubTheme.muted)
                            }
                            Spacer()
                            Text(HubStatsPage.duration(seconds: s.duration))
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                            Text(HubStatsPage.count(s.turns, String(localized: "turn"), String(localized: "turns"))).font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                            Image(systemName: open == s.id ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(HubTheme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(s.project), \(HubStatsPage.duration(seconds: s.duration)), \(HubStatsPage.count(s.turns, String(localized: "turn"), String(localized: "turns")))")
                    .accessibilityHint(String(localized: "Shows the session's details"))

                    if open == s.id { detail(s) }
                }
                .padding(.vertical, 4)
                if s.id != sessions.prefix(15).last?.id { Divider().overlay(HubTheme.line) }
            }
        }
    }

    private func detail(_ s: AgentStats.Session) -> some View {
        let total = max(1, s.workingSeconds + s.waitingSeconds)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(HubTheme.accent).frame(width: max(2, geo.size.width * s.workingSeconds / total))
                    Capsule().fill(HubTheme.secondary.opacity(0.5))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            HStack(spacing: 18) {
                Label(String(localized: "Working \(HubStatsPage.duration(seconds: s.workingSeconds))"), systemImage: "bolt.fill")
                    .foregroundColor(HubTheme.accent)
                Label(String(localized: "Waiting on you \(HubStatsPage.duration(seconds: s.waitingSeconds))"), systemImage: "hourglass")
                    .foregroundColor(HubTheme.secondary)
                Text("+\(s.added) −\(s.removed)").foregroundColor(HubTheme.body)
            }
            .font(.system(size: 12))
            if !s.topFiles.isEmpty {
                Text("Files touched most").font(.system(size: 11.5, weight: .medium)).foregroundColor(HubTheme.secondary)
                ForEach(s.topFiles, id: \.name) { f in
                    HStack {
                        Text(f.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(HubStatsPage.count(f.lines, String(localized: "line"), String(localized: "lines"))).font(.system(size: 11.5).monospacedDigit()).foregroundColor(HubTheme.muted)
                    }
                }
            }
        }
        .padding(.leading, 18)
    }
}

// MARK: - Memory

private struct MemoryCard: View {
    @ObservedObject var memory: MemoryMonitor

    var body: some View {
        StatsCard(title: String(localized: "Memory")) {
            HStack(alignment: .top, spacing: 14) {
                big(String(localized: "Last app you used"), memory.lastApp)
                big(String(localized: "Coucou"), memory.own)
                if let system = memory.system {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This Mac").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                        Text(HubStatsPage.bytes(system.used)).font(.system(size: 20, weight: .bold))
                        Text(String(localized: "of \(HubStatsPage.bytes(system.total)) used"))
                            .font(.system(size: 11)).foregroundColor(HubTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if !memory.apps.isEmpty {
                Divider().overlay(HubTheme.line)
                Text("Apps using the most").font(.system(size: 12, weight: .medium)).foregroundColor(HubTheme.secondary)
                let top = Double(memory.apps.first?.bytes ?? 1)
                ForEach(memory.apps.prefix(6)) { app in
                    HStack(spacing: 10) {
                        Text(app.name).font(.system(size: 12.5)).lineLimit(1).frame(width: 160, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(app.bundleID == memory.lastAppBundleID ? HubTheme.accent : HubTheme.secondary.opacity(0.6))
                                .frame(width: max(4, geo.size.width * Double(app.bytes) / top))
                        }
                        .frame(height: 6)
                        Text(HubStatsPage.bytes(app.bytes))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(app.name), \(HubStatsPage.bytes(app.bytes))")
                }
            }
        }
    }

    private func big(_ label: String, _ app: AppMemory?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
            Text(app.map { HubStatsPage.bytes($0.bytes) } ?? "—").font(.system(size: 20, weight: .bold))
            if let app {
                Text(app.processes > 1 ? String(localized: "\(app.name) · \(app.processes) processes") : app.name)
                    .font(.system(size: 11)).foregroundColor(HubTheme.muted).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
