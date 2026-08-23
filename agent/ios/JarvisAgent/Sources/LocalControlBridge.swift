import Foundation
import Network

private final class LocalOnlySessionDelegate: NSObject, URLSessionTaskDelegate {
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

struct LocalControlResult {
    let status: String
    let metadata: [String: Any]
}

/// A deliberately narrow bridge to services on the iPhone loopback interface.
///
/// It cannot proxy arbitrary URLs, bundle IDs, coordinates, text, or HID data.
/// The first release only probes fixed local endpoints and performs two fixed,
/// non-secret WDA actions. No response body leaves the device.
final class LocalControlBridge {
    static let shared = LocalControlBridge()

    private let callbackQueue = DispatchQueue(label: "com.forwardinfinity.jarvisagent.local-control")
    private let networkQueue = DispatchQueue(label: "com.forwardinfinity.jarvisagent.local-control.network")
    private let wdaBaseURL = URL(string: "http://localhost:8100")!
    private let sessionDelegate = LocalOnlySessionDelegate()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }()

    private init() {}

    func perform(action: String, completion: @escaping (LocalControlResult) -> Void) {
        switch action {
        case "probe-local-control":
            probeLocalControl(completion: completion)
        case "wda-home":
            performWDAAction(
                path: "/wda/homescreen",
                body: [:],
                successEffect: "home-sent",
                completion: completion
            )
        case "wda-launch-settings":
            performWDAAction(
                path: "/wda/apps/launchUnattached",
                body: ["bundleId": "com.apple.Preferences"],
                successEffect: "settings-launch-sent",
                completion: completion
            )
        default:
            completion(LocalControlResult(
                status: "error",
                metadata: ["control_error": "unsupported-action", "effect": "none"]
            ))
        }
    }

    private func probeLocalControl(completion: @escaping (LocalControlResult) -> Void) {
        let group = DispatchGroup()
        let resultLock = NSLock()
        var metadata: [String: Any] = [
            "local_wda_reachable": false,
            "wda_ready": false,
            "local_rsd_v4": false,
            "local_rsd_v6": false,
            "effect": "probe-only",
            "control_error": "none",
        ]

        group.enter()
        wdaRequest(method: "GET", path: "/status", body: nil) { code, data in
            resultLock.lock()
            metadata["wda_http_status"] = code
            metadata["local_wda_reachable"] = code > 0
            metadata["wda_ready"] = code == 200 && self.wdaReady(from: data)
            resultLock.unlock()

            guard code > 0 else {
                group.leave()
                return
            }
            group.enter()
            self.wdaRequest(method: "GET", path: "/wda/locked", body: nil) { lockCode, lockData in
                if lockCode == 200, let locked = self.wdaLocked(from: lockData) {
                    resultLock.lock()
                    metadata["wda_locked"] = locked
                    resultLock.unlock()
                }
                group.leave()
            }
            group.leave()
        }

        group.enter()
        probeTCP(host: "127.0.0.1", port: 49152) { reachable in
            resultLock.lock()
            metadata["local_rsd_v4"] = reachable
            resultLock.unlock()
            group.leave()
        }

        group.enter()
        probeTCP(host: "::1", port: 49152) { reachable in
            resultLock.lock()
            metadata["local_rsd_v6"] = reachable
            resultLock.unlock()
            group.leave()
        }

        group.notify(queue: callbackQueue) {
            completion(LocalControlResult(status: "ok", metadata: metadata))
        }
    }

    private func performWDAAction(
        path: String,
        body: [String: Any],
        successEffect: String,
        completion: @escaping (LocalControlResult) -> Void
    ) {
        wdaRequest(method: "POST", path: path, body: body) { code, _ in
            var metadata: [String: Any] = [
                "local_wda_reachable": code > 0,
                "wda_http_status": code,
                "effect": code == 200 ? successEffect : "none",
                "control_error": code == 0 ? "wda-unreachable" : (code == 200 ? "none" : "wda-http-error"),
            ]
            let status = code == 200 ? "ok" : "error"

            guard code == 200 else {
                completion(LocalControlResult(status: status, metadata: metadata))
                return
            }
            self.wdaRequest(method: "GET", path: "/wda/locked", body: nil) { lockCode, lockData in
                if lockCode == 200, let locked = self.wdaLocked(from: lockData) {
                    metadata["wda_locked"] = locked
                }
                completion(LocalControlResult(status: status, metadata: metadata))
            }
        }
    }

    /// Only fixed relative paths supplied by this type are accepted. Redirects
    /// are treated as failure because a local bridge must never become an
    /// arbitrary network proxy.
    private func wdaRequest(
        method: String,
        path: String,
        body: [String: Any]?,
        completion: @escaping (Int, Data?) -> Void
    ) {
        guard path.hasPrefix("/"), !path.contains(".."),
              let url = URL(string: path, relativeTo: wdaBaseURL),
              url.host == "localhost", url.port == 8100 else {
            completion(0, nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.url?.host == "localhost",
                  http.url?.port == 8100 else {
                completion(0, nil)
                return
            }
            completion(http.statusCode, data)
        }.resume()
    }

    private func wdaReady(from data: Data?) -> Bool {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? [String: Any] else {
            return false
        }
        return value["ready"] as? Bool ?? false
    }

    private func wdaLocked(from data: Data?) -> Bool? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["value"] as? Bool
    }

    private func probeTCP(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        var finished = false
        func finish(_ reachable: Bool) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(reachable)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
        networkQueue.asyncAfter(deadline: .now() + 2) {
            finish(false)
        }
    }
}
