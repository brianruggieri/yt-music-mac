import Foundation
import Security

/// Codable token blob persisted in the macOS Keychain.
struct TokenBlob: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

enum KeychainError: Error {
    case notFound
    case osStatus(OSStatus)
    case decodingFailed(Error)
}

/// Thin wrapper around SecItem* to save/load/delete the Spotify token blob.
/// App sandbox is disabled in this project, so no additional entitlements are needed.
enum KeychainStore {
    private static let service = "com.ytmusic-import.spotify-tokens"
    private static let account = "spotify"

    static func save(_ blob: TokenBlob) throws {
        let data = try JSONEncoder().encode(blob)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        } else if status == errSecSuccess {
            let update: [CFString: Any] = [kSecValueData: data]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    static func load() throws -> TokenBlob {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? KeychainError.notFound : KeychainError.osStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.osStatus(errSecDecode)
        }
        do {
            return try JSONDecoder().decode(TokenBlob.self, from: data)
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
