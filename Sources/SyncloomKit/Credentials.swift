import Foundation
import Security

/// What the apps (and the File Provider extension) need to reopen a session without asking again.
public struct SavedSession: Codable {
    public var server: String
    public var username: String
    public var token: String
    /// Master and private key (64 bytes), base64. Stored only in the Keychain.
    public var secrets: Data
}

/// Keychain storage. With an access group (App Group style `TEAMID.group.world.syncloom`) the app and its
/// File Provider extension share the session.
public enum Credentials {
    public static var accessGroup: String?
    private static let service = "world.syncloom.session"

    private static func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "current"]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    @discardableResult
    public static func save(_ s: SavedSession) -> Bool {
        guard let data = try? JSONEncoder().encode(s) else { return false }
        SecItemDelete(base() as CFDictionary)
        var q = base()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public static func load() -> SavedSession? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: d)
    }

    public static func clear() {
        SecItemDelete(base() as CFDictionary)
    }
}
