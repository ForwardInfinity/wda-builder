import Combine
import Foundation
import JarvisRSDProbeFFI
import Network

private let controllerPairingMaximumBytes = 256 * 1024

/// Fixed, on-device owner for the already-proven XCTest/WDA lifecycle.
/// It shares Jarvis Agent's single user-visible Continued Processing grant;
/// there is no second background task or VPS-controlled transport parameter.
final class IntegratedControllerManager: ObservableObject {
    static let shared = IntegratedControllerManager()

    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.integrated-controller")
    private let localNetworkQueue = DispatchQueue(label: "com.forwardinfinity.jarvisagent.integrated-controller.local-network")
    private let healthQueue = DispatchQueue(label: "com.forwardinfinity.jarvisagent.integrated-controller.health")
    private let maximumRecoveryAttempts = 3
    private var localNetworkConnection: NWConnection?
    private var localNetworkTimeout: DispatchWorkItem?
    private var healthTimer: DispatchSourceTimer?
    private var armedForRecovery = false
    private var heldSessionActive = false
    private var recoveryAttempts = 0

    @Published private(set) var pairingPresent = ControllerPairingRecordStore.isPresent
    @Published private(set) var busy = false
    @Published private(set) var controllerActive = false
    @Published private(set) var wdaReady = false
    @Published private(set) var status = "Not started"
    @Published private(set) var stage = "None"

    private init() {}

    /// One fixed Network-framework attempt triggers Apple's Local Network
    /// consent flow. No application bytes are sent.
    func requestFixedLocalNetworkAccess() {
        guard !busy, localNetworkConnection == nil else { return }
        busy = true
        status = "Requesting fixed Local Network authorization"
        stage = "Local network permission"
        let connection = NWConnection(
            host: NWEndpoint.Host("10.7.0.1"),
            port: NWEndpoint.Port(rawValue: 49_152)!,
            using: .tcp
        )
        localNetworkConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.finishLocalNetworkRequest(
                        "Local Network path ready — no application data sent",
                        connection: connection
                    )
                }
            case .failed:
                DispatchQueue.main.async {
                    self.finishLocalNetworkRequest(
                        "Local Network request ended — verify the iOS permission toggle",
                        connection: connection
                    )
                }
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            DispatchQueue.main.async {
                self.finishLocalNetworkRequest(
                    "Local Network request timed out — verify the iOS permission toggle",
                    connection: connection
                )
            }
        }
        localNetworkTimeout = timeout
        connection.start(queue: localNetworkQueue)
        localNetworkQueue.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    /// Consumes one fixed USB-staged record before any controller operation.
    func importUSBStagedPairingRecord() {
        guard !busy else { return }
        busy = true
        status = "Validating fixed USB-staged controller record"
        stage = "Pairing import"
        let stagedURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jarvis-controller.mobiledevicepairing", isDirectory: false)

        worker.async { [weak self] in
            var bytes = Data()
            var accepted = false
            var outcome = "Controller record import rejected"
            do {
                let values = try stagedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let size = values.fileSize,
                      size > 0,
                      size <= controllerPairingMaximumBytes else {
                    throw ControllerImportError.invalidBounds
                }
                bytes = try Data(contentsOf: stagedURL, options: [])
                guard !bytes.isEmpty,
                      bytes.count <= controllerPairingMaximumBytes,
                      Self.validatePairingRecord(bytes) else {
                    throw ControllerImportError.invalidFormat
                }
                guard ControllerPairingRecordStore.write(bytes) else {
                    throw ControllerImportError.storageFailure
                }
                do {
                    try Self.removeStagedRecord(at: stagedURL, byteCount: bytes.count)
                } catch {
                    _ = ControllerPairingRecordStore.delete()
                    throw ControllerImportError.cleanupFailure
                }
                accepted = true
                outcome = "Controller record moved into device-only Keychain"
            } catch ControllerImportError.invalidBounds {
                outcome = "Controller record rejected: invalid staging bounds"
            } catch ControllerImportError.invalidFormat {
                outcome = "Controller record rejected: invalid RPPairing format"
            } catch ControllerImportError.storageFailure {
                outcome = "Controller record rejected: Keychain write failed"
            } catch ControllerImportError.cleanupFailure {
                outcome = "Controller record rejected: staging cleanup failed"
            } catch {
                outcome = "Controller record rejected: staging file unavailable"
            }
            if !accepted {
                try? Self.removeStagedRecord(at: stagedURL, byteCount: bytes.count)
            }
            if !bytes.isEmpty {
                bytes.resetBytes(in: 0..<bytes.count)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pairingPresent = accepted && ControllerPairingRecordStore.isPresent
                self.busy = false
                self.status = outcome
                self.stage = accepted ? "Validated" : "Rejected"
            }
        }
    }

    /// One explicit action arms the fixed controller and starts the sole
    /// Continued Processing owner. The RSD/XCTest work begins only after iOS
    /// invokes the execution-grant callback.
    func startProtectedFromUserAction() {
        guard !busy, !controllerActive else { return }
        guard pairingPresent else {
            status = "Controller blocked: device-local pairing record absent"
            stage = "Pairing import"
            return
        }
        armedForRecovery = true
        recoveryAttempts = 0
        status = "Waiting for the visible iOS execution grant"
        stage = "Continued processing"
        if ContinuedRecoveryManager.shared.active {
            continuedRecoveryBecameActive()
        } else {
            ContinuedRecoveryManager.shared.startFromUserAction()
        }
    }

    /// Called only by ContinuedRecoveryManager after receiving an actual
    /// BGContinuedProcessingTask, never on request submission alone.
    func continuedRecoveryBecameActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.armedForRecovery,
                  !self.busy,
                  !self.controllerActive else { return }
            self.startControllerAfterExecutionGrant()
        }
    }

    private func startControllerAfterExecutionGrant() {
        guard ContinuedRecoveryManager.shared.active else {
            status = "Controller blocked: execution grant is not active"
            stage = "Continued processing"
            return
        }
        busy = true
        status = "Starting integrated fixed XCTest controller"
        stage = "RSD adapter"

        worker.async { [weak self] in
            guard let self else { return }
            var bytes = Data()
            defer {
                if !bytes.isEmpty { bytes.resetBytes(in: 0..<bytes.count) }
            }
            if !self.heldSessionActive {
                guard let loaded = ControllerPairingRecordStore.read() else {
                    DispatchQueue.main.async {
                        self.scheduleRecovery(reason: "Controller blocked: pairing record unreadable")
                    }
                    return
                }
                bytes = loaded
                var held = Self.emptyRsdResult()
                let heldCode: Int32 = bytes.withUnsafeBytes { raw in
                    jarvis_rsd_hold_start(
                        raw.bindMemory(to: UInt8.self).baseAddress,
                        raw.count,
                        &held
                    )
                }
                guard heldCode == 0,
                      held.abi_version == 1,
                      held.stage == UInt32(JARVIS_RSD_STAGE_COMPLETE) else {
                    self.heldSessionActive = false
                    _ = jarvis_rsd_hold_stop()
                    DispatchQueue.main.async {
                        self.scheduleRecovery(
                            reason: "Integrated RSD failed closed — code \(held.error_code)/\(held.error_subcode)"
                        )
                    }
                    return
                }
                self.heldSessionActive = true
            }

            var controller = Self.emptyDtxResult()
            let controllerCode = jarvis_rsd_hold_fixed_wda_start(&controller)
            guard controllerCode == 0,
                  controller.abi_version == 1,
                  controller.stage == UInt32(JARVIS_RSD_STAGE_CONTROLLER_ACTIVE),
                  controller.channel_mask & UInt32(JARVIS_FIXED_WDA_CONTROLLER_ACTIVE) != 0 else {
                _ = jarvis_rsd_fixed_wda_stop()
                // The FFI drops the held adapter on controller-start failure.
                self.heldSessionActive = false
                DispatchQueue.main.async {
                    self.scheduleRecovery(
                        reason: "Integrated controller failed closed — code \(controller.error_code)/\(controller.error_subcode)"
                    )
                }
                return
            }

            DispatchQueue.main.async {
                self.controllerActive = true
                self.stage = "Local controller active"
                self.status = "Integrated controller active — waiting for loopback WDA"
                Task { [weak self] in
                    let ready = await Self.waitForWDAStatus()
                    guard let self else { return }
                    self.busy = false
                    self.wdaReady = ready
                    if ready {
                        self.status = "INTEGRATED JARVIS CONTROLLER + WDA PASS"
                        self.stage = "WDA ready"
                        self.startHealthMonitor()
                    } else {
                        self.scheduleRecovery(reason: "WDA readiness failed closed")
                    }
                }
            }
        }
    }

    func check() {
        guard !busy else { return }
        var result = Self.emptyDtxResult()
        let code = jarvis_rsd_fixed_wda_check(&result)
        controllerActive = code == 0
        if controllerActive {
            status = "Integrated local controller is active"
            stage = "Local controller active"
        } else {
            scheduleRecovery(reason: "Integrated controller is not active")
        }
    }

    func stopFromUserAction() {
        guard !busy else { return }
        armedForRecovery = false
        stopHealthMonitor()
        _ = jarvis_rsd_fixed_wda_stop()
        _ = jarvis_rsd_hold_stop()
        heldSessionActive = false
        controllerActive = false
        wdaReady = false
        status = "Integrated controller stopped"
        stage = "Stopped"
    }

    func stopForRecoveryExpiration() {
        armedForRecovery = false
        stopHealthMonitor()
        _ = jarvis_rsd_fixed_wda_stop()
        _ = jarvis_rsd_hold_stop()
        heldSessionActive = false
        DispatchQueue.main.async {
            self.busy = false
            self.controllerActive = false
            self.wdaReady = false
            self.status = "Controller stopped with Continued Processing"
            self.stage = "Expired"
        }
    }

    private func scheduleRecovery(reason: String) {
        stopHealthMonitor()
        // Preserve the already-authenticated userspace adapter so a warm
        // Cellular retry never depends on fresh fake-peer pair-verify.
        _ = jarvis_rsd_fixed_wda_stop()
        busy = false
        controllerActive = false
        wdaReady = false
        guard armedForRecovery,
              ContinuedRecoveryManager.shared.active,
              recoveryAttempts < maximumRecoveryAttempts else {
            armedForRecovery = false
            _ = jarvis_rsd_hold_stop()
            heldSessionActive = false
            status = reason
            stage = "Stopped fail-closed"
            return
        }
        recoveryAttempts += 1
        status = "\(reason) — bounded retry \(recoveryAttempts)/\(maximumRecoveryAttempts)"
        stage = "Controller recovery"
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self,
                  self.armedForRecovery,
                  ContinuedRecoveryManager.shared.active,
                  !self.busy,
                  !self.controllerActive else { return }
            self.startControllerAfterExecutionGrant()
        }
    }

    private func startHealthMonitor() {
        stopHealthMonitor()
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.verifyControllerHealth()
            }
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthMonitor() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func verifyControllerHealth() {
        guard armedForRecovery, controllerActive, !busy else { return }
        var result = Self.emptyDtxResult()
        guard jarvis_rsd_fixed_wda_check(&result) == 0 else {
            scheduleRecovery(reason: "Controller transport ended")
            return
        }
    }

    private func finishLocalNetworkRequest(_ message: String, connection: NWConnection) {
        guard localNetworkConnection === connection else { return }
        localNetworkTimeout?.cancel()
        localNetworkTimeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        localNetworkConnection = nil
        busy = false
        status = message
        stage = "Local network permission"
    }

    private static func validatePairingRecord(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            jarvis_rsd_pairing_record_is_valid(
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count
            ) == 1
        }
    }

    private static func removeStagedRecord(at url: URL, byteCount: Int) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return }
        if byteCount > 0, byteCount <= controllerPairingMaximumBytes {
            try Data(repeating: 0, count: byteCount).write(to: url, options: [])
        }
        try files.removeItem(at: url)
    }

    private static func waitForWDAStatus() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:8100/status")!
        for _ in 0..<120 {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 200,
                   !data.isEmpty,
                   data.count <= 262_144,
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    return true
                }
            } catch {
                // Bounded readiness polling emits no raw error.
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func emptyRsdResult() -> JarvisRsdProbeResult {
        JarvisRsdProbeResult(
            abi_version: 0,
            stage: 0,
            error_code: 0,
            error_subcode: 0,
            protocol_version: 0,
            service_mask: 0,
            service_count: 0
        )
    }

    private static func emptyDtxResult() -> JarvisDtxProbeResult {
        JarvisDtxProbeResult(
            abi_version: 0,
            stage: 0,
            error_code: 0,
            error_subcode: 0,
            channel_mask: 0
        )
    }

    private enum ControllerImportError: Error {
        case invalidBounds
        case invalidFormat
        case storageFailure
        case cleanupFailure
    }
}
