import Foundation

enum CommandJournalDecision {
    case execute
    case replay(status: String, metadata: [String: Any])
    case ambiguous
    case unavailable
}

/// A one-record durable journal that prevents a side-effecting command from
/// being blindly executed again when its HTTPS result acknowledgement is lost.
/// It contains command metadata only and is protected by the same
/// AfterFirstUnlockThisDeviceOnly Keychain class as the Agent credential.
enum CommandJournal {
    private static let account = "command-journal-v1"

    static func prepare(commandID: String, action: String) -> CommandJournalDecision {
        if let record = read(),
           record["command_id"] as? String == commandID,
           record["action"] as? String == action {
            if record["state"] as? String == "completed",
               let status = record["status"] as? String,
               let metadata = record["metadata"] as? [String: Any] {
                return .replay(status: status, metadata: metadata)
            }
            // The process disappeared after the durable pre-action marker but
            // before a completion marker. Never guess whether an effect ran.
            return .ambiguous
        }

        let marker: [String: Any] = [
            "command_id": commandID,
            "action": action,
            "state": "executing",
            "marked_at": Date().timeIntervalSince1970,
        ]
        return write(marker) ? .execute : .unavailable
    }

    @discardableResult
    static func complete(
        commandID: String,
        action: String,
        status: String,
        metadata: [String: Any]
    ) -> Bool {
        let record: [String: Any] = [
            "command_id": commandID,
            "action": action,
            "state": "completed",
            "status": status,
            "metadata": metadata,
            "completed_at": Date().timeIntervalSince1970,
        ]
        return write(record)
    }

    private static func read() -> [String: Any]? {
        guard let encoded = KeychainStore.read(account),
              let data = encoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func write(_ value: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return false
        }
        return KeychainStore.write(encoded, account: account)
    }
}
