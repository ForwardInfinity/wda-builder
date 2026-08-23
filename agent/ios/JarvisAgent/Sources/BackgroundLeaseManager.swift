import Foundation

/// Maintains an authenticated long-lived stream as a background download.
/// `nsurlsessiond`, not the suspended app process, owns each task. In addition
/// to the active stream, a bounded set of future background tasks is submitted
/// up front. If iOS defers the active task's failure callback, a pre-submitted
/// recovery slot can still establish a fresh stream without running app code.
final class BackgroundLeaseManager: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundLeaseManager()

    private let sessionIdentifier = "com.forwardinfinity.jarvisagent.background-stream.v2"
    private let endpoint = URL(string: "https://workbox.tailfd8ac6.ts.net/v1/stream")!
    private let recoverySlotCount = 24
    private let recoverySlotSpacing: TimeInterval = 30
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.background-stream")
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.forwardinfinity.jarvisagent.background-stream.delegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var scheduling = false
    private var successfulTasks = Set<Int>()
    private var ignoredCompletionTasks = Set<Int>()
    private var eventsCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 8 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private override init() {
        super.init()
    }

    func start() {
        worker.async {
            guard !self.scheduling else { return }
            self.scheduling = true
            self.session.getAllTasks { tasks in
                self.worker.async {
                    defer { self.scheduling = false }
                    guard let request = self.makeRequest() else { return }
                    let hasPrimary = tasks.contains { $0.taskDescription == "primary" }
                    let hasRecoverySlots = tasks.contains {
                        $0.taskDescription?.hasPrefix("recovery-") == true
                    }
                    if !hasPrimary {
                        self.enqueue(request: request, delay: 0, description: "primary")
                    }
                    if !hasRecoverySlots {
                        for slot in 1...self.recoverySlotCount {
                            self.enqueue(
                                request: request,
                                delay: TimeInterval(slot) * self.recoverySlotSpacing,
                                description: String(format: "recovery-%03d", slot)
                            )
                        }
                    }
                }
            }
        }
    }

    func forceReconnect() {
        worker.async {
            self.session.getAllTasks { tasks in
                self.worker.async {
                    self.ignoredCompletionTasks.formUnion(tasks.map(\.taskIdentifier))
                    tasks.forEach { $0.cancel() }
                    self.worker.asyncAfter(deadline: .now() + 1) {
                        guard let request = self.makeRequest() else { return }
                        self.enqueue(request: request, delay: 0, description: "primary")
                    }
                }
            }
        }
    }

    func handleEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == sessionIdentifier else {
            completionHandler()
            return
        }
        worker.async {
            self.eventsCompletionHandler = completionHandler
            _ = self.session
        }
    }

    private func makeRequest() -> URLRequest? {
        guard let token = KeychainStore.read("agent-token"),
              let deviceID = KeychainStore.read("device-id"),
              token.count >= 40,
              deviceID.count >= 8 else {
            return nil
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8 * 24 * 60 * 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-Jarvis-Device-ID")
        request.setValue("ios-background-stream-2", forHTTPHeaderField: "X-Jarvis-Agent-Version")
        request.setValue(
            UserDefaults.standard.string(forKey: "jarvis-network") ?? "Unknown",
            forHTTPHeaderField: "X-Jarvis-Network"
        )
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func enqueue(request: URLRequest, delay: TimeInterval, description: String) {
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        if delay > 0 {
            task.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        }
        task.resume()
    }

    private func schedulePrimary(after delay: TimeInterval) {
        worker.asyncAfter(deadline: .now() + delay) {
            guard let request = self.makeRequest() else { return }
            self.enqueue(request: request, delay: 0, description: "primary")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        worker.async {
            if (200..<300).contains(status) {
                self.successfulTasks.insert(downloadTask.taskIdentifier)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        worker.async {
            if self.ignoredCompletionTasks.remove(task.taskIdentifier) != nil {
                self.successfulTasks.remove(task.taskIdentifier)
                return
            }
            let succeeded = error == nil && self.successfulTasks.remove(task.taskIdentifier) != nil
            if task.taskDescription?.hasPrefix("recovery-") == true {
                return
            }
            self.schedulePrimary(after: succeeded ? 0.5 : 5.0)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        worker.async {
            let completion = self.eventsCompletionHandler
            self.eventsCompletionHandler = nil
            DispatchQueue.main.async { completion?() }
        }
    }
}
