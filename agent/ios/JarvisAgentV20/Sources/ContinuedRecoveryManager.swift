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

    /// `requested` means iOS accepted or restored a request. `active` becomes
    /// true only inside the BGContinuedProcessingTask callback, never merely
    /// because submission succeeded.
    @Published private(set) var requested = false
    @Published private(set) var active = false
    @Published private(set) var status = "Not started"

    private init() {}

    /// Called during app launch so a task created by this same bundle can be
    /// restored. The fixed controller itself is never assumed to survive a
    /// process death; it starts only after a fresh explicit UI action.
    func registerPendingTask() {
        guard let identifier = UserDefaults.standard.string(forKey: identifierKey) else { return }
        if register(identifier: identifier) {
            publish(requested: true, active: false, status: "Restoring visible recovery task")
        } else {
            clearPersistedTask()
            publish(requested: false, active: false, status: "Recovery restoration rejected")
        }
    }

    /// Must only be reached from the explicit integrated-controller UI action.
    func startFromUserAction() {
        worker.async {
            if self.currentTask != nil {
                self.publish(requested: true, active: true, status: "Active · integrated Jarvis protected")
                IntegratedControllerManager.shared.continuedRecoveryBecameActive()
                return
            }

            // Cancel a stale v19 request before creating the one and only v20
            // execution owner. This prevents an old queued request from
            // blocking the integrated controller indefinitely.
            if let oldIdentifier = UserDefaults.standard.string(forKey: self.identifierKey) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: oldIdentifier)
                self.clearPersistedTask()
            }

            let identifier = self.identifierPrefix + UUID().uuidString.lowercased()
            guard self.register(identifier: identifier) else {
                self.publish(requested: false, active: false, status: "Registration rejected")
                return
            }
            UserDefaults.standard.set(identifier, forKey: self.identifierKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.startedKey)
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: "Jarvis integrated recovery",
                subtitle: "Secure VPS channel and fixed local controller"
            )
            request.strategy = .queue
            do {
                try BGTaskScheduler.shared.submit(request)
                self.publish(requested: true, active: false, status: "Waiting for visible iOS execution grant")
            } catch {
                self.clearPersistedTask()
                self.publish(requested: false, active: false, status: "Submission rejected")
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
            self?.begin(continued, identifier: identifier)
        }
        if accepted {
            registeredIdentifiers.insert(identifier)
        }
        return accepted
    }

    private func begin(_ task: BGContinuedProcessingTask, identifier: String) {
        worker.async {
            guard UserDefaults.standard.string(forKey: self.identifierKey) == identifier else {
                task.setTaskCompleted(success: false)
                return
            }
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
            self.publish(requested: true, active: true, status: "Active · integrated Jarvis protected")
            AgentController.shared.continuedRecoveryPulse()
            IntegratedControllerManager.shared.continuedRecoveryBecameActive()

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
                        "Jarvis integrated recovery",
                        subtitle: "VPS + fixed WDA controller · \(remainingHours)h remaining"
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
        IntegratedControllerManager.shared.stopForRecoveryExpiration()
        timer?.cancel()
        timer = nil
        currentTask = nil
        clearPersistedTask()
        publish(requested: false, active: false, status: status)
    }

    private func clearPersistedTask() {
        UserDefaults.standard.removeObject(forKey: identifierKey)
        UserDefaults.standard.removeObject(forKey: startedKey)
    }

    private func publish(requested: Bool, active: Bool, status: String) {
        DispatchQueue.main.async {
            self.requested = requested
            self.active = active
            self.status = status
        }
    }
}
