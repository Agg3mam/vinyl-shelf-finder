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
