#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - AI Usage pill (overview right card)

/// Mochi plus one coloured figure per provider: Claude, Codex, Antigravity.
struct UsagePill: View {
    let task: AgentTask
    @Binding var swapping: Bool
    let onTap: () -> Void
    @ObservedObject private var monitor = AIUsageMonitor.shared
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(isHovered ? Color(hex: task.color).opacity(0.18) : Color(hex: "#0E0F11"))
            Capsule()
                .stroke(Color(hex: task.color).opacity(isHovered ? 0.55 : 0.14), lineWidth: 1)

            HStack(spacing: 0) {
                MiniBotCanvasView(task: task, isDancing: false)
                    .frame(width: 22 / 0.6, height: 22 / 0.6)
                    .frame(width: 22, height: 22, alignment: .center)
                    .padding(.leading, 8)
                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(AIUsageProvider.allCases, id: \.self) { p in
                    HStack(spacing: 2) {
                        Circle().fill(Color(hex: p.color)).frame(width: 5, height: 5)
                        Text(monitor.pct(p).map { "\(Int(monitor.shown($0).rounded()))" } ?? "—")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(isHovered ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 30)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .shadow(color: Color(hex: task.color).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .help(AIUsageProvider.allCases.map { p in
            "\(p.title): \(monitor.pct(p).map { "\(Int(monitor.shown($0).rounded()))%" } ?? "—")\(monitor.showRemaining ? " left" : " used")"
        }.joined(separator: " · "))
        .onHover { newHover in
            guard !swapping else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
    }
}

// MARK: - AI Usage card (overview left card)

struct UsageCardView: View {
    @ObservedObject private var monitor = AIUsageMonitor.shared
    @State private var now = Date()

    private struct Row: Identifiable {
        let id: String
        let provider: AIUsageProvider
        let label: String
        let usage: ProviderUsage?
    }

    /// Claude, Codex, then one row per Antigravity model group.
    private var rows: [Row] {
        var rows = [Row(id: "claude", provider: .claude, label: "Claude", usage: monitor.claude),
                    Row(id: "codex", provider: .codex, label: "Codex", usage: monitor.codex)]
        if monitor.antigravity.isEmpty {
            rows.append(Row(id: "ag", provider: .antigravity, label: "Antigravity", usage: nil))
        } else if monitor.antigravity.count == 1, monitor.antigravity[0].windows.isEmpty {
            rows.append(Row(id: "ag", provider: .antigravity, label: "Antigravity", usage: monitor.antigravity[0]))
        } else {
            for g in monitor.antigravity.prefix(2) {
                rows.append(Row(id: "ag-\(g.name)", provider: .antigravity, label: "AG \(g.name.split(separator: "/").first.map(String.init) ?? g.name)", usage: g))
            }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: ClaudePlanGauge.color(for: monitor.dominantPct)))
                    .frame(width: 7, height: 7)
                Text("AI Usage")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(monitor.showRemaining ? "left" : "used")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .fixedSize()
                Button(action: { monitor.refresh(force: true) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NowPlayingPressStyle())
                .help("Refresh now · updated \(subtitle)")
                // Flip between what's used and what's left
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { monitor.showRemaining.toggle() }
                }) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: monitor.showRemaining ? "#F5F6F8" : "#6B7079"))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NowPlayingPressStyle())
                .help(monitor.showRemaining ? "Showing what's left · show used" : "Showing what's used · show what's left")
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.trailing, 36)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    UsageRowView(provider: row.provider, label: row.label, usage: row.usage, now: now,
                                 showRemaining: monitor.showRemaining)
                }
            }
            .padding(.top, 6)
        }
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .onAppear { monitor.refresh() }
        // Countdowns tick every 30 s, only while the card is on screen
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitle: String {
        guard let last = monitor.lastRefresh else { return "Reading…" }
        let mins = Int(now.timeIntervalSince(last) / 60)
        return mins < 1 ? "just now" : "\(mins) min ago"
    }
}

/// One provider: name, 5-hour bar, weekly bar (resets on hover). Click: its usage page.
struct UsageRowView: View {
    let provider: AIUsageProvider
    let label: String
    let usage: ProviderUsage?
    let now: Date
    var showRemaining = false
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: provider.color)).frame(width: 5, height: 5)
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: hovered ? "#F5F6F8" : "#C5C8CD"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: 80, alignment: .leading)

                if let usage, !usage.windows.isEmpty {
                    let five = usage.window("5h")
                    let week = usage.window("Week") ?? (five == nil ? usage.windows.first : nil)
                    bar(five)
                    bar(week)
                } else {
                    Text(usage?.message ?? "Reading…")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tooltip)
    }

    /// Bar and figure; the reset time is in the row's tooltip (the card is ~215 pt wide).
    private func bar(_ w: UsageWindow?) -> some View {
        let used = w?.effectivePct(at: now)
        // Colour always follows use (red = near the limit); the bar and figure follow the mode.
        let accent = Color(hex: ClaudePlanGauge.color(for: used))
        let pct = used.map { showRemaining ? max(0, 100 - $0) : $0 }
        return HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 22, height: 4)
                Capsule().fill(accent).frame(width: max(0, 22 * CGFloat((pct ?? 0) / 100)), height: 4)
            }
            .frame(width: 22, height: 4)
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(hex: "#C5C8CD"))
                .fixedSize()
                .frame(width: 28, alignment: .leading)
        }
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let secs = Int(date.timeIntervalSince(now))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(1, m))m"
    }

    private var tooltip: String {
        guard let usage else { return provider.title }
        let parts = usage.windows.map { w -> String in
            let used = w.effectivePct(at: now)
            var s = "\(w.label) \(Int(used.rounded()))% used, \(Int((100 - used).rounded()))% left"
            if let r = w.resetsAt, r > now { s += ", resets in \(Self.countdown(to: r, from: now))" }
            return s
        }
        var lines = [provider.title + (usage.name != provider.title ? " · \(usage.name)" : "")] + parts
        if let at = usage.updatedAt {
            lines.append("Read \(Self.countdown(to: now, from: at)) ago")
        }
        return lines.joined(separator: "\n")
    }

    private func open() {
        switch provider {
        case .claude:
            NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
        case .codex:
            NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
        case .antigravity:
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains("Antigravity") == true && $0.activationPolicy == .regular
            }) {
                app.activate()
            } else if let url = ["/Applications/Antigravity.app", "/Applications/Antigravity IDE.app"]
                        .map(URL.init(fileURLWithPath:))
                        .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        }
    }
}
#endif
