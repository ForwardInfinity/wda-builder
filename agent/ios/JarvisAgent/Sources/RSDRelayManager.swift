import Foundation
import Network

/// Fixed-purpose, memory-only relay from the iPhone loopback RemotePairing
/// listener to the authenticated VPS WDA holder. It never accepts a URL, host,
/// port, service name, or payload from a command: both endpoints are constants.
final class RSDRelayManager {
    static let shared = RSDRelayManager()

    private let baseURL = URL(string: "https://workbox.tailfd8ac6.ts.net")!
    private let tokenAccount = "agent-token"
    private let enabledKey = "jarvis-rsd-relay-enabled"
    private let queue = DispatchQueue(label: "com.forwardinfinity.jarvisagent.rsd-relay")
    private let maxChunkBytes = 64 * 1024
    private let maxQueuedBytes = 1024 * 1024

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    private var desired = false
    private var deviceID: String?
    private var generation = 0
    private var opening = false
    private var connection: NWConnection?
    private var relayID: String?
    private var upstreamQueue: [Data] = []
    private var queuedBytes = 0
    private var upstreamInFlight = false
    private var downstreamInFlight = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var startWaiters: [(Bool) -> Void] = []

    private init() {}

    func start(deviceID: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard (8...128).contains(deviceID.count) else {
                completion(false)
                return
            }
            UserDefaults.standard.set(true, forKey: self.enabledKey)
            self.desired = true
            self.deviceID = deviceID
            if self.relayID != nil, self.connection != nil {
                completion(true)
                return
            }
            self.startWaiters.append(completion)
            self.establishIfNeeded()
        }
    }

    func ensureStarted(deviceID: String) {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        start(deviceID: deviceID) { _ in }
    }

    private func establishIfNeeded() {
        guard desired, !opening, connection == nil, relayID == nil,
              let deviceID,
              let token = KeychainStore.read(tokenAccount), token.count >= 40 else {
            if desired, connection == nil, !opening {
                scheduleReconnect()
            }
            return
        }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        opening = true
        generation += 1
        let currentGeneration = generation
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let local = NWConnection(host: "127.0.0.1", port: 49152, using: .tcp)
        connection = local
        local.stateUpdateHandler = { [weak self, weak local] state in
            guard let self, let local else { return }
            self.queue.async {
                guard self.generation == currentGeneration, self.connection === local else { return }
                switch state {
                case .ready:
                    self.openServerRelay(
                        generation: currentGeneration,
                        nonce: nonce,
                        deviceID: deviceID,
                        token: token
                    )
                case .failed, .cancelled:
                    self.restart(generation: currentGeneration)
                default:
                    break
                }
            }
        }
        local.start(queue: queue)
    }

    private func openServerRelay(
        generation currentGeneration: Int,
        nonce: String,
        deviceID: String,
        token: String
    ) {
        guard generation == currentGeneration, relayID == nil else { return }
        var request = authenticatedRequest(
            path: "/v1/rsd-relay/open",
            method: "POST",
            deviceID: deviceID,
            token: token
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": deviceID,
            "protocol": 1,
            "nonce": nonce,
        ])
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == currentGeneration else { return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, code == 200, let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let relayID = object["relay_id"] as? String,
                      Self.validIdentifier(relayID) else {
                    self.restart(generation: currentGeneration)
                    return
                }
                self.opening = false
                self.relayID = relayID
                self.completeStartWaiters(true)
                self.receiveLocal(generation: currentGeneration)
                self.flushUpstream(generation: currentGeneration)
                self.pollDownstream(generation: currentGeneration)
            }
        }.resume()
    }

    private func receiveLocal(generation currentGeneration: Int) {
        guard generation == currentGeneration, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxChunkBytes) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.generation == currentGeneration, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    guard data.count <= self.maxChunkBytes,
                          self.queuedBytes + data.count <= self.maxQueuedBytes else {
                        self.restart(generation: currentGeneration)
                        return
                    }
                    self.upstreamQueue.append(data)
                    self.queuedBytes += data.count
                    self.flushUpstream(generation: currentGeneration)
                }
                if isComplete || error != nil {
                    self.restart(generation: currentGeneration)
                    return
                }
                self.receiveLocal(generation: currentGeneration)
            }
        }
    }

    private func flushUpstream(generation currentGeneration: Int) {
        guard generation == currentGeneration, !upstreamInFlight,
              !upstreamQueue.isEmpty,
              let deviceID,
              let relayID,
              let token = KeychainStore.read(tokenAccount) else { return }
        let data = upstreamQueue.removeFirst()
        queuedBytes -= data.count
        upstreamInFlight = true
        var request = authenticatedRequest(
            path: "/v1/rsd-relay/up",
            method: "POST",
            deviceID: deviceID,
            token: token,
            relayID: relayID
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == currentGeneration else { return }
                self.upstreamInFlight = false
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, code == 200 else {
                    self.restart(generation: currentGeneration)
                    return
                }
                self.flushUpstream(generation: currentGeneration)
            }
        }.resume()
    }

    private func pollDownstream(generation currentGeneration: Int) {
        guard generation == currentGeneration, !downstreamInFlight,
              let deviceID,
              let relayID,
              let token = KeychainStore.read(tokenAccount),
              let connection else { return }
        downstreamInFlight = true
        let request = authenticatedRequest(
            path: "/v1/rsd-relay/down",
            method: "GET",
            deviceID: deviceID,
            token: token,
            relayID: relayID
        )
        session.dataTask(with: request) { [weak self, weak connection] data, response, error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.generation == currentGeneration, self.connection === connection else { return }
                self.downstreamInFlight = false
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, code == 200, let data, data.count <= self.maxChunkBytes else {
                    self.restart(generation: currentGeneration)
                    return
                }
                guard !data.isEmpty else {
                    self.pollDownstream(generation: currentGeneration)
                    return
                }
                connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection else { return }
                    self.queue.async {
                        guard self.generation == currentGeneration, self.connection === connection else { return }
                        guard error == nil else {
                            self.restart(generation: currentGeneration)
                            return
                        }
                        self.pollDownstream(generation: currentGeneration)
                    }
                })
            }
        }.resume()
    }

    private func authenticatedRequest(
        path: String,
        method: String,
        deviceID: String,
        token: String,
        relayID: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-Jarvis-Device-ID")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let relayID {
            request.setValue(relayID, forHTTPHeaderField: "X-Jarvis-Relay-ID")
        }
        return request
    }

    private func restart(generation currentGeneration: Int) {
        guard generation == currentGeneration else { return }
        generation += 1
        opening = false
        upstreamInFlight = false
        downstreamInFlight = false
        relayID = nil
        upstreamQueue.removeAll(keepingCapacity: false)
        queuedBytes = 0
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard desired, reconnectWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.establishIfNeeded()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func completeStartWaiters(_ success: Bool) {
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter(success)
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
