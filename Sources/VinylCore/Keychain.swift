import Foundation
import Security

/// Gemmer Discogs-tokenet i macOS' nøglering – aldrig i databasen, filer eller logs.
public enum Keychain {
    private static let service = "dk.vinylshelffinder.discogs"
    private static let account = "discogs-personal-access-token"

    /// Gemmer (eller udskifter) tokenet. Det gamle token slettes aldrig først: findes der
    /// allerede et, opdateres det på stedet med `SecItemUpdate`, så en fejl undervejs
    /// efterlader det gamle token urørt.
    public static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let changes: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = query
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(attrs as CFDictionary, nil)
            // Oprettet af en anden imellemtiden: opdatér i stedet.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Tokenet kunne ikke gemmes i nøgleringen (fejlkode \(status)). Et eventuelt tidligere token er ikke ændret."])
        }
    }

    public static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Findes der et token? Spørger kun efter elementets egenskaber, ikke selve tokenet,
    /// så macOS ikke beder om adgang til nøgleringen, bare fordi appen starter. Der
    /// spørges først, når tokenet faktisk skal bruges (sync, værdier).
    public static var hasToken: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }
}

/// En hemmelighed i macOS' nøglering (generisk adgangskode). Indholdet logges eller vises aldrig.
public struct KeychainSecret: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// iMusic-feedets URL fra Daisycon. Den indeholder brugerens media_id og behandles som en hemmelighed.
    public static let iMusicFeed = KeychainSecret(service: "dk.vinylshelffinder.imusicfeed", account: "daisycon-feed-url")

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Gemmer (eller udskifter) værdien uden først at slette den gamle.
    public func save(_ value: String) throws {
        let data = Data(value.utf8)
        let changes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = base
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(attrs as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Kunne ikke gemme i nøgleringen (fejlkode \(status))."])
        }
    }

    public func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete() {
        SecItemDelete(base as CFDictionary)
    }

    /// Findes værdien? Læser kun egenskaberne, så macOS ikke spørger om adgang ved start.
    public var exists: Bool {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }
}
