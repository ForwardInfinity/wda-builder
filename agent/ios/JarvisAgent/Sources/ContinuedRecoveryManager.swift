import BackgroundTasks
import Combine
import Foundation

@available(iOS 26.0, *)
final class ContinuedRecoveryManager: ObservableObject {
    static let shared = ContinuedRecoveryManager()

    private let identifierPrefix = "com.forwardinfinity.jarvisagent.recovery."
    private let identifierKey = "jarvis-continued-recovery-identifier"
    private let startedKey = "jarvis-continued-recovery-started"
    private let duration: TimeInterval = 48 * 60 * 60
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.continued-recovery")
    private var registeredIdentifiers = Set<String>()
    private var timer: DispatchSourceTimer?
    private var currentTask: BGContinuedProcessingTask?

    @Published private(set) var active = false
    @Published private(set) var status = "Not started"

    private init() {}

    /// Call during application launch so iOS can reconnect a task whose app was
    /// relaunched in the background.
    func registerPendingTask() {
        guard let identifier = UserDefaults.standard.string(forKey: identifierKey) else { return }
        register(identifier: identifier)
    }

    /// This must only be called from an explicit foreground UI action.
    func startFromUserAction() {
        worker.async {
            guard self.currentTask == nil else { return }
            let identifier = self.identifierPrefix + UUID().uuidString.lowercased()
            guard self.register(identifier: identifier) else {
                self.publish(active: false, status: "Registration rejected")
                return
            }
            UserDefaults.standard.set(identifier, forKey: self.identifierKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.startedKey)
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: "Jarvis cellular recovery",
                subtitle: "Maintaining the secure VPS channel"
            )
            request.strategy = .queue
            do {
                try BGTaskScheduler.shared.submit(request)
                self.publish(active: true, status: "Starting 48-hour recovery")
            } catch {
                self.clearPersistedTask()
                self.publish(active: false, status: "Submission rejected")
            }
        }
    }

    func stopFromUserAction() {
        worker.async {
            if let identifier = UserDefaults.standard.string(forKey: self.identifierKey) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
            self.finish(success: true, status: "Stopped")
        }
    }

    @discardableResult
    private func register(identifier: String) -> Bool {
        if registeredIdentifiers.contains(identifier) { return true }
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {
            [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.begin(continued)
        }
        if accepted {
            registeredIdentifiers.insert(identifier)
        }
        return accepted
    }

    private func begin(_ task: BGContinuedProcessingTask) {
        worker.async {
            self.currentTask = task
            let started = UserDefaults.standard.double(forKey: self.startedKey)
            let startDate = started > 0 ? Date(timeIntervalSince1970: started) : Date()
            let totalTicks = Int64(self.duration / 10)
            task.progress.totalUnitCount = totalTicks
            task.expirationHandler = { [weak self, weak task] in
                self?.worker.async {
                    task?.setTaskCompleted(success: false)
                    self?.finishWithoutCompleting(status: "Expired by iOS")
                }
            }
            self.publish(active: true, status: "Active · VPS recovery protected")
            AgentController.shared.continuedRecoveryPulse()

            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .seconds(10), leeway: .seconds(1))
            timer.setEventHandler { [weak self, weak task] in
                guard let self, let task else { return }
                let elapsed = max(0, Date().timeIntervalSince(startDate))
                let completed = min(totalTicks, Int64(elapsed / 10))
                task.progress.completedUnitCount = completed
                AgentController.shared.continuedRecoveryPulse()
                if completed % 6 == 0 {
                    let remainingHours = max(0, Int((self.duration - elapsed) / 3600))
                    task.updateTitle(
                        "Jarvis cellular recovery",
                        subtitle: "Secure VPS channel · \(remainingHours)h remaining"
                    )
                }
                if elapsed >= self.duration {
                    self.finish(success: true, status: "48-hour recovery complete")
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    private func finish(success: Bool, status: String) {
        currentTask?.setTaskCompleted(success: success)
        finishWithoutCompleting(status: status)
    }

    private func finishWithoutCompleting(status: String) {
        timer?.cancel()
        timer = nil
        currentTask = nil
        clearPersistedTask()
        publish(active: false, status: status)
    }

    private func clearPersistedTask() {
        UserDefaults.standard.removeObject(forKey: identifierKey)
        UserDefaults.standard.removeObject(forKey: startedKey)
    }

    private func publish(active: Bool, status: String) {
        DispatchQueue.main.async {
            self.active = active
            self.status = status
        }
    }
}
