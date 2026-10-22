#if !APPSTORE
import SwiftUI
import AppKit
import Combine

// MARK: - Usage strip under the notch

/// A thin black capsule hanging just under the island that shows the live 5-hour and weekly
/// usage of the AI app in front (Claude, Codex, Antigravity). It slides out when one of them
/// comes to the front and away when another app does. Its own click-through panel: the island
/// is untouched. Nothing runs while no supported app is in front (0 % CPU).
@MainActor
final class FrontAppUsageStrip {
    static let shared = FrontAppUsageStrip()

    private static let defaultsKey = "myNotch.frontAppUsageStrip"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            shared.update()
        }
    }

    final class Model: ObservableObject {
        @Published var provider: AIUsageProvider?
        @Published var visible = false
    }

    let model = Model()
    private var panel: NSPanel?
    private var frontKey: String?
    private var refreshTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let panelSize = NSSize(width: 300, height: 30)
    private let gap: CGFloat = 4

    private init() {}

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.frontAppChanged(app) }
            }
            .store(in: &cancellables)
        AppState.shared.$mode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .islandScreenChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
            .store(in: &cancellables)
        frontAppChanged(NSWorkspace.shared.frontmostApplication)
    }

    private func frontAppChanged(_ app: NSRunningApplication?) {
        // Clicking Coucou itself must not hide the strip.
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        frontKey = FrontAppUsageLogic.providerKey(forBundleID: app?.bundleIdentifier)
        update()
    }

    private func update() {
        let show = FrontAppUsageLogic.shouldShow(enabled: Self.enabled,
                                                 islandExpanded: AppState.shared.mode == .expanded,
                                                 providerKey: frontKey)
        if show, let key = frontKey, let provider = AIUsageProvider(rawValue: key) {
            hideTask?.cancel()
            model.provider = provider
            reposition()
            if panel?.isVisible != true { panel?.orderFrontRegardless() }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.visible = true }
            AIUsageMonitor.shared.refresh(ignoringPillState: true)
            if refreshTimer == nil {
                refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                    Task { @MainActor in AIUsageMonitor.shared.refresh(ignoringPillState: true) }
                }
            }
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            withAnimation(.easeIn(duration: 0.25)) { model.visible = false }
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func buildPanel() -> NSPanel {
        let size = Self.panelSize
        let view = NSHostingView(rootView: FrontAppUsageStripView(model: model))
        view.frame = NSRect(origin: .zero, size: size)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Same level as the island, so nothing covers it.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = view
        return p
    }

    /// Centred under the visible island (closed: compact or hidden), on the island's screen.
    private func reposition() {
        let p = panel ?? buildPanel()
        panel = p
        let app = AppState.shared
        let (_, islandH) = islandSize(mode: app.mode, view: app.view, progress: app.uploadProgress,
                                      nw: app.notchWidth, nh: app.notchHeight)
        let barH = max(islandH, app.notchHeight)
        let sf = IslandWindowController.islandScreen().frame
        let size = Self.panelSize
        let frame = NSRect(x: sf.midX - size.width / 2, y: sf.maxY - barH - gap - size.height,
                           width: size.width, height: size.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }
}

// MARK: - View

struct FrontAppUsageStripView: View {
    @ObservedObject var model: FrontAppUsageStrip.Model
    @ObservedObject private var monitor = AIUsageMonitor.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            capsule(now: ctx.date)
                .offset(y: model.visible ? 0 : -14)
                .opacity(model.visible ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func usage(for p: AIUsageProvider) -> ProviderUsage? {
        switch p {
        case .claude:      return monitor.claude
        case .codex:       return monitor.codex
        case .antigravity: return monitor.antigravity.max { ($0.dominantPct ?? 0) < ($1.dominantPct ?? 0) }
        }
    }

    @ViewBuilder
    private func capsule(now: Date) -> some View {
        if let p = model.provider {
            let u = usage(for: p)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: p.color)).frame(width: 5, height: 5)
                    Text(p.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                }
                if let u, !u.windows.isEmpty {
                    let five = u.window("5h")
                    let week = u.window("Week") ?? (five == nil ? u.windows.first : nil)
                    bar(label: "5h", five, now: now)
                    bar(label: "Wk", week, now: now)
                    if let r = (five ?? week)?.resetsAt, r > now {
                        Text(UsageRowView.countdown(to: r, from: now))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                } else {
                    Text(u?.message ?? "Reading…")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().stroke(Color(hex: p.color).opacity(0.18), lineWidth: 1))
        }
    }

    private func bar(label: String, _ w: UsageWindow?, now: Date) -> some View {
        let used = w?.effectivePct(at: now)
        let pct = used.map { monitor.showRemaining ? max(0, 100 - $0) : $0 }
        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(hex: "#6B7079"))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(width: 40, height: 4)
                Capsule().fill(Color(hex: ClaudePlanGauge.color(for: used)))
                    .frame(width: 40 * CGFloat((pct ?? 0) / 100), height: 4)
            }
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(hex: "#C5C8CD"))
        }
    }
}

/// Settings → Agents → Usage under the notch.
struct FrontAppUsageSettingsSection: View {
    @State private var on = FrontAppUsageStrip.enabled

    var body: some View {
        GroupBox("Usage under the notch") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show live usage under the notch", isOn: $on)
                    .onChange(of: on) { _, v in FrontAppUsageStrip.enabled = v }
                Text("When Claude, Codex or Antigravity is the app in front, a thin bar under the notch shows its 5-hour and weekly usage.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}
#endif
