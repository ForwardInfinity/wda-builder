import Combine
import Foundation
import Network
import UIKit

final class AgentController: ObservableObject {
    static let shared = AgentController()

    private let baseURL = URL(string: "https://workbox.tailfd8ac6.ts.net")!
    private let protocolVersion = 1
    private let agentVersion = "ios-standalone-11"
    private let allowedCommands = Set([
        "ping",
        "refresh-stream",
        "probe-local-control",
        "wda-home",
        "wda-launch-settings",
        "wda-continue-recovery",
        "wda-keyboard-probe",
        "secure-unlock",
    ])
    private let deviceAccount = "device-id"
    private let tokenAccount = "agent-token"
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.worker")
    private let pathMonitor = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var commandInFlight: String?
    private var startedAt = Date()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    @Published private(set) var status = "Starting"
    @Published private(set) var path = "Checking network"
    @Published private(set) var lastSeen = "Never"
    @Published private(set) var enrolled = false
    @Published private(set) var unlockProvisioned = DevicePasscodeStore.isProvisioned

    private init() {}

    var deviceID: String {
        if let existing = KeychainStore.read(deviceAccount), existing.count >= 8 {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        precondition(KeychainStore.write(created, account: deviceAccount))
        return created
    }

    func start() {
        worker.async {
            guard self.timer == nil else { return }
            _ = self.deviceID
            self.startedAt = Date()
            self.pathMonitor.pathUpdateHandler = { [weak self] path in
                let interface: String
                if path.usesInterfaceType(.cellular) {
                    interface = "Cellular"
                } else if path.usesInterfaceType(.wifi) {
                    interface = "Wi-Fi"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    interface = "Ethernet"
                } else {
                    interface = "Other"
                }
                let network = path.status == .satisfied ? interface : "Offline"
                UserDefaults.standard.set(network, forKey: "jarvis-network")
                self?.publish(path: "\(path.status == .satisfied ? "Online" : "Offline") · \(interface)")
            }
            self.pathMonitor.start(queue: self.worker)
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            BackgroundLeaseManager.shared.start()
            self.publish(status: "Connecting")
        }
    }

    @discardableResult
    func provisionDevicePasscode(_ value: String) -> Bool {
        let success = DevicePasscodeStore.provision(value)
        DispatchQueue.main.async { self.unlockProvisioned = DevicePasscodeStore.isProvisioned }
        return success
    }

    func removeDevicePasscode() {
        DevicePasscodeStore.remove()
        DispatchQueue.main.async { self.unlockProvisioned = false }
    }

    func appEnteredBackground() {
        BackgroundLeaseManager.shared.start()
        scheduleBackgroundRefresh()
        worker.async {
            guard self.backgroundTask == .invalid else { return }
            DispatchQueue.main.async {
                self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "JarvisHeartbeat") {
                    self.finishBackgroundTask()
                }
            }
        }
    }

    func appBecameActive() {
        BackgroundLeaseManager.shared.start()
        worker.async { self.tick() }
    }

    func continuedRecoveryPulse() {
        BackgroundLeaseManager.shared.start()
        worker.async { self.tick() }
    }

    func performBackgroundRefresh(completion: @escaping (Bool) -> Void) {
        worker.async {
            self.performRequest { success in
                self.scheduleBackgroundRefresh()
                completion(success)
            }
        }
    }

    func scheduleBackgroundRefresh() {
        AppDelegate.scheduleRefresh()
    }

    private func finishBackgroundTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    private func tick() {
        performRequest { _ in }
    }

    private func performRequest(completion: @escaping (Bool) -> Void) {
        guard !inFlight else {
            completion(false)
            return
        }
        inFlight = true
        let token = KeychainStore.read(tokenAccount)
        let isEnrollment = token == nil
        let endpoint = isEnrollment ? "/v1/enroll" : "/v1/heartbeat"
        var payload: [String: Any] = [
            "device_id": deviceID,
            "protocol": protocolVersion,
        ]
        if isEnrollment {
            payload["client"] = "jarvis-wda"
        } else {
            payload["agent_version"] = agentVersion
            payload["bundle"] = Bundle.main.bundleIdentifier ?? "unknown"
            payload["network"] = UserDefaults.standard.string(forKey: "jarvis-network") ?? "Unknown"
            payload["os"] = UIDevice.current.systemVersion
            payload["uptime"] = ProcessInfo.processInfo.systemUptime
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            inFlight = false
            publish(status: "JSON error")
            completion(false)
            return
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.worker.async {
                defer { self.inFlight = false }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, (200..<300).contains(code), let data else {
                    if code == 403 && isEnrollment {
                        self.publish(status: "Waiting for secure enrollment")
                    } else {
                        self.publish(status: "Reconnect pending (\(code == 0 ? "network" : String(code)))")
                    }
                    completion(false)
                    return
                }
                if isEnrollment {
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let issued = object["token"] as? String,
                          issued.count >= 40,
                          KeychainStore.write(issued, account: self.tokenAccount) else {
                        self.publish(status: "Invalid enrollment response")
                        completion(false)
                        return
                    }
                    self.publish(enrolled: true)
                    self.publish(status: "Enrolled; authenticating")
                    BackgroundLeaseManager.shared.start()
                    self.tick()
                    completion(true)
                    return
                }
                self.handleCommandResponse(data)
                self.publish(enrolled: true)
                self.publish(status: "Connected")
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                self.publish(lastSeen: formatter.string(from: Date()))
                completion(true)
            }
        }.resume()
    }

    private func handleCommandResponse(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? [String: Any],
              let commandID = command["id"] as? String,
              commandID.count == 32,
              let action = command["action"] as? String,
              allowedCommands.contains(action),
              commandInFlight != commandID else {
            return
        }
        commandInFlight = commandID

        switch CommandJournal.prepare(commandID: commandID, action: action) {
        case let .replay(status, metadata):
            sendCommandResult(commandID: commandID, action: action, status: status, metadata: metadata)
        case .ambiguous:
            completeAndSend(
                commandID: commandID,
                action: action,
                status: "error",
                metadata: ["control_error": "ambiguous-state", "effect": "none"]
            )
        case .unavailable:
            sendCommandResult(
                commandID: commandID,
                action: action,
                status: "error",
                metadata: ["control_error": "journal-unavailable", "effect": "none"]
            )
        case .execute:
            executeCommand(commandID: commandID, action: action)
        }
    }

    private func executeCommand(commandID: String, action: String) {
        if action == "ping" {
            completeAndSend(commandID: commandID, action: action, status: "ok", metadata: [:])
            return
        }
        if action == "refresh-stream" {
            BackgroundLeaseManager.shared.forceReconnect()
            completeAndSend(
                commandID: commandID,
                action: action,
                status: "ok",
                metadata: ["effect": "stream-refresh-requested", "control_error": "none"]
            )
            return
        }
        LocalControlBridge.shared.perform(action: action, commandID: commandID) { [weak self] result in
            guard let self else { return }
            self.worker.async {
                self.completeAndSend(
                    commandID: commandID,
                    action: action,
                    status: result.status,
                    metadata: result.metadata
                )
            }
        }
    }

    private func completeAndSend(
        commandID: String,
        action: String,
        status: String,
        metadata: [String: Any]
    ) {
        var finalStatus = status
        var finalMetadata = metadata
        if !CommandJournal.complete(
            commandID: commandID,
            action: action,
            status: status,
            metadata: metadata
        ) {
            // The pre-action marker remains durable, so a repeated delivery
            // fails ambiguous rather than executing the effect a second time.
            finalStatus = "error"
            finalMetadata["control_error"] = "journal-completion-failed"
        }
        sendCommandResult(
            commandID: commandID,
            action: action,
            status: finalStatus,
            metadata: finalMetadata
        )
    }

    private func sendCommandResult(
        commandID: String,
        action: String,
        status: String,
        metadata: [String: Any]
    ) {
        guard let token = KeychainStore.read(tokenAccount) else {
            commandInFlight = nil
            return
        }
        var payload: [String: Any] = [
            "device_id": deviceID,
            "command_id": commandID,
            "action": action,
            "status": status,
            "agent_version": agentVersion,
            "network": UserDefaults.standard.string(forKey: "jarvis-network") ?? "Unknown",
            "uptime": ProcessInfo.processInfo.systemUptime,
        ]
        let allowedMetadata = Set([
            "local_wda_reachable",
            "wda_ready",
            "wda_locked",
            "local_rsd_v4",
            "local_rsd_v6",
            "wda_http_status",
            "effect",
            "control_error",
            "keypad_gate",
            "probe_digit_sent",
            "cleanup_sent",
            "secret_accessed",
            "unlock_verified",
        ])
        for (key, value) in metadata where allowedMetadata.contains(key) {
            if value is String || value is Int || value is Bool || value is Double {
                payload[key] = value
            }
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/result"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            commandInFlight = nil
            return
        }
        request.httpBody = body
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.worker.async {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil && (200..<300).contains(code) {
                    self.publish(status: "Command \(action) complete")
                }
                self.commandInFlight = nil
            }
        }.resume()
    }

    private func publish(status: String) {
        DispatchQueue.main.async { self.status = status }
    }

    private func publish(path: String) {
        DispatchQueue.main.async { self.path = path }
    }

    private func publish(lastSeen: String) {
        DispatchQueue.main.async { self.lastSeen = lastSeen }
    }

    private func publish(enrolled: Bool) {
        DispatchQueue.main.async { self.enrolled = enrolled }
    }
}
