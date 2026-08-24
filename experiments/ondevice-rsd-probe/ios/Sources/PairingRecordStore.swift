import Foundation
import Security

/// Device-local storage for the experimental RPPairing record.
///
/// The record is never synchronized, logged, exported, or sent over the Agent
/// channel. After-first-unlock accessibility is required for a later locked
/// probe, but the item remains bound to this physical device.
enum PairingRecordStore {
    private static let service = "com.forwardinfinity.jarvisrsdprobe.rppairing.v1"
    private static let account = "verify-only-record"

    static var isPresent: Bool {
        var query = identity
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func write(_ data: Data) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess {
            return true
        }
        guard update == errSecItemNotFound else {
            return false
        }
        var create = identity
        create.merge(attributes) { _, new in new }
        return SecItemAdd(create as CFDictionary, nil) == errSecSuccess
    }

    static func delete() -> Bool {
        let status = SecItemDelete(identity as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
