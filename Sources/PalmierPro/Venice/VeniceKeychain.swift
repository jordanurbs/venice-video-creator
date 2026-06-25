import Foundation

extension Notification.Name {
    /// Posted whenever the stored Venice API key changes (saved or removed).
    static let veniceAPIKeyChanged = Notification.Name("veniceAPIKeyChanged")
}

/// Stores the single user-supplied Venice API key in the macOS Keychain.
///
/// A single Venice key powers every AI feature in the app: the in-app agent
/// (chat/inference), image generation, video generation, audio/music, and
/// upscaling. Because the app is local and BYO-key, the key only ever lives in
/// the user's Keychain and is sent directly to `api.venice.ai`.
enum VeniceKeychain {
    private static let account = "venice-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .veniceAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["VENICE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .veniceAPIKeyChanged, object: nil)
    }

    static var hasKey: Bool { (load() ?? "").isEmpty == false }
}
