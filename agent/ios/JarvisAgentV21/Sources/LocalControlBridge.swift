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

private final class PasscodeXMLGateParser: NSObject, XMLParserDelegate {
    private(set) var digits = Set<String>()
    private(set) var titlePresent = false
    private(set) var emergencyPresent = false
    private(set) var cancelPresent = false
    private(set) var emptyFieldPresent = false

    var passed: Bool {
        digits == Set((0...9).map(String.init))
            && titlePresent
            && emergencyPresent
            && cancelPresent
            && emptyFieldPresent
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = attributeDict["name"] ?? ""
        let label = attributeDict["label"] ?? ""
        let value = attributeDict["value"] ?? ""
        if elementName == "XCUIElementTypeKey" {
            for candidate in [name, label] where candidate.count == 1 && candidate.first?.isNumber == true {
                digits.insert(candidate)
            }
        }
        if name == "Enter Passcode" || label == "Enter Passcode" {
            titlePresent = true
        }
        if name == "Emergency" || label == "Emergency" {
            emergencyPresent = true
        }
        if name == "Cancel" || label == "Cancel" {
            cancelPresent = true
        }
        if elementName == "XCUIElementTypeSecureTextField"
            && (name == "Passcode field" || label == "Passcode field")
            && value == "0 of 6 values entered" {
            emptyFieldPresent = true
        }
    }
}

struct LocalControlResult {
    let status: String
    let metadata: [String: Any]
}

/// Deliberately narrow bridge to WDA on the iPhone loopback interface.
///
/// It cannot proxy arbitrary URLs, bundle IDs, coordinates, text, or command
/// parameters. UI trees are inspected only in memory and never returned.
final class LocalControlBridge {
    static let shared = LocalControlBridge()

    private let callbackQueue = DispatchQueue(label: "com.forwardinfinity.jarvisagent.local-control")
    private let networkQueue = DispatchQueue(label: "com.forwardinfinity.jarvisagent.local-control.network")
    private let wdaBaseURL = URL(string: "http://localhost:8100")!
    private let sessionDelegate = LocalOnlySessionDelegate()
    private let keypadSourceReadAttempts = 5

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
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

    func perform(
        action: String,
        commandID: String,
        completion: @escaping (LocalControlResult) -> Void
    ) {
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
        case "wda-continue-recovery":
            continueRecovery(completion: completion)
        case "wda-keyboard-probe":
            keyboardProbe(completion: completion)
        case "secure-unlock":
            secureUnlock(commandID: commandID, completion: completion)
        default:
            completion(failure("unsupported-action"))
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
            self.readLockState { lockCode, locked in
                if lockCode == 200, let locked {
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
            self.readLockState { lockCode, locked in
                if lockCode == 200, let locked {
                    metadata["wda_locked"] = locked
                }
                completion(LocalControlResult(status: status, metadata: metadata))
            }
        }
    }

    private func continueRecovery(completion: @escaping (LocalControlResult) -> Void) {
        createSession { sessionCode, sessionID in
            guard sessionCode == 200, let sessionID else {
                completion(self.failure("session-failed", httpStatus: sessionCode))
                return
            }
            self.findElement(
                sessionID: sessionID,
                predicate: "label == 'Continue' AND enabled == 1"
            ) { findCode, elementID in
                guard findCode == 200, let elementID else {
                    completion(self.failure("element-not-found", httpStatus: findCode))
                    return
                }
                self.wdaRequest(
                    method: "POST",
                    path: "/session/\(sessionID)/element/\(elementID)/click",
                    body: [:]
                ) { clickCode, _ in
                    guard clickCode == 200 else {
                        completion(self.failure("wda-http-error", httpStatus: clickCode))
                        return
                    }
                    completion(LocalControlResult(status: "ok", metadata: [
                        "local_wda_reachable": true,
                        "wda_http_status": clickCode,
                        "effect": "recovery-continued",
                        "control_error": "none",
                    ]))
                }
            }
        }
    }

    private func keyboardProbe(completion: @escaping (LocalControlResult) -> Void) {
        createSession { sessionCode, sessionID in
            guard sessionCode == 200, let sessionID else {
                completion(self.failure("session-failed", httpStatus: sessionCode))
                return
            }
            self.prepareKeypad(sessionID: sessionID) { gateCode, passed in
                guard passed else {
                    completion(self.failure("keypad-gate-rejected", httpStatus: gateCode, extra: ["keypad_gate": false]))
                    return
                }
                self.sendHID(sessionID: sessionID, usage: 0x1E, duration: 0.15) { digitCode in
                    guard digitCode == 200 else {
                        completion(self.failure("hid-rejected", httpStatus: digitCode, extra: ["keypad_gate": true]))
                        return
                    }
                    self.sendHID(sessionID: sessionID, usage: 0x2A, duration: 0.05) { cleanupCode in
                        guard cleanupCode == 200 else {
                            completion(self.failure("hid-rejected", httpStatus: cleanupCode, extra: [
                                "keypad_gate": true,
                                "probe_digit_sent": true,
                                "cleanup_sent": false,
                            ]))
                            return
                        }
                        completion(LocalControlResult(status: "ok", metadata: [
                            "local_wda_reachable": true,
                            "wda_http_status": cleanupCode,
                            "keypad_gate": true,
                            "probe_digit_sent": true,
                            "cleanup_sent": true,
                            "effect": "keyboard-probe-cleaned",
                            "control_error": "none",
                        ]))
                    }
                }
            }
        }
    }

    private func secureUnlock(
        commandID: String,
        completion: @escaping (LocalControlResult) -> Void
    ) {
        guard DevicePasscodeStore.isProvisioned else {
            completion(failure("passcode-not-provisioned"))
            return
        }
        createSession { sessionCode, sessionID in
            guard sessionCode == 200, let sessionID else {
                completion(self.failure("session-failed", httpStatus: sessionCode))
                return
            }
            self.prepareKeypad(sessionID: sessionID) { gateCode, passed in
                guard passed else {
                    completion(self.failure("keypad-gate-rejected", httpStatus: gateCode, extra: ["keypad_gate": false]))
                    return
                }
                guard DevicePasscodeStore.createAndConsumeGate(commandID: commandID) else {
                    completion(self.failure("gate-file-failed", extra: ["keypad_gate": true]))
                    return
                }
                guard DevicePasscodeStore.markSecretBoundary(commandID: commandID) else {
                    completion(self.failure("secret-marker-failed", extra: ["keypad_gate": true]))
                    return
                }
                guard let secret = DevicePasscodeStore.readSecretAfterBoundary() else {
                    completion(self.failure("passcode-not-provisioned", extra: ["keypad_gate": true]))
                    return
                }
                self.sendPasscode(secret, sessionID: sessionID) { sendCode in
                    guard sendCode == 200 else {
                        secret.wipe()
                        completion(self.failure("hid-rejected", httpStatus: sendCode, extra: [
                            "keypad_gate": true,
                            "secret_accessed": true,
                            "effect": "unlock-sent",
                        ]))
                        return
                    }
                    secret.wipe()
                    self.callbackQueue.asyncAfter(deadline: .now() + 1) {
                        self.readLockState { lockCode, locked in
                            let verified = lockCode == 200 && locked == false
                            completion(LocalControlResult(status: verified ? "ok" : "error", metadata: [
                                "local_wda_reachable": lockCode > 0,
                                "wda_http_status": lockCode,
                                "keypad_gate": true,
                                "secret_accessed": true,
                                "unlock_verified": verified,
                                "effect": verified ? "unlocked" : "unlock-sent",
                                "control_error": verified ? "none" : "unlock-not-verified",
                            ]))
                        }
                    }
                }
            }
        }
    }

    /// Sends ten Backspaces followed by exactly six key usages. Any error ends
    /// the transaction; callers never retry a secret-bearing command.
    private func sendPasscode(
        _ secret: SecretBuffer,
        sessionID: String,
        completion: @escaping (Int) -> Void
    ) {
        func clear(_ remaining: Int) {
            guard remaining > 0 else {
                sendDigit(0)
                return
            }
            sendHID(sessionID: sessionID, usage: 0x2A, duration: 0.03) { code in
                guard code == 200 else {
                    completion(code)
                    return
                }
                clear(remaining - 1)
            }
        }
        func sendDigit(_ index: Int) {
            guard index < secret.bytes.count else {
                completion(200)
                return
            }
            let byte = secret.bytes[index]
            let usage = byte == 48 ? 0x27 : 0x1E + Int(byte - 49)
            sendHID(sessionID: sessionID, usage: usage, duration: 0.15) { code in
                guard code == 200 else {
                    completion(code)
                    return
                }
                self.callbackQueue.asyncAfter(deadline: .now() + 0.15) {
                    sendDigit(index + 1)
                }
            }
        }
        clear(10)
    }

    private func prepareKeypad(
        sessionID: String,
        completion: @escaping (Int, Bool) -> Void
    ) {
        readLockState { lockCode, locked in
            guard lockCode == 200, locked == true else {
                completion(lockCode, false)
                return
            }
            // /wda/unlock blocks until FBScreenLockTimeout when a passcode is
            // present. Home wakes Cover Sheet; one fixed public digit then
            // exposes the keypad. Backspace removes it before the XML gate,
            // which requires exactly "0 of 6 values entered".
            self.wdaRequest(
                method: "POST",
                path: "/session/\(sessionID)/wda/pressButton",
                body: ["name": "home"]
            ) { homeCode, _ in
                guard homeCode == 200 else {
                    completion(homeCode, false)
                    return
                }
                // A dark Cover Sheet can accept Home before SpringBoard has
                // made its secure accessibility tree queryable. Wait for that
                // transition before the one public digit/cleanup sequence.
                self.callbackQueue.asyncAfter(deadline: .now() + 0.85) {
                    self.sendHID(sessionID: sessionID, usage: 0x1E, duration: 0.15) { publicDigitCode in
                        guard publicDigitCode == 200 else {
                            completion(publicDigitCode, false)
                            return
                        }
                        self.callbackQueue.asyncAfter(deadline: .now() + 0.35) {
                            self.sendHID(sessionID: sessionID, usage: 0x2A, duration: 0.05) { cleanupCode in
                                guard cleanupCode == 200 else {
                                    completion(cleanupCode, false)
                                    return
                                }
                                self.callbackQueue.asyncAfter(deadline: .now() + 0.85) {
                                    self.readEmptyPasscodeGate(
                                        remaining: self.keypadSourceReadAttempts,
                                        completion: completion
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// SpringBoard can transiently return HTTP 500 for /source while its
    /// secure lock-screen tree is being published. Retry only this read-only,
    /// bounded XML fetch: no additional HID event and no secret access occurs.
    private func readEmptyPasscodeGate(
        remaining: Int,
        completion: @escaping (Int, Bool) -> Void
    ) {
        wdaRequest(method: "GET", path: "/source", body: nil) { sourceCode, data in
            let passed = sourceCode == 200 && self.isEmptyPasscodeXML(data)
            guard !passed, remaining > 1 else {
                completion(sourceCode, passed)
                return
            }
            self.callbackQueue.asyncAfter(deadline: .now() + 0.75) {
                self.readEmptyPasscodeGate(remaining: remaining - 1, completion: completion)
            }
        }
    }

    private func createSession(completion: @escaping (Int, String?) -> Void) {
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": ["shouldWaitForQuiescence": false],
                "firstMatch": [[:]],
            ],
        ]
        wdaRequest(method: "POST", path: "/session", body: body) { code, data in
            completion(code, code == 200 ? self.sessionID(from: data) : nil)
        }
    }

    private func findElement(
        sessionID: String,
        predicate: String,
        completion: @escaping (Int, String?) -> Void
    ) {
        guard validIdentifier(sessionID) else {
            completion(0, nil)
            return
        }
        wdaRequest(
            method: "POST",
            path: "/session/\(sessionID)/element",
            body: ["using": "predicate string", "value": predicate]
        ) { code, data in
            completion(code, code == 200 ? self.elementID(from: data) : nil)
        }
    }

    private func isEmptyPasscodeXML(_ data: Data?) -> Bool {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["value"] as? String,
              source.utf8.count <= 2_000_000,
              let xml = source.data(using: .utf8) else {
            return false
        }
        let gate = PasscodeXMLGateParser()
        let parser = XMLParser(data: xml)
        parser.delegate = gate
        return parser.parse() && gate.passed
    }

    private func sendHID(
        sessionID: String,
        page: Int = 0x07,
        usage: Int,
        duration: Double,
        completion: @escaping (Int) -> Void
    ) {
        guard validIdentifier(sessionID), (0...255).contains(usage) else {
            completion(0)
            return
        }
        wdaRequest(
            method: "POST",
            path: "/session/\(sessionID)/wda/performIoHidEvent",
            body: ["page": page, "usage": usage, "duration": duration]
        ) { code, _ in
            completion(code)
        }
    }

    private func readLockState(completion: @escaping (Int, Bool?) -> Void) {
        wdaRequest(method: "GET", path: "/wda/locked", body: nil) { code, data in
            completion(code, code == 200 ? self.wdaLocked(from: data) : nil)
        }
    }

    private func sessionID(from data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let direct = object["sessionId"] as? String, validIdentifier(direct) {
            return direct
        }
        if let value = object["value"] as? [String: Any],
           let nested = value["sessionId"] as? String,
           validIdentifier(nested) {
            return nested
        }
        return nil
    }

    private func elementID(from data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? [String: Any] else {
            return nil
        }
        for key in ["element-6066-11e4-a52e-4f735466cecf", "ELEMENT"] {
            if let identifier = value[key] as? String, validIdentifier(identifier) {
                return identifier
            }
        }
        return nil
    }

    private func validIdentifier(_ value: String) -> Bool {
        (8...128).contains(value.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    private func failure(
        _ error: String,
        httpStatus: Int = 0,
        extra: [String: Any] = [:]
    ) -> LocalControlResult {
        var metadata: [String: Any] = [
            "local_wda_reachable": httpStatus > 0,
            "wda_http_status": httpStatus,
            "effect": "none",
            "control_error": error,
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        return LocalControlResult(status: "error", metadata: metadata)
    }

    /// Only fixed relative paths supplied by this type are accepted. Redirects
    /// are rejected by LocalOnlySessionDelegate.
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
        request.timeoutInterval = 12
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
