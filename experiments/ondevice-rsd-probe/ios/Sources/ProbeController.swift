import Combine
import Foundation
import JarvisRSDProbeFFI

struct FixedServiceStatus: Identifiable {
    let id: String
    let name: String
    let available: Bool
}

private let maximumPairingRecordBytes = 256 * 1024

private func validatePairingRecord(_ data: Data) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
        return jarvis_rsd_pairing_record_is_valid(base, rawBuffer.count) == 1
    }
}

private func makeFixedServices(mask: UInt32) -> [FixedServiceStatus] {
    [
        FixedServiceStatus(
            id: "testmanagerd",
            name: "testmanagerd",
            available: mask & UInt32(JARVIS_RSD_SERVICE_TESTMANAGERD) != 0
        ),
        FixedServiceStatus(
            id: "dtservicehub",
            name: "dtservicehub",
            available: mask & UInt32(JARVIS_RSD_SERVICE_DTSERVICEHUB) != 0
        ),
        FixedServiceStatus(
            id: "appservice",
            name: "AppService",
            available: mask & UInt32(JARVIS_RSD_SERVICE_APP_SERVICE) != 0
        ),
        FixedServiceStatus(
            id: "installation-proxy",
            name: "installation proxy",
            available: mask & UInt32(JARVIS_RSD_SERVICE_INSTALLATION_PROXY) != 0
        ),
    ]
}

@MainActor
final class ProbeController: ObservableObject {
    @Published private(set) var hasPairingRecord = PairingRecordStore.isPresent
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Idle — no network operation has run"
    @Published private(set) var stage = "None"
    @Published private(set) var protocolVersion: UInt64 = 0
    @Published private(set) var advertisedServiceCount: UInt32 = 0
    @Published private(set) var services: [FixedServiceStatus] = makeFixedServices(mask: 0)

    private let worker = DispatchQueue(
        label: "com.forwardinfinity.jarvisrsdprobe.worker",
        qos: .userInitiated
    )

    func importUSBStagedPairingRecord() {
        guard !isBusy else { return }
        isBusy = true
        status = "Validating fixed USB-staged pairing record"
        stage = "Pairing import"
        let stagedURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("bootstrap.mobiledevicepairing", isDirectory: false)

        worker.async { [weak self] in
            var bytes = Data()
            var outcome = "USB staging import rejected"
            var accepted = false
            do {
                let fileManager = FileManager.default
                let values = try stagedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      fileSize > 0,
                      fileSize <= maximumPairingRecordBytes else {
                    throw ImportError.invalidBounds
                }
                try fileManager.setAttributes(
                    [
                        .posixPermissions: 0o600,
                        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                    ],
                    ofItemAtPath: stagedURL.path
                )
                bytes = try Data(contentsOf: stagedURL, options: [])
                guard !bytes.isEmpty,
                      bytes.count <= maximumPairingRecordBytes,
                      validatePairingRecord(bytes) else {
                    throw ImportError.invalidFormat
                }
                guard PairingRecordStore.write(bytes) else {
                    throw ImportError.storageFailure
                }
                do {
                    try Self.removeStagedRecord(at: stagedURL, byteCount: bytes.count)
                } catch {
                    _ = PairingRecordStore.delete()
                    throw ImportError.cleanupFailure
                }
                accepted = true
                outcome = "USB-staged record moved into device-local Keychain"
            } catch ImportError.invalidBounds {
                outcome = "USB staging rejected: invalid size or file type"
            } catch ImportError.invalidFormat {
                outcome = "USB staging rejected: invalid RPPairing record"
            } catch ImportError.cleanupFailure {
                outcome = "USB staging rejected: secure cleanup failed"
            } catch {
                outcome = "USB staging rejected: local read or storage failure"
            }
            if !accepted {
                try? Self.removeStagedRecord(at: stagedURL, byteCount: bytes.count)
            }
            if !bytes.isEmpty {
                bytes.resetBytes(in: 0..<bytes.count)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.hasPairingRecord = accepted && PairingRecordStore.isPresent
                self.isBusy = false
                self.status = outcome
                self.stage = accepted ? "Validated" : "Rejected"
            }
        }
    }

    func importPairingRecord(from url: URL) {
        guard !isBusy else { return }
        isBusy = true
        status = "Validating pairing record locally"
        stage = "Pairing import"
        worker.async { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            var bytes = Data()
            var outcome = "Import rejected"
            var accepted = false
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      fileSize > 0,
                      fileSize <= maximumPairingRecordBytes else {
                    throw ImportError.invalidBounds
                }
                bytes = try Data(contentsOf: url, options: [])
                guard !bytes.isEmpty,
                      bytes.count <= maximumPairingRecordBytes,
                      validatePairingRecord(bytes) else {
                    throw ImportError.invalidFormat
                }
                guard PairingRecordStore.write(bytes) else {
                    throw ImportError.storageFailure
                }
                accepted = true
                outcome = "Pairing record stored device-locally"
            } catch ImportError.invalidBounds {
                outcome = "Import rejected: invalid size or file type"
            } catch ImportError.invalidFormat {
                outcome = "Import rejected: not a valid RPPairing record"
            } catch {
                outcome = "Import rejected: local read or storage failure"
            }
            if !bytes.isEmpty {
                bytes.resetBytes(in: 0..<bytes.count)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.hasPairingRecord = accepted && PairingRecordStore.isPresent
                self.isBusy = false
                self.status = outcome
                self.stage = accepted ? "Validated" : "Rejected"
            }
        }
    }

    func deletePairingRecord() {
        guard !isBusy else { return }
        let removed = PairingRecordStore.delete()
        hasPairingRecord = PairingRecordStore.isPresent
        status = removed ? "Pairing record removed" : "Pairing record removal failed"
        stage = "Local storage"
        clearProbeResult()
    }

    func runReadOnlyProbe() {
        guard !isBusy else { return }
        guard hasPairingRecord else {
            status = "Probe blocked: pairing record is absent"
            stage = "Input"
            return
        }
        isBusy = true
        status = "Running bounded verify-only RSD probe"
        stage = "Starting"
        clearProbeResult()

        worker.async { [weak self] in
            guard var bytes = PairingRecordStore.read() else {
                DispatchQueue.main.async {
                    self?.finishLocalFailure("Probe blocked: pairing record could not be read")
                }
                return
            }
            defer {
                if !bytes.isEmpty {
                    bytes.resetBytes(in: 0..<bytes.count)
                }
            }

            var result = JarvisRsdProbeResult(
                abi_version: 0,
                stage: 0,
                error_code: 0,
                error_subcode: 0,
                protocol_version: 0,
                service_mask: 0,
                service_count: 0
            )
            let returnCode: Int32 = bytes.withUnsafeBytes { rawBuffer in
                let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
                return jarvis_rsd_probe(base, rawBuffer.count, &result)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.stage = Self.stageName(result.stage)
                if returnCode == 0,
                   result.abi_version == 1,
                   result.stage == UInt32(JARVIS_RSD_STAGE_COMPLETE) {
                    self.protocolVersion = result.protocol_version
                    self.advertisedServiceCount = result.service_count
                    self.services = makeFixedServices(mask: result.service_mask)
                    self.status = "RSD TRANSPORT PASS — read-only handshake completed"
                } else {
                    self.status = "Probe failed closed — code \(result.error_code)/\(result.error_subcode)"
                }
            }
        }
    }

    private nonisolated static func removeStagedRecord(at url: URL, byteCount: Int) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        if byteCount > 0, byteCount <= maximumPairingRecordBytes {
            try Data(repeating: 0, count: byteCount).write(to: url, options: [])
        }
        try fileManager.removeItem(at: url)
    }

    private func finishLocalFailure(_ message: String) {
        isBusy = false
        status = message
        stage = "Local storage"
    }

    private func clearProbeResult() {
        protocolVersion = 0
        advertisedServiceCount = 0
        services = makeFixedServices(mask: 0)
    }

    private static func stageName(_ value: UInt32) -> String {
        switch value {
        case UInt32(JARVIS_RSD_STAGE_INPUT): return "Input"
        case UInt32(JARVIS_RSD_STAGE_PAIRING_PARSE): return "Pairing parse"
        case UInt32(JARVIS_RSD_STAGE_TCP_CONNECT): return "Fake-peer TCP"
        case UInt32(JARVIS_RSD_STAGE_PAIR_VERIFY_HELLO): return "Pair-verify hello"
        case UInt32(JARVIS_RSD_STAGE_PAIR_VERIFY): return "Pair-verify"
        case UInt32(JARVIS_RSD_STAGE_TUNNEL_LISTENER): return "Tunnel listener"
        case UInt32(JARVIS_RSD_STAGE_TUNNEL_TCP): return "Tunnel TCP"
        case UInt32(JARVIS_RSD_STAGE_TUNNEL_TLS): return "Tunnel TLS"
        case UInt32(JARVIS_RSD_STAGE_TUNNEL_PARAMETERS): return "Tunnel parameters"
        case UInt32(JARVIS_RSD_STAGE_RSD_TCP): return "Userspace RSD TCP"
        case UInt32(JARVIS_RSD_STAGE_RSD_HANDSHAKE): return "RSD handshake"
        case UInt32(JARVIS_RSD_STAGE_COMPLETE): return "Complete"
        default: return "None"
        }
    }

    private enum ImportError: Error {
        case invalidBounds
        case invalidFormat
        case storageFailure
        case cleanupFailure
    }
}
