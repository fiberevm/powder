import Foundation
import Security
import os

struct KeychainStore: Sendable {
    let service = "io.powder.app"
    let account = "codex-api-key"

    /// The key once read, so views and polls asking for it do not go back to the Keychain each time.
    private static let cached = OSAllocatedUnfairLock<String?>(initialState: nil)

    func readAPIKey() -> String? {
        if let cached = Self.cached.withLock({ $0 }) { return cached }
        let value = readFromKeychain()
        if let value { Self.cached.withLock { $0 = value } }
        return value
    }

    private func readFromKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey()
            return
        }

        Self.cached.withLock { $0 = trimmed }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainError.status(insertStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    func deleteAPIKey() {
        Self.cached.withLock { $0 = nil }
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .status(status):
            "The API key could not be saved securely (Keychain status \(status))."
        }
    }
}
