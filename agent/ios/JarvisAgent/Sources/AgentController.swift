import Combine
import Foundation
import Network
import UIKit

final class AgentController: ObservableObject {
    static let shared = AgentController()

    private let baseURL = URL(string: "https://workbox.tailfd8ac6.ts.net")!
    private let protocolVersion = 1
    private let deviceAccount = "device-id"
    private let tokenAccount = "agent-token"
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.worker")
    private let pathMonitor = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var inFlight = false
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
                    interface = "Wired"
                } else {
                    interface = "Other"
                }
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
            payload["agent_version"] = "ios-standalone-3"
            payload["bundle"] = Bundle.main.bundleIdentifier ?? "unknown"
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
                self.publish(enrolled: true)
                self.publish(status: "Connected")
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                self.publish(lastSeen: formatter.string(from: Date()))
                completion(true)
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
