#if !APPSTORE
import AppKit
import Carbon
import SwiftUI

/// The pages of the Coucou window: the notch's settings.
enum HubPage: String, CaseIterable, Identifiable {
    case general, pills, agents, chat, integrations, voice, shortcuts

    var id: String { rawValue }

    static let notchPages: [HubPage] = [.general, .pills, .agents, .chat, .integrations, .voice, .shortcuts]

    /// The section of Settings this page shows, for the notch's pages.
    var settingsSection: String {
        switch self {
        case .general:      return "general"
        case .pills:        return "activepills"
        case .agents:       return "agents"
        case .chat:         return "chat"
        case .integrations: return "integrations"
        case .voice:        return "voice"
        case .shortcuts:    return "shortcuts"
        }
    }

    /// The page showing a section of Settings ("chat", "voice"…).
    static func forSettings(_ section: String) -> HubPage {
        notchPages.first { $0.settingsSection == section } ?? .general
    }

    var title: String {
        switch self {
        case .general:      return String(localized: "General")
        case .pills:        return String(localized: "Active pills")
        case .agents:       return String(localized: "Agents")
        case .chat:         return String(localized: "Chat")
        case .integrations: return String(localized: "Integrations")
        case .voice:        return String(localized: "Voice")
        case .shortcuts:    return String(localized: "Shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .general:      return "gearshape"
        case .pills:        return "square.grid.2x2"
        case .agents:       return "terminal"
        case .chat:         return "bubble.left.and.bubble.right"
        case .integrations: return "puzzlepiece.extension"
        case .voice:        return "waveform"
        case .shortcuts:    return "keyboard"
        }
    }
}

/// The colors of the Coucou window: the island's dark, with Coucou's orange.
enum HubTheme {
    /// OLED black: the window and the sidebar.
    static let window = Color.black
    static let sidebar = Color.black
    /// The big card on the right, where the pages are.
    static let panel = Color(hex: "#0E0F11")
    static let card = Color(hex: "#18191C")
    static let field = Color(hex: "#1F2024")
    static let line = Color.white.opacity(0.07)
    static let text = Color(hex: "#F5F6F8")
    static let body = Color(hex: "#E1E3E6")
    static let secondary = Color(hex: "#8E939C")
    static let muted = Color(hex: "#6B7079")
    static let accent = Color(hex: "#FB923C")
    static let onAccent = Color(hex: "#170C04")
    static let green = Color(hex: "#34D399")
    static let red = Color(hex: "#FF453A")
}

private struct HubPageKey: EnvironmentKey {
    static let defaultValue: HubPage = .general
}

extension EnvironmentValues {
    /// The page shown, for the colour and the Mochis of its top band.
    var hubPage: HubPage {
        get { self[HubPageKey.self] }
        set { self[HubPageKey.self] = newValue }
    }
}

extension HubPage {
    /// The line under the title of the notch's pages.
    static func notchSubtitle(_ page: HubPage) -> String {
        switch page {
        case .general:      return String(localized: "hub.notch.general")
        case .pills:        return String(localized: "hub.notch.pills")
        case .agents:       return String(localized: "hub.notch.agents")
        case .chat:         return String(localized: "hub.notch.chat")
        case .integrations: return String(localized: "hub.notch.integrations")
        case .voice:        return String(localized: "hub.notch.voice")
        case .shortcuts:    return String(localized: "hub.notch.shortcuts")
        }
    }
}

@MainActor
final class HubRouter: ObservableObject {
    @Published var page: HubPage = .general
}

/// Opens the Coucou window: the notch's settings.
@MainActor
final class HubController {
    static let shared = HubController()
    let router = HubRouter()
    let windowState = HubWindowState()
    private var window: NSWindow?

    static let showInDockKey = "coucouShowInDock"
    static let openAtLaunchKey = "coucouOpenAtLaunch"

    /// Coucou in the Dock, like a regular app (on by default in the GitHub build).
    static var showInDock: Bool {
        get { UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showInDockKey)
            NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            if newValue { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// The window opens when Coucou is opened by hand (never at login).
    static var openAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: openAtLaunchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: openAtLaunchKey) }
    }

    /// Whether macOS opened Coucou at login, rather than you from the Finder, the Dock or Spotlight.
    static func launchedAtLogin() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        // A login item started by launchd may come without that flag: the first minutes after
        // the Mac starts count as a login.
        return ProcessInfo.processInfo.systemUptime < 180
    }

    func show(_ page: HubPage? = nil) {
        if let page { router.page = page }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Coucou"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .black
        win.contentView = NSHostingView(rootView: HubView(router: router, windowState: windowState))
        windowState.watch(win)
        win.contentMinSize = NSSize(width: 940, height: 600)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("CoucouFlowWindow")
        if !win.setFrameUsingName("CoucouFlowWindow") { win.center() }
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HubView: View {
    @ObservedObject var router: HubRouter
    @ObservedObject var windowState: HubWindowState

    var body: some View {
        HStack(spacing: 0) {
            HubSidebar(router: router)
            // The pages sit in one big card.
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(HubTheme.panel)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
                .padding(.top, 10)
                .padding(.bottom, 10)
                .padding(.trailing, 10)
        }
        .background(HubTheme.window)
        .foregroundColor(HubTheme.text)
        .preferredColorScheme(.dark)
        .tint(HubTheme.accent)
        .environment(\.hubVisible, windowState.visible)
        .environment(\.hubPage, router.page)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubHero(page: router.page, title: router.page.title, subtitle: HubPage.notchSubtitle(router.page))
                .padding(.horizontal, 28)
                .padding(.top, 24)
            SettingsView(embeddedSection: router.page.settingsSection)
                .id(router.page)
        }
    }
}

// MARK: - Sidebar

private struct HubSidebar: View {
    @ObservedObject var router: HubRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                // The scene draws Mochi a little below its middle (room for his
                // hops and hats): lifted so his body lines up with the name.
                HubLiveMochi(size: 28)
                    .offset(y: -4)
                Text(verbatim: "Coucou")
                    .font(.system(size: 18, weight: .bold))
            }
            .padding(.horizontal, 8)
            // Halfway between the window's buttons and "NOTCH".
            .padding(.top, 25)
            .padding(.bottom, 31)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HubSidebarHeader(text: String(localized: "hub.section.notch"))
                    ForEach(HubPage.notchPages) { page in
                        HubSidebarItem(page: page, selected: router.page == page) { router.page = page }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 228)
        .frame(maxHeight: .infinity)
        .background(HubTheme.sidebar)
    }
}

/// "NOTCH": the small capitals above a group of pages.
private struct HubSidebarHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased(with: .current))
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.2)
            .foregroundColor(HubTheme.muted)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct HubSidebarItem: View {
    let page: HubPage
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? HubTheme.text : Color(hex: "#B7BBC2"))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(selected ? 0.08 : (hover ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
#endif
