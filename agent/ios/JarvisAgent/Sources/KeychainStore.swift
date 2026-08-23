import Foundation
import Security

enum KeychainStore {
    private static let service = "com.forwardinfinity.jarvisagent.credentials.v1"

    static func read(_ account: String) -> String? {
        guard let data = readData(account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func readData(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return writeData(data, account: account)
    }

    @discardableResult
    static func writeData(_ data: Data, account: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Background work may read it while locked, but only after the
            // owner has unlocked once since boot. It never leaves this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        var create = identity
        create.merge(attributes) { _, new in new }
        return SecItemAdd(create as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
