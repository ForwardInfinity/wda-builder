import Combine
import Foundation

private final class FullUISessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Explicitly enabled, unlocked-screen-only WDA bridge.
///
/// This is separate from the fixed command plane and never handles a passcode
/// or pairing record. Every request is device-bound/authenticated, delivered at
/// most once by the VPS, bounded here, and rejected whenever WDA reports locked.
final class FullUIBridge: ObservableObject {
    static let shared = FullUIBridge()

    private let pollURL = URL(string: "https://workbox.tailfd8ac6.ts.net/jarvis-ui/v1/poll")!
    private let resultURL = URL(string: "https://workbox.tailfd8ac6.ts.net/jarvis-ui/v1/result")!
    private let wdaBaseURL = URL(string: "http://localhost:8100")!
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.full-ui")
    private let sessionDelegate = FullUISessionDelegate()
    private let tokenAccount = "agent-token"
    private let maximumRequestBytes = 512 * 1024
    private let maximumResponseBytes = 8 * 1024 * 1024
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var runtimeEnabled = false

    @Published private(set) var enabled = false
    @Published private(set) var status = "Disabled"

    private lazy var rendezvousSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }()

    private lazy var wdaSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }()

    private init() {}

    /// Direct on-device consent is required once per process lifetime.
    func enableFromUserAction() {
        worker.async {
            self.runtimeEnabled = true
            let status = ContinuedRecoveryManager.shared.active
                ? "Enabled · unlocked screens only"
                : "Waiting for visible recovery execution"
            self.publish(enabled: true, status: status)
            self.startTimer()
        }
    }

    func disableFromUserAction() {
        worker.async { self.stop(status: "Disabled") }
    }

    func stopForRecoveryExpiration() {
        worker.async { self.stop(status: "Stopped with recovery task") }
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    private func stop(status: String) {
        runtimeEnabled = false
        timer?.cancel()
        timer = nil
        publish(enabled: false, status: status)
    }

    private func poll() {
        guard runtimeEnabled, ContinuedRecoveryManager.shared.active, !inFlight,
              let token = KeychainStore.read(tokenAccount) else { return }
        inFlight = true
        var request = URLRequest(url: pollURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": AgentController.shared.deviceID,
            "protocol": 1,
        ])
        rendezvousSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.worker.async {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, code == 200, let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.inFlight = false
                    self.publish(enabled: true, status: "Reconnect pending")
                    return
                }
                guard let command = object["command"] as? [String: Any] else {
                    self.inFlight = false
                    return
                }
                self.execute(command)
            }
        }.resume()
    }

    private func execute(_ command: [String: Any]) {
        guard let identifier = command["id"] as? String,
              validIdentifier(identifier),
              let method = command["method"] as? String,
              ["GET", "POST", "DELETE"].contains(method),
              let path = command["path"] as? String,
              validWDAPath(path),
              let encoded = command["body_b64"] as? String,
              let body = Data(base64Encoded: encoded),
              body.count <= maximumRequestBytes else {
            if let identifier = command["id"] as? String, validIdentifier(identifier) {
                postResult(identifier: identifier, statusCode: 0, error: "invalid-request", body: Data())
            } else {
                inFlight = false
            }
            return
        }

        readLockState { [weak self] code, locked in
            guard let self else { return }
            self.worker.async {
                guard code == 200, let locked else {
                    self.postResult(identifier: identifier, statusCode: 0, error: "wda-unreachable", body: Data())
                    return
                }
                guard !locked else {
                    self.postResult(identifier: identifier, statusCode: 423, error: "device-locked", body: Data())
                    return
                }
                self.performWDARequest(identifier: identifier, method: method, path: path, body: body)
            }
        }
    }

    private func performWDARequest(
        identifier: String,
        method: String,
        path: String,
        body: Data
    ) {
        guard let url = URL(string: path, relativeTo: wdaBaseURL),
              url.host == "localhost", url.port == 8100 else {
            postResult(identifier: identifier, statusCode: 0, error: "invalid-request", body: Data())
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if !body.isEmpty { request.httpBody = body }
        wdaSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.worker.async {
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      http.url?.host == "localhost", http.url?.port == 8100 else {
                    self.postResult(identifier: identifier, statusCode: 0, error: "wda-unreachable", body: Data())
                    return
                }
                let result = data ?? Data()
                guard result.count <= self.maximumResponseBytes else {
                    self.postResult(identifier: identifier, statusCode: 0, error: "response-too-large", body: Data())
                    return
                }
                self.postResult(identifier: identifier, statusCode: http.statusCode, error: "none", body: result)
            }
        }.resume()
    }

    private func readLockState(completion: @escaping (Int, Bool?) -> Void) {
        var request = URLRequest(url: URL(string: "/wda/locked", relativeTo: wdaBaseURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        wdaSession.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.url?.host == "localhost", http.url?.port == 8100 else {
                completion(0, nil)
                return
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(http.statusCode, nil)
                return
            }
            completion(http.statusCode, object["value"] as? Bool)
        }.resume()
    }

    private func postResult(identifier: String, statusCode: Int, error: String, body: Data) {
        guard let token = KeychainStore.read(tokenAccount) else {
            inFlight = false
            return
        }
        let payload: [String: Any] = [
            "device_id": AgentController.shared.deviceID,
            "id": identifier,
            "status_code": statusCode,
            "error": error,
            "body_b64": body.base64EncodedString(),
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload) else {
            inFlight = false
            return
        }
        var request = URLRequest(url: resultURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = encoded
        rendezvousSession.dataTask(with: request) { [weak self] _, response, requestError in
            guard let self else { return }
            self.worker.async {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.inFlight = false
                if requestError == nil && code == 200 {
                    self.publish(enabled: true, status: "Full UI ready")
                } else {
                    // The VPS marks delivery before execution. Never repeat an
                    // ambiguous side effect merely because its result was lost.
                    self.publish(enabled: true, status: "Ambiguous result; fail closed")
                }
            }
        }.resume()
    }

    private func validIdentifier(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func validWDAPath(_ path: String) -> Bool {
        guard path.utf8.count <= 512,
              path.hasPrefix("/"),
              !path.contains(".."),
              !path.contains("://"),
              !path.contains("\\"),
              !path.contains("?") else { return false }
        return path == "/status"
            || path == "/source"
            || path == "/screenshot"
            || path == "/session"
            || path.hasPrefix("/session/")
            || path.hasPrefix("/wda/")
    }

    private func publish(enabled: Bool, status: String) {
        DispatchQueue.main.async {
            self.enabled = enabled
            self.status = status
        }
    }
}
