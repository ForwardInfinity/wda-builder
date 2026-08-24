import Foundation
import Security

/// Bootstrap authority for the fixed on-device RSD controller. The bytes are
/// non-synchronizing, device-bound, and never enter the VPS command channel.
enum ControllerPairingRecordStore {
    private static let service = "com.forwardinfinity.jarvisagent.rppairing.v1"
    private static let account = "fixed-controller-record"

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
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var create = identity
        create.merge(attributes) { _, new in new }
        create[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
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
        ]
    }
}
