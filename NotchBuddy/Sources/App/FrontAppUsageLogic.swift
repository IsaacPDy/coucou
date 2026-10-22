import Foundation

/// Which AI usage provider the frontmost app belongs to (pure, so it can be tested alone).
/// The returned key is an `AIUsageProvider` raw value.
enum FrontAppUsageLogic {

    private static let providerByBundleID: [String: String] = [
        "com.anthropic.claudefordesktop": "claude",
        "com.openai.codex":               "codex",
        "com.google.antigravity":         "antigravity",
        "com.google.antigravity-ide":     "antigravity",
    ]

    static func providerKey(forBundleID id: String?) -> String? {
        guard let id else { return nil }
        return providerByBundleID[id]
    }

    /// The strip hangs under the closed island: it hides while the island is open.
    static func shouldShow(enabled: Bool, islandExpanded: Bool, providerKey: String?) -> Bool {
        enabled && !islandExpanded && providerKey != nil
    }
}
