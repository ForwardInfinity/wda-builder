import BackgroundTasks
import Combine
import Foundation

@available(iOS 26.0, *)
final class ContinuedRecoveryManager: ObservableObject {
    static let shared = ContinuedRecoveryManager()

    private let identifierPrefix = "com.forwardinfinity.jarvisagent.recovery."
    private let identifierKey = "jarvis-continued-recovery-identifier"
    private let operationStartedKey = "jarvis-continued-recovery-started"
    private let expirationCountKey = "jarvis-continued-recovery-expiration-count"
    private let eventKey = "jarvis-continued-recovery-event"
    private let allocationActiveKey = "jarvis-continued-recovery-allocation-active"
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
            clearPersistedOperation()
            recordEvent("restoration-rejected")
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

            if let oldIdentifier = UserDefaults.standard.string(forKey: self.identifierKey) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: oldIdentifier)
            }
            self.clearPersistedOperation()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.operationStartedKey)
            UserDefaults.standard.set(0, forKey: self.expirationCountKey)
            UserDefaults.standard.set(false, forKey: self.allocationActiveKey)
            self.recordEvent("initial-submit")

            let identifier = self.identifierPrefix + UUID().uuidString.lowercased()
            guard self.register(identifier: identifier) else {
                self.clearPersistedOperation()
                self.recordEvent("submission-rejected")
                self.publish(requested: false, active: false, status: "Registration rejected")
                return
            }
            UserDefaults.standard.set(identifier, forKey: self.identifierKey)
            do {
                try BGTaskScheduler.shared.submit(self.makeRequest(identifier: identifier))
                self.publish(
                    requested: true,
                    active: false,
                    status: "Waiting for visible iOS execution grant"
                )
            } catch {
                self.clearPersistedOperation()
                self.recordEvent("submission-rejected")
                self.publish(requested: false, active: false, status: "Submission rejected")
            }
        }
    }

    func stopFromUserAction() {
        worker.async {
            if let identifier = UserDefaults.standard.string(forKey: self.identifierKey) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
            self.recordEvent("user-stopped")
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

    private func makeRequest(identifier: String) -> BGContinuedProcessingTaskRequest {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Jarvis integrated recovery",
            subtitle: "Secure VPS channel and fixed local controller"
        )
        request.strategy = .queue
        return request
    }

    private func begin(_ task: BGContinuedProcessingTask, identifier: String) {
        worker.async {
            guard UserDefaults.standard.string(forKey: self.identifierKey) == identifier else {
                task.setTaskCompleted(success: false)
                return
            }
            self.currentTask = task
            UserDefaults.standard.set(true, forKey: self.allocationActiveKey)
            self.recordEvent("allocation-active")
            let now = Date().timeIntervalSince1970
            if UserDefaults.standard.double(forKey: self.operationStartedKey) <= 0 {
                UserDefaults.standard.set(now, forKey: self.operationStartedKey)
            }

            task.progress.totalUnitCount = Int64(self.duration / 10)
            task.expirationHandler = { [weak self, weak task] in
                self?.worker.async {
                    guard let self, let task else { return }
                    guard self.currentTask === task else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    UserDefaults.standard.set(
                        UserDefaults.standard.integer(forKey: self.expirationCountKey) + 1,
                        forKey: self.expirationCountKey
                    )
                    self.recordEvent("expiration-callback")
                    AgentController.shared.continuedRecoveryPulse()
                    task.setTaskCompleted(success: false)
                    self.finishWithoutCompleting(status: "Expired by iOS")
                }
            }
            self.publish(requested: true, active: true, status: "Active · integrated Jarvis protected")
            AgentController.shared.continuedRecoveryPulse()
            IntegratedControllerManager.shared.continuedRecoveryBecameActive()
            self.startTimer(task: task)
        }
    }

    private func startTimer(task: BGContinuedProcessingTask) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .seconds(10), leeway: .seconds(1))
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task, self.currentTask === task else { return }
            let started = Date(
                timeIntervalSince1970: UserDefaults.standard.double(forKey: self.operationStartedKey)
            )
            let elapsed = max(0, Date().timeIntervalSince(started))
            task.progress.completedUnitCount = min(
                task.progress.totalUnitCount,
                Int64(elapsed / 10)
            )
            AgentController.shared.continuedRecoveryPulse()
            if task.progress.completedUnitCount % 6 == 0 {
                let remainingHours = max(0, Int((self.duration - elapsed) / 3600))
                task.updateTitle(
                    "Jarvis integrated recovery",
                    subtitle: "VPS + fixed WDA controller · \(remainingHours)h remaining"
                )
            }
            if elapsed >= self.duration {
                self.recordEvent("operation-complete")
                self.finish(success: true, status: "48-hour recovery complete")
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func finish(success: Bool, status: String) {
        currentTask?.setTaskCompleted(success: success)
        finishWithoutCompleting(status: status)
    }

    private func finishWithoutCompleting(status: String) {
        FullUIBridge.shared.stopForRecoveryExpiration()
        IntegratedControllerManager.shared.stopForRecoveryExpiration()
        timer?.cancel()
        timer = nil
        currentTask = nil
        UserDefaults.standard.set(false, forKey: allocationActiveKey)
        clearPersistedOperation()
        publish(requested: false, active: false, status: status)
    }

    private func clearPersistedOperation() {
        UserDefaults.standard.removeObject(forKey: identifierKey)
        UserDefaults.standard.removeObject(forKey: operationStartedKey)
    }

    private func recordEvent(_ event: String) {
        // Values are fixed non-secret state labels; no error descriptions or
        // caller-selected text are persisted.
        UserDefaults.standard.set(event, forKey: eventKey)
    }

    private func publish(requested: Bool, active: Bool, status: String) {
        DispatchQueue.main.async {
            self.requested = requested
            self.active = active
            self.status = status
        }
    }
}
