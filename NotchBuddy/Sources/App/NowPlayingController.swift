#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Now Playing (any app or browser tab, GitHub build only)

/// What the system's Now Playing reports: a browser tab, Spotify, Music, any app.
struct NowPlayingTrack: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: Double        // seconds, 0 when unknown (live streams)
    let bundleId: String?       // the app that plays it (the browser for a web page)
    let pid: Int32

    var appName: String? {
        guard let bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Reads the system's Now Playing through NowPlayingHelper (a library /usr/bin/perl loads,
/// because only Apple-entitled processes may read MediaRemote since macOS 15.4) and drives
/// playback the same way. Event driven: the helper sleeps until something changes.
@MainActor
final class NowPlayingController: ObservableObject {
    static let shared = NowPlayingController()
    nonisolated static let pillId = "integration_nowplaying"
    nonisolated static let accent = "#FF5C8A"

    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var isPlaying = false
    /// Position (seconds) at `positionDate`; while playing, the real position runs on from there.
    @Published private(set) var positionAnchor: Double = 0
    @Published private(set) var positionDate = Date()
    @Published private(set) var artwork: NSImage?
    /// False when the helper can't run (missing from the bundle, or MediaRemote refused).
    @Published private(set) var available = true

    private var process: Process?
    private var input: FileHandle?
    private var stoppedOnPurpose = false
    private var restarts = 0
    private var cancellables = Set<AnyCancellable>()
    private let scriptQueue = DispatchQueue(label: "fr.louisraille.coucou.nowplaying.script")

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    /// Where playback is now, extrapolated from the last anchor.
    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(positionDate) : 0
        let p = positionAnchor + max(0, elapsed)
        guard let d = track?.duration, d > 0 else { return p }
        return min(p, d)
    }

    private init() {
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                if active { self.start() } else { self.stop(); self.clearState() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Helper process

    private func start() {
        guard process == nil else { return }
        guard let lib = Bundle.main.url(forResource: "libCoucouNowPlaying", withExtension: "dylib") else {
            available = false
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", """
            use DynaLoader;
            my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
            my $s = DynaLoader::dl_find_symbol($l, "coucou_nowplaying_run") or die "symbol";
            DynaLoader::dl_install_xsub("main::run", $s);
            run();
            """, lib.path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice

        let splitter = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            for event in splitter.feed(chunk) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { NowPlayingController.shared.apply(event) }
                }
            }
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NowPlayingController.shared.helperExited() }
            }
        }
        do {
            try p.run()
        } catch {
            available = false
            return
        }
        stoppedOnPurpose = false
        process = p
        input = stdin.fileHandleForWriting
        available = true
    }

    private func stop() {
        stoppedOnPurpose = true
        try? input?.close()     // EOF: the helper exits on its own
        input = nil
        process?.terminate()
        process = nil
    }

    private func helperExited() {
        process = nil
        input = nil
        guard !stoppedOnPurpose, isPillActive else { return }
        // Crashed or refused: retry a few times, slowly, then give up until next launch.
        restarts += 1
        guard restarts <= 3 else { available = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isPillActive else { return }
            self.start()
        }
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    // MARK: - State

    private func apply(_ event: NowPlayingEvent) {
        switch event {
        case .none:
            clearState()
        case .error:
            available = false
        case .state(let s):
            restarts = 0
            // Coucou's own sounds are not "music".
            if s.pid == ProcessInfo.processInfo.processIdentifier { return }
            let bundle = s.parentBundle ?? s.bundle
                ?? NSRunningApplication(processIdentifier: s.pid)?.bundleIdentifier
            let newTrack = NowPlayingTrack(title: s.title, artist: s.artist, album: s.album,
                                           duration: s.duration, bundleId: bundle, pid: s.pid)
            let wasPlaying = isPlaying
            if track != newTrack { track = newTrack }
            if let data = s.artwork { artwork = NSImage(data: data) }
            else if !s.hasArtwork { artwork = nil }
            // MediaRemote gives the position at `timestamp`; while playing it has moved on since.
            var pos = s.elapsed
            if s.playing, let stamp = s.timestamp {
                pos += max(0, Date().timeIntervalSince1970 - stamp) * (s.rate > 0 ? s.rate : 1)
            }
            positionAnchor = max(0, pos)
            positionDate = Date()
            isPlaying = s.playing
            AppState.shared.nowPlayingActive = s.playing
            syncTaskName()
            if s.playing && !wasPlaying { startedPlaying() }
        }
    }

    /// Music started: show it. The notch peeks out (silently), and the Now Playing card
    /// becomes the one the island opens on unless something else needs attention.
    private func startedPlaying() {
        let state = AppState.shared
        if let focus = state.focusTask, focus.id != Self.pillId,
           focus.state == .idle || focus.state == .finished {
            state.setFocus(Self.pillId)
        }
        NotificationCenter.default.post(name: .musicReveal, object: nil)
    }

    private func clearState() {
        track = nil
        artwork = nil
        isPlaying = false
        positionAnchor = 0
        positionDate = Date()
        AppState.shared.nowPlayingActive = false
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let title = track?.title ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: Self.pillId)?.name ?? "Now Playing")
            : title
    }

    // MARK: - Quick actions

    func playPause() {
        send("toggle")
        // Answer the click at once; the helper's next line confirms it.
        positionAnchor = position(at: Date())
        positionDate = Date()
        isPlaying.toggle()
    }

    func nextTrack()     { send("next") }
    func previousTrack() { send("previous") }

    func seek(to seconds: Double) {
        send(String(format: "seek %.3f", seconds))
        positionAnchor = max(0, seconds)
        positionDate = Date()
    }

    // MARK: - Opening the source

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium",
    ]
    private static let safariBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// Takes me to what's playing: the browser tab whose title matches, else the app.
    func openSource() {
        guard let track else { return }
        let bundle = track.bundleId ?? ""
        let pid = track.pid
        guard Self.chromiumBrowsers.contains(bundle) || Self.safariBrowsers.contains(bundle) else {
            activateApp(bundleId: track.bundleId, pid: pid)
            return
        }
        let source = Self.focusTabScript(bundleId: bundle, title: track.title,
                                         safari: Self.safariBrowsers.contains(bundle))
        scriptQueue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
            let found = err == nil && result == "ok"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Tab not found (or Automation refused): at least bring the browser forward.
                    if !found { NowPlayingController.shared.activateApp(bundleId: bundle, pid: pid) }
                }
            }
        }
    }

    private func activateApp(bundleId: String?, pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
            app.activate()
        } else if let bundleId,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            app.activate()
        } else if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    /// Finds the tab whose title contains the track title, selects it, raises its window.
    nonisolated static func focusTabScript(bundleId: String, title: String, safari: Bool) -> String {
        // Tab titles are often "<title> - YouTube"; a long title may be cut: match on its start.
        let needle = String(title.prefix(60))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let select = safari ? "set current tab of w to t" : "set active tab index of w to i"
        let titleOf = safari ? "name" : "title"
        return """
            tell application id "\(bundleId)"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if (\(titleOf) of t) contains "\(needle)" then
                            \(select)
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
    }
}

// MARK: - Helper protocol

struct NowPlayingState: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let elapsed: Double
    let timestamp: Double?
    let rate: Double
    let playing: Bool
    let pid: Int32
    let bundle: String?
    let parentBundle: String?
    let artwork: Data?          // only when it changed
    let hasArtwork: Bool
}

enum NowPlayingEvent: Sendable {
    case state(NowPlayingState)
    case none
    case error
}

/// Cuts the helper's output into JSON lines. Used only from the pipe's serial read handler.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ chunk: Data) -> [NowPlayingEvent] {
        buffer.append(chunk)
        var events: [NowPlayingEvent] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let e = Self.parse(Data(line)) { events.append(e) }
        }
        // A runaway line (no newline for 8 MB) is dropped rather than kept growing.
        if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }
        return events
    }

    private static func parse(_ line: Data) -> NowPlayingEvent? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = o["type"] as? String else { return nil }
        switch type {
        case "none":  return NowPlayingEvent.none
        case "error": return .error
        case "state":
            guard let title = o["title"] as? String else { return nil }
            func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
            return .state(NowPlayingState(
                title: title,
                artist: o["artist"] as? String ?? "",
                album: o["album"] as? String ?? "",
                duration: max(0, num("duration") ?? 0),
                elapsed: max(0, num("elapsed") ?? 0),
                timestamp: num("timestamp"),
                rate: num("rate") ?? 0,
                playing: (o["playing"] as? NSNumber)?.boolValue ?? false,
                pid: Int32((o["pid"] as? NSNumber)?.intValue ?? 0),
                bundle: o["bundle"] as? String,
                parentBundle: o["parentBundle"] as? String,
                artwork: (o["artwork"] as? String).flatMap { Data(base64Encoded: $0) },
                hasArtwork: o["artworkHash"] != nil))
        default:
            return nil
        }
    }
}
#endif
