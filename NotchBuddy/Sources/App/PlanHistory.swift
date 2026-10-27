#if !APPSTORE
import Foundation
import UserNotifications

/// Keeps the plan usage readings (Claude, Codex) for a week, for the Stats page's charts and
/// forecast, and warns once per window when one passes 80 %. Stored on the Mac only.
@MainActor
final class PlanHistory: ObservableObject {
    static let shared = PlanHistory()

    static let alertKey = "planUsageAlert80"
    static let alertThreshold = 80.0

    /// Keyed "Claude|5h", "Codex|Week"…
    @Published private(set) var samples: [String: [PlanSample]] = [:]

    /// Warn when a window passes 80 % (on by default).
    static var alertsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: alertKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: alertKey) }
    }

    private static let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NotchBuddy/plan-history.json")
    }()
    private static let alertedKey = "planUsageAlerted"

    private init() {
        if let raw = try? Data(contentsOf: Self.storageURL),
           let decoded = try? JSONDecoder().decode([String: [PlanSample]].self, from: raw) {
            samples = decoded
        }
    }

    static func key(provider: String, window: String) -> String { "\(provider)|\(window)" }

    func samples(provider: String, window: String) -> [PlanSample] {
        samples[Self.key(provider: provider, window: window)] ?? []
    }

    /// Called with each new reading. Keeps one sample every 5 minutes, or sooner when the
    /// figure moved by a point or more.
    func record(_ usage: ProviderUsage?) {
        guard let usage, !usage.windows.isEmpty else { return }
        // A reading is dated when the provider took it: an old one read again adds nothing.
        let now = min(usage.updatedAt ?? Date(), Date())
        var changed = false
        for window in usage.windows {
            let key = Self.key(provider: usage.name, window: window.label)
            let pct = window.effectivePct(at: now)
            var list = samples[key] ?? []
            if let last = list.last {
                if now <= last.date { continue }
                if now.timeIntervalSince(last.date) < 300, abs(last.pct - pct) < 1 { continue }
            }
            let previous = list.last?.pct ?? 0
            list.append(PlanSample(date: now, pct: pct, resetsAt: window.resetsAt))
            let cutoff = Date().addingTimeInterval(-8 * 86400)
            samples[key] = list.filter { $0.date >= cutoff }
            changed = true
            if pct >= Self.alertThreshold, previous < Self.alertThreshold || list.count == 1 {
                alert(provider: usage.name, window: window, pct: pct)
            }
        }
        if changed { save() }
    }

    func clear() {
        samples = [:]
        try? FileManager.default.removeItem(at: Self.storageURL)
    }

    private func save() {
        let dir = Self.storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(samples) {
            try? encoded.write(to: Self.storageURL, options: .atomic)
        }
    }

    // MARK: - 80 % alert

    private func alert(provider: String, window: UsageWindow, pct: Double) {
        guard Self.alertsEnabled else { return }
        // Once per window: the reset time tells one 5-hour window from the next.
        let reset = window.resetsAt.map { Int($0.timeIntervalSince1970 / 600) } ?? Int(Date().timeIntervalSince1970 / 86400)
        let id = "\(provider)|\(window.label)|\(reset)"
        var alerted = UserDefaults.standard.stringArray(forKey: Self.alertedKey) ?? []
        guard !alerted.contains(id) else { return }
        alerted = Array((alerted + [id]).suffix(40))
        UserDefaults.standard.set(alerted, forKey: Self.alertedKey)

        SoundEngine.shared.play("rate")
        let windowName = window.label == "5h" ? String(localized: "5-hour limit") : String(localized: "weekly limit")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(provider): \(Int(pct.rounded()))% of your \(windowName) used")
        if let resetsAt = window.resetsAt {
            let time = resetsAt.formatted(date: Calendar.current.isDateInToday(resetsAt) ? .omitted : .abbreviated, time: .shortened)
            content.body = String(localized: "It resets at \(time).")
        }
        let request = UNNotificationRequest(identifier: "plan-\(id)", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }
}
#endif
