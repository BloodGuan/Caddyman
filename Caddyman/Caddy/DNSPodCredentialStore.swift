import Foundation
import Security

protocol DNSPodCredentialStoring: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

enum DNSPodCredentialStoreError: Error, Equatable, LocalizedError {
    case invalidToken
    case keychainFailure

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            L10n.text("The DNSPod token must use the APP_ID,APP_TOKEN format.")
        case .keychainFailure:
            L10n.text("Caddyman could not access the DNSPod item in Keychain.")
        }
    }
}

struct DNSPodKeychainCredentialStore: DNSPodCredentialStoring {
    static let service = "Caddyman-DNSPod"
    static let account = "DNSPOD_TOKEN"

    func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              ReverseProxySiteValidator.isValidDNSPodToken(token) else {
            throw DNSPodCredentialStoreError.keychainFailure
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ReverseProxySiteValidator.isValidDNSPodToken(normalized) else {
            throw DNSPodCredentialStoreError.invalidToken
        }
        let data = Data(normalized.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DNSPodCredentialStoreError.keychainFailure }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw DNSPodCredentialStoreError.keychainFailure
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DNSPodCredentialStoreError.keychainFailure
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
