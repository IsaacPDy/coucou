import Foundation

@main
enum FrontAppUsageTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "  ✓ \(label)" : "  ✗ \(label)")
        if !ok { failures += 1 }
    }

    static func main() {
        let key = FrontAppUsageLogic.providerKey(forBundleID:)
        check("Claude desktop", key("com.anthropic.claudefordesktop") == "claude")
        check("Codex desktop", key("com.openai.codex") == "codex")
        check("Antigravity", key("com.google.antigravity") == "antigravity")
        check("Antigravity IDE", key("com.google.antigravity-ide") == "antigravity")
        check("Safari is not an AI app", key("com.apple.Safari") == nil)
        check("ChatGPT chat app is not Codex", key("com.openai.chat") == nil)
        check("nil bundle id", key(nil) == nil)

        check("shows for a supported app", FrontAppUsageLogic.shouldShow(enabled: true, islandExpanded: false, providerKey: "claude"))
        check("hidden when disabled", !FrontAppUsageLogic.shouldShow(enabled: false, islandExpanded: false, providerKey: "claude"))
        check("hidden while island open", !FrontAppUsageLogic.shouldShow(enabled: true, islandExpanded: true, providerKey: "claude"))
        check("hidden for other apps", !FrontAppUsageLogic.shouldShow(enabled: true, islandExpanded: false, providerKey: nil))

        print(failures == 0 ? "All passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
