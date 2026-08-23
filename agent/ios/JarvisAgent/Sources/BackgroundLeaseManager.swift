import Foundation

/// Maintains an authenticated, finite long-poll as a background download.
/// `nsurlsessiond`, not the suspended app process, owns the transfer and
/// reconnects it across Wi-Fi/cellular changes. Each completed lease schedules
/// the next one and gives iOS a supported reason to wake the app briefly.
final class BackgroundLeaseManager: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundLeaseManager()

    private let sessionIdentifier = "com.forwardinfinity.jarvisagent.background-lease.v1"
    private let endpoint = URL(string: "https://workbox.tailfd8ac6.ts.net/v1/lease")!
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.background-lease")
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.forwardinfinity.jarvisagent.background-lease.delegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var scheduling = false
    private var successfulTasks = Set<Int>()
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
        configuration.timeoutIntervalForResource = 5 * 60
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
                    self.scheduling = false
                    if tasks.isEmpty {
                        self.schedule(after: 0)
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

    private func schedule(after delay: TimeInterval) {
        worker.asyncAfter(deadline: .now() + delay) {
            guard let token = KeychainStore.read("agent-token"),
                  let deviceID = KeychainStore.read("device-id"),
                  token.count >= 40,
                  deviceID.count >= 8 else {
                return
            }
            var request = URLRequest(url: self.endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 5 * 60
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceID, forHTTPHeaderField: "X-Jarvis-Device-ID")
            request.setValue("ios-background-lease-1", forHTTPHeaderField: "X-Jarvis-Agent-Version")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            self.session.downloadTask(with: request).resume()
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
            let succeeded = error == nil && self.successfulTasks.remove(task.taskIdentifier) != nil
            self.schedule(after: succeeded ? 0.5 : 5.0)
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
