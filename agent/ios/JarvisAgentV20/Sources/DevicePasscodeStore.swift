import Foundation

final class SecretBuffer {
    private(set) var bytes: [UInt8]

    init(_ data: Data) {
        bytes = Array(data)
    }

    func wipe() {
        for index in bytes.indices {
            bytes[index] = 0
        }
    }

    deinit {
        wipe()
    }
}

/// Device-local passcode storage and fail-closed secret boundary.
///
/// The passcode is never accepted from a VPS command. It can only be entered
/// in the foreground UI, is stored AfterFirstUnlockThisDeviceOnly, and is read
/// only after a fresh semantic keypad gate file has been consumed.
enum DevicePasscodeStore {
    private static let account = "device-passcode-v1"
    private static let purpose = "locked-springboard-passcode-keypad"

    static var isProvisioned: Bool {
        guard let data = KeychainStore.readData(account) else { return false }
        return valid(data)
    }

    static func provision(_ value: String) -> Bool {
        let data = Data(value.utf8)
        guard valid(data) else { return false }
        return KeychainStore.writeData(data, account: account)
    }

    static func remove() {
        KeychainStore.delete(account)
    }

    static func createAndConsumeGate(commandID: String) -> Bool {
        guard validCommandID(commandID), let directory = secureDirectory() else { return false }
        let gate = directory.appendingPathComponent("unlock-gate.json")
        let temporary = directory.appendingPathComponent("unlock-gate.tmp")
        try? FileManager.default.removeItem(at: gate)
        try? FileManager.default.removeItem(at: temporary)
        let value: [String: Any] = [
            "command_id": commandID,
            "purpose": purpose,
            "passed_at": Date().timeIntervalSince1970,
            "semantic_digits": 10,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [
                    .posixPermissions: 0o600,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
              ) else {
            return false
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: gate)
            let attributes = try FileManager.default.attributesOfItem(atPath: gate.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                try? FileManager.default.removeItem(at: gate)
                return false
            }
            let raw = try Data(contentsOf: gate, options: [.uncached])
            // Consume before Keychain access even if parsing or validation fails.
            try FileManager.default.removeItem(at: gate)
            guard let parsed = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  parsed["command_id"] as? String == commandID,
                  parsed["purpose"] as? String == purpose,
                  let passedAt = parsed["passed_at"] as? Double,
                  Date().timeIntervalSince1970 - passedAt >= 0,
                  Date().timeIntervalSince1970 - passedAt <= 20 else {
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: gate)
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    /// Must be called after gate consumption and before Keychain read. O_EXCL
    /// semantics are provided by createFile returning false for an existing
    /// command marker; therefore a PIN sequence is never automatically retried.
    static func markSecretBoundary(commandID: String) -> Bool {
        guard validCommandID(commandID), let directory = secureDirectory() else { return false }
        let marker = directory.appendingPathComponent("secret-access-\(commandID).json")
        let value: [String: Any] = [
            "command_id": commandID,
            "purpose": "local-unlock",
            "secret_access_at": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              !FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.createFile(
                atPath: marker.path,
                contents: data,
                attributes: [
                    .posixPermissions: 0o600,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
              ) else {
            return false
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600
    }

    static func readSecretAfterBoundary() -> SecretBuffer? {
        guard let data = KeychainStore.readData(account), valid(data) else { return nil }
        return SecretBuffer(data)
    }

    private static func valid(_ data: Data) -> Bool {
        data.count == 6 && data.allSatisfy { (48...57).contains($0) }
    }

    private static func validCommandID(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func secureDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("JarvisSecure", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: 0o700,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            )
            return directory
        } catch {
            return nil
        }
    }
}
