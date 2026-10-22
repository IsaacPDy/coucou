#if !APPSTORE
import Foundation
import Combine

// MARK: - AI usage: Claude (Desktop files + status line), Codex (app-server), Antigravity (language server)

/// One quota window of a provider: a 5-hour or a weekly bucket.
struct UsageWindow: Equatable, Sendable {
    let label: String       // "5h", "Week"
    let usedPct: Double     // 0–100
    let resetsAt: Date?     // nil when the provider didn't say

    /// 0 once the reset has passed: the quota refilled since the reading.
    func effectivePct(at now: Date = Date()) -> Double {
        if let r = resetsAt, r <= now { return 0 }
        return usedPct
    }
}

/// What one provider reported, or why it couldn't.
struct ProviderUsage: Equatable, Sendable {
    let name: String            // "Claude", "Codex", "Gemini", …
    let windows: [UsageWindow]
    let updatedAt: Date?
    var message: String? = nil  // shown instead of the bars when there are none

    var dominantPct: Double? {
        windows.map { $0.effectivePct() }.max()
    }

    func window(_ label: String) -> UsageWindow? {
        windows.first { $0.label == label }
    }
}

enum AIUsageProvider: String, CaseIterable, Sendable {
    case claude, codex, antigravity

    var title: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// The catalog colours of their agent pills.
    var color: String {
        switch self {
        case .claude:      return "#D97757"
        case .codex:       return "#2DD4BF"
        case .antigravity: return "#E879F9"
        }
    }
}

private func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    // Python-style microseconds ("…00.002288+00:00"): drop the fraction.
    if let dot = s.firstIndex(of: "."),
       let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        return f.date(from: String(s[..<dot]) + String(s[tz...]))
    }
    return nil
}

// MARK: - Claude: Claude Desktop's own usage files

/// Claude Desktop samples the plan usage every 12–15 minutes into plan-usage-history.json
/// (percentages only) and keeps the /usage response it fetched in its HTTP cache (with
/// reset times). Only the usage fields are read: no conversation, no credential.
/// Coucou's status-line relay only hears from terminal Claude Code sessions; this covers
/// the Claude desktop app.
enum ClaudeDesktopUsage {
    private static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude")
    }

    private struct CachedWindow { let pct: Double; let resetsAt: Date? }

    static func read() -> ProviderUsage? {
        let history = readHistory()
        let cache = history.flatMap { readCache(organization: $0.org) }
        guard history != nil || cache != nil else { return nil }

        var windows: [UsageWindow] = []
        let updatedAt: Date?
        if let cache, cache.date > (history?.date ?? .distantPast) {
            // The cached response is newer than the last sample: it has both values.
            for (key, label) in [("five_hour", "5h"), ("seven_day", "Week")] {
                if let w = cache.windows[key] {
                    windows.append(UsageWindow(label: label, usedPct: w.pct, resetsAt: w.resetsAt))
                }
            }
            updatedAt = cache.date
        } else if let history {
            for (key, cacheKey, label) in [("fh", "five_hour", "5h"), ("sd", "seven_day", "Week")] {
                guard let pct = history.usage[key] else { continue }
                // The cached reset belongs to this reading only if the window hasn't rolled over.
                var reset: Date? = nil
                if let c = cache?.windows[cacheKey], let r = c.resetsAt,
                   abs(c.pct - pct) < 0.01 || r > history.date {
                    reset = r
                }
                windows.append(UsageWindow(label: label, usedPct: pct, resetsAt: reset))
            }
            updatedAt = history.date
        } else {
            updatedAt = nil
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(name: "Claude", windows: windows, updatedAt: updatedAt)
    }

    private static func readHistory() -> (org: String, date: Date, usage: [String: Double])? {
        let url = claudeDir.appendingPathComponent("plan-usage-history.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        for sample in samples.reversed() {
            guard let t = (sample["t"] as? NSNumber)?.doubleValue,
                  let org = sample["org"] as? String,
                  let u = sample["u"] as? [String: Any] else { continue }
            let date = Date(timeIntervalSince1970: t / 1000)
            guard date.timeIntervalSinceNow < 60 else { continue }
            var usage: [String: Double] = [:]
            for key in ["fh", "sd"] {
                if let v = (u[key] as? NSNumber)?.doubleValue, v.isFinite { usage[key] = min(100, max(0, v)) }
            }
            return (org, date, usage)
        }
        return nil
    }

    private static func readCache(organization: String) -> (date: Date, windows: [String: CachedWindow])? {
        let dir = claudeDir.appendingPathComponent("Cache/Cache_Data")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return nil }
        let candidates: [(Date, URL)] = files.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  (v.fileSize ?? .max) <= 2 * 1024 * 1024,
                  let date = v.contentModificationDate else { return nil }
            return (date, url)
        }.sorted { $0.0 > $1.0 }

        let endpoint = Data("/api/organizations/\(organization)/usage".utf8)
        for (date, url) in candidates {
            guard let bytes = try? Data(contentsOf: url), bytes.range(of: endpoint) != nil else { continue }
            var json: Any?
            if let start = bytes.range(of: Data(#"{"five_hour""#.utf8))?.lowerBound {
                json = jsonPrefix(bytes[start...])
            } else if let start = bytes.range(of: Data([0x28, 0xB5, 0x2F, 0xFD]))?.lowerBound,
                      let decoded = zstdDecode(Data(bytes[start...])) {
                json = jsonPrefix(decoded[...])
            }
            guard let obj = json as? [String: Any] else { continue }
            var windows: [String: CachedWindow] = [:]
            for key in ["five_hour", "seven_day"] {
                guard let w = obj[key] as? [String: Any],
                      let pct = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                windows[key] = CachedWindow(pct: min(100, max(0, pct)),
                                            resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
            }
            if !windows.isEmpty { return (date, windows) }
        }
        return nil
    }

    /// Claude Desktop stores the response zstd-compressed. macOS has no zstd decoder of its
    /// own, so this uses the `zstd` command when it's installed (Homebrew); without it, the
    /// percentages still show and only the reset times are unknown.
    private static func zstdDecode(_ data: Data) -> Data? {
        guard let tool = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-dc", "-q"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Write from another thread so a full stdout pipe can't block both ends.
        DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out.isEmpty ? nil : out
    }
}

/// Parses the first JSON object of `bytes`, ignoring whatever follows it.
func jsonPrefix(_ bytes: Data.SubSequence) -> Any? {
    var depth = 0, inString = false, escaped = false
    var end: Data.Index?
    for i in bytes.indices {
        let b = bytes[i]
        if inString {
            if escaped { escaped = false }
            else if b == 0x5C { escaped = true }
            else if b == 0x22 { inString = false }
            continue
        }
        if b == 0x22 { inString = true }
        else if b == 0x7B || b == 0x5B { depth += 1 }
        else if b == 0x7D || b == 0x5D {
            depth -= 1
            if depth == 0 { end = i; break }
        }
    }
    guard let end else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(bytes[bytes.startIndex...end]))
}

// MARK: - Claude (ClaudePlanGauge, from the status-line relay) and Codex (CodexPlanGauge)

extension CodexPlanUsage {
    var providerUsage: ProviderUsage {
        var windows: [UsageWindow] = []
        if let f = fiveHour { windows.append(UsageWindow(label: "5h", usedPct: f.usedPct, resetsAt: f.resetsAt)) }
        if let w = sevenDay { windows.append(UsageWindow(label: "Week", usedPct: w.usedPct, resetsAt: w.resetsAt)) }
        return ProviderUsage(name: "Codex", windows: windows, updatedAt: updatedAt)
    }
}

extension PlanUsage {
    var providerUsage: ProviderUsage {
        var windows: [UsageWindow] = []
        if let f = fiveHour { windows.append(UsageWindow(label: "5h", usedPct: f.usedPct, resetsAt: f.resetsAt)) }
        if let w = sevenDay { windows.append(UsageWindow(label: "Week", usedPct: w.usedPct, resetsAt: w.resetsAt)) }
        return ProviderUsage(name: "Claude", windows: windows, updatedAt: updatedAt)
    }
}

// MARK: - Antigravity: the running app's language server

/// Antigravity's language server answers on a local port, guarded by a CSRF token its own
/// app passes on the command line. Reading the token from `ps` and asking for the quotas
/// is what Antigravity's panel does; nothing is stored. Undocumented: an update may break it.
enum AntigravityUsage {
    private static let service = "/exa.language_server_pb.LanguageServerService/"

    /// One ProviderUsage per model group ("Gemini", "Claude and GPT"), or a message.
    static func read() async -> [ProviderUsage] {
        let servers = parseProcesses(run("/bin/ps", ["-axo", "pid=,command="]))
        guard !servers.isEmpty else {
            return [ProviderUsage(name: "Antigravity", windows: [], updatedAt: nil,
                                  message: "Open Antigravity to read its quotas")]
        }
        for server in servers {
            let lsof = run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", String(server.pid)])
            for port in parsePorts(lsof) {
                guard let status = await post(port: port, csrf: server.csrf, method: "GetUserStatus"),
                      status["userStatus"] != nil else { continue }
                // Older versions lack the summary: fall back to per-model quotas.
                let summary = await post(port: port, csrf: server.csrf, method: "RetrieveUserQuotaSummary")
                var groups = summary.map(summaryGroups) ?? []
                if groups.isEmpty { groups = pools(status) }
                return groups.isEmpty
                    ? [ProviderUsage(name: "Antigravity", windows: [], updatedAt: Date(),
                                     message: "No model quotas reported")]
                    : groups
            }
        }
        return [ProviderUsage(name: "Antigravity", windows: [], updatedAt: nil,
                              message: "Couldn't read quotas — signed in?")]
    }

    private static func parseProcesses(_ ps: String) -> [(pid: Int32, csrf: String)] {
        ps.split(separator: "\n").compactMap { line in
            guard line.contains("language_server"), line.lowercased().contains("antigravity") else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = parts.first.flatMap({ Int32($0) }) else { return nil }
            for (i, arg) in parts.enumerated() {
                if arg.hasPrefix("--csrf_token=") { return (pid, String(arg.dropFirst("--csrf_token=".count))) }
                if arg == "--csrf_token", i + 1 < parts.count { return (pid, String(parts[i + 1])) }
            }
            return nil
        }
    }

    private static func parsePorts(_ lsof: String) -> [Int] {
        let ports = lsof.split(separator: "\n").filter { $0.contains("LISTEN") }.compactMap { line -> Int? in
            guard let addr = line.split(separator: " ").first(where: { $0.contains(":") }) else { return nil }
            return addr.split(separator: ":").last.flatMap { Int($0) }
        }
        return Array(Set(ports)).sorted()
    }

    private static func post(port: Int, csrf: String, method: String) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(service)\(method)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(csrf, forHTTPHeaderField: "x-codeium-csrf-token")
        req.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]   // never through a proxy: it's localhost
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Per model group, a weekly and a 5-hour bucket — what Antigravity's own panel shows.
    private static func summaryGroups(_ summary: [String: Any]) -> [ProviderUsage] {
        let groups = (summary["response"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        return groups.compactMap { g in
            let name = shortGroupName(g["displayName"] as? String ?? "Models")
            var windows: [UsageWindow] = []
            for b in g["buckets"] as? [[String: Any]] ?? [] {
                guard let fraction = (b["remainingFraction"] as? NSNumber)?.doubleValue, fraction.isFinite else { continue }
                let label: String
                switch b["window"] as? String {
                case "5h":     label = "5h"
                case "weekly": label = "Week"
                case let other?: label = other
                case nil:      continue
                }
                windows.append(UsageWindow(label: label,
                                           usedPct: min(100, max(0, 100 - min(1, max(0, fraction)) * 100)),
                                           resetsAt: (b["resetTime"] as? String).flatMap(parseDate)))
            }
            return windows.isEmpty ? nil : ProviderUsage(name: name, windows: windows, updatedAt: Date())
        }
    }

    /// Older servers: one quota per model; models with the same reading share a pool.
    private static func pools(_ status: [String: Any]) -> [ProviderUsage] {
        let configs = (((status["userStatus"] as? [String: Any])?["cascadeModelConfigData"]
                        as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]) ?? []
        var byPool: [String: (pct: Double, reset: Date?, labels: [String])] = [:]
        for c in configs {
            guard let q = c["quotaInfo"] as? [String: Any] else { continue }
            // A quota object without a fraction means the pool is exhausted.
            let fraction = min(1, max(0, (q["remainingFraction"] as? NSNumber)?.doubleValue ?? 0))
            let reset = (q["resetTime"] as? String).flatMap(parseDate)
            let key = "\(Int((fraction * 1000).rounded()))|\(reset?.timeIntervalSince1970 ?? 0)"
            let label = c["label"] as? String ?? "Model"
            byPool[key, default: (100 - fraction * 100, reset, [])].labels.append(label)
        }
        return byPool.values.sorted { $0.labels.sorted()[0] < $1.labels.sorted()[0] }.map { pool in
            let labels = pool.labels.sorted()
            let name = labels.count == 1 ? labels[0] : "\(labels[0]) +\(labels.count - 1)"
            return ProviderUsage(name: name, windows: [UsageWindow(label: "Quota", usedPct: pool.pct, resetsAt: pool.reset)],
                                 updatedAt: Date())
        }
    }

    private static func shortGroupName(_ name: String) -> String {
        name.replacingOccurrences(of: " Models", with: "")
            .replacingOccurrences(of: " models", with: "")
            .replacingOccurrences(of: " and ", with: "/")
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Monitor

/// Keeps the three readings fresh while the island is open (0 % CPU while it's hidden).
@MainActor
final class AIUsageMonitor: ObservableObject {
    static let shared = AIUsageMonitor()
    nonisolated static let pillId = "integration_usage"

    @Published private(set) var claude: ProviderUsage?
    @Published private(set) var codex: ProviderUsage?
    @Published private(set) var antigravity: [ProviderUsage] = []
    @Published private(set) var lastRefresh: Date?
    /// Show what's left instead of what's used (the button beside refresh). Persisted.
    @Published var showRemaining: Bool = UserDefaults.standard.bool(forKey: "myNotch.usageShowRemaining") {
        didSet {
            UserDefaults.standard.set(showRemaining, forKey: "myNotch.usageShowRemaining")
            syncTaskName()
        }
    }

    private var lastRead: [AIUsageProvider: Date] = [:]
    private var inFlight: Set<AIUsageProvider> = []
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Minimum time between two reads of a provider.
    private func interval(_ p: AIUsageProvider) -> TimeInterval {
        switch p {
        case .claude:      return 30    // two small local files
        case .codex:       return 120   // starts `codex app-server`
        case .antigravity: return 60
        }
    }

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    private init() {
        // Read when the island opens; keep reading every minute while it stays open.
        AppState.shared.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                guard let self else { return }
                if mode == .expanded {
                    self.refresh()
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                        Task { @MainActor in AIUsageMonitor.shared.refresh() }
                    }
                } else {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
            .store(in: &cancellables)
        // Claude Code's status line feeds AppState.claudePlanUsage (HookServer).
        AppState.shared.$claudePlanUsage
            .sink { [weak self] _ in Task { @MainActor in self?.updateClaude() } }
            .store(in: &cancellables)
        refresh()
    }

    func refresh(force: Bool = false, ignoringPillState: Bool = false) {
        guard isPillActive || ignoringPillState else { return }
        for p in AIUsageProvider.allCases {
            if !force, let last = lastRead[p], Date().timeIntervalSince(last) < interval(p) { continue }
            guard !inFlight.contains(p) else { continue }
            inFlight.insert(p)
            lastRead[p] = Date()
            Task {
                switch p {
                case .claude:
                    AppState.shared.refreshPlanRelayState()
                    desktopClaude = await Task.detached { ClaudeDesktopUsage.read() }.value
                    updateClaude()
                case .codex:
                    if let u = await CodexPlanGauge.fetch() {
                        codex = u.providerUsage
                        AppState.shared.codexPlanUsage = u
                    } else if codex == nil {
                        codex = ProviderUsage(name: "Codex", windows: [], updatedAt: nil,
                                              message: CodexPlanGauge.codexExecutable() == nil
                                                ? "Codex CLI not found" : "Sign in to Codex to see it")
                    }
                case .antigravity:
                    antigravity = await AntigravityUsage.read()
                }
                inFlight.remove(p)
                lastRefresh = Date()
                syncTaskName()
            }
        }
    }

    /// Two Claude readings, the newer one wins: Claude Desktop's own files, and the rate
    /// limits terminal Claude Code hands Coucou's status-line relay (when it's installed).
    private var desktopClaude: ProviderUsage?
    private func updateClaude() {
        let candidates = [desktopClaude, AppState.shared.claudePlanUsage?.providerUsage].compactMap { $0 }
        claude = candidates.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
            ?? ProviderUsage(name: "Claude", windows: [], updatedAt: nil,
                             message: "Open Claude Desktop to sample usage")
        syncTaskName()
    }

    /// A used percentage as the card and pill show it: used, or what's left.
    func shown(_ usedPct: Double) -> Double {
        showRemaining ? max(0, 100 - usedPct) : usedPct
    }

    /// The highest use across everything, for Mochi's colour.
    var dominantPct: Double? {
        ([claude, codex].compactMap { $0 } + antigravity).compactMap(\.dominantPct).max()
    }

    /// Highest use of a provider (Antigravity: across its model groups).
    func pct(_ p: AIUsageProvider) -> Double? {
        switch p {
        case .claude:      return claude?.dominantPct
        case .codex:       return codex?.dominantPct
        case .antigravity: return antigravity.compactMap(\.dominantPct).max()
        }
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let parts = AIUsageProvider.allCases.compactMap { p in pct(p).map { "\(p.title) \(Int(shown($0).rounded()))%" } }
        AppState.shared.tasks[idx].name = parts.isEmpty
            ? (PillCatalog.definition(for: Self.pillId)?.name ?? "AI Usage")
            : parts.joined(separator: " · ")
    }
}
#endif
