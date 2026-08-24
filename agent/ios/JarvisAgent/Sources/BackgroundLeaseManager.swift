import Foundation

/// Cancels the legacy V3/V4 background download streams.
///
/// Those streams proved that nsurlsessiond could finish an in-flight transfer,
/// but iOS deferred their reconnect callbacks after a broken socket. They are
/// not a production keepalive and can survive an app upgrade under the stable
/// background-session identifier. V19 never creates a stream task; it only
/// attaches to that identifier long enough to cancel any inherited tasks.
final class BackgroundLeaseManager: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundLeaseManager()

    private let sessionIdentifier = "com.forwardinfinity.jarvisagent.background-stream.v2"
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.legacy-stream-cleaner")
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.forwardinfinity.jarvisagent.legacy-stream-cleaner.delegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var eventsCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private override init() {
        super.init()
    }

    func cancelLegacyTasks() {
        worker.async {
            self.session.getAllTasks { tasks in
                self.worker.async {
                    tasks.forEach { $0.cancel() }
                    if tasks.isEmpty {
                        self.finishEventsIfNeeded()
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
            self.cancelLegacyTasks()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // A completion racing the upgrade is discarded. No response body is
        // inspected, copied, or persisted by the Agent.
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        worker.async { self.finishEventsIfNeeded() }
    }

    private func finishEventsIfNeeded() {
        let completion = eventsCompletionHandler
        eventsCompletionHandler = nil
        DispatchQueue.main.async { completion?() }
    }
}
