#if !APPSTORE
import AppKit
import Darwin

/// How much memory an app uses: its own process and the helpers inside its bundle,
/// counted like Activity Monitor's "Memory" column (physical footprint).
struct AppMemory: Identifiable, Sendable {
    var name: String
    var bundleID: String
    var pid: pid_t
    var bytes: UInt64
    var processes: Int
    var id: String { bundleID.isEmpty ? "\(pid)" : bundleID }
}

struct SystemMemory: Sendable {
    var used: UInt64
    var total: UInt64
}

/// Reads memory use for the Stats page, every 5 seconds while the page is on screen only.
/// Remembers the last app you used before Coucou, since Coucou is in front while you look.
@MainActor
final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()

    @Published private(set) var apps: [AppMemory] = []
    @Published private(set) var system: SystemMemory?
    /// The app you used last, other than Coucou.
    @Published private(set) var lastAppBundleID: String?

    private var timer: Timer?
    private var viewers = 0
    private var observer: NSObjectProtocol?

    private init() {}

    /// Follows which app is in front. Costs nothing between app switches.
    func trackFrontApp() {
        guard observer == nil else { return }
        noteFront(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            let pid = app?.processIdentifier ?? 0
            MainActor.assumeIsolated { MemoryMonitor.shared.noteFront(bundleID: id, pid: pid) }
        }
    }

    private func noteFront(_ app: NSRunningApplication?) {
        noteFront(bundleID: app?.bundleIdentifier, pid: app?.processIdentifier ?? 0)
    }

    private func noteFront(bundleID: String?, pid: pid_t) {
        guard let bundleID, pid != getpid() else { return }
        lastAppBundleID = bundleID
    }

    var lastApp: AppMemory? { apps.first { $0.bundleID == lastAppBundleID } }
    var own: AppMemory? { apps.first { $0.pid == getpid() } }

    func start() {
        viewers += 1
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in MemoryMonitor.shared.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.processIdentifier == getpid() }
            .map { (name: $0.localizedName ?? $0.bundleIdentifier ?? "?", bundleID: $0.bundleIdentifier ?? "",
                    pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path) }
        Task.detached(priority: .utility) {
            let apps = Self.measure(running)
            let system = Self.systemMemory()
            await MainActor.run {
                MemoryMonitor.shared.apps = apps
                MemoryMonitor.shared.system = system
            }
        }
    }

    // MARK: - Reading

    private nonisolated static func measure(_ running: [(name: String, bundleID: String, pid: pid_t, bundlePath: String?)]) -> [AppMemory] {
        // Every process with its executable path, to give helpers to the app whose bundle holds them.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var paths: [(pid: pid_t, path: String)] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(0, found))) where pid > 0 {
            let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if n > 0 { paths.append((pid, String(cString: buffer))) }
        }

        return running.map { app in
            var members: Set<pid_t> = [app.pid]
            if let bundle = app.bundlePath {
                let prefix = bundle.hasSuffix("/") ? bundle : bundle + "/"
                for p in paths where p.path.hasPrefix(prefix) { members.insert(p.pid) }
            }
            let bytes = members.reduce(UInt64(0)) { $0 + (footprint($1) ?? 0) }
            return AppMemory(name: app.name, bundleID: app.bundleID, pid: app.pid, bytes: bytes, processes: members.count)
        }
        .filter { $0.bytes > 0 }
        .sorted { $0.bytes > $1.bytes }
    }

    private nonisolated static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : nil
    }

    /// Used = what Activity Monitor calls "Memory Used": app memory, wired and compressed.
    private nonisolated static func systemMemory() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        let appPages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return SystemMemory(used: used, total: ProcessInfo.processInfo.physicalMemory)
    }
}
#endif
