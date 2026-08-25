import BackgroundTasks
import Combine
import Foundation

@available(iOS 26.0, *)
final class ContinuedRecoveryManager: ObservableObject {
    static let shared = ContinuedRecoveryManager()

    private let identifierPrefix = "com.forwardinfinity.jarvisagent.recovery."
    private let identifierKey = "jarvis-continued-recovery-identifier"
    private let operationStartedKey = "jarvis-continued-recovery-started"
    private let sliceStartedKey = "jarvis-continued-recovery-slice-started"
    private let handoffProofKey = "jarvis-continued-recovery-handoff-proof"
    private let handoffCountKey = "jarvis-continued-recovery-handoff-count"
    private let expirationCountKey = "jarvis-continued-recovery-expiration-count"
    private let eventKey = "jarvis-continued-recovery-event"
    private let allocationActiveKey = "jarvis-continued-recovery-allocation-active"
    private let overallDuration: TimeInterval = 48 * 60 * 60
    // iOS ended the prior allocation before its four-hour target. Rotate one
    // visible operation every twenty minutes, well before that observed bound.
    private let normalSliceDuration: TimeInterval = 20 * 60
    private let initialProofSliceDuration: TimeInterval = 3 * 60
    private let rolloverRetryDelay: TimeInterval = 60
    private let maximumRolloverSubmissionAttempts = 3
    private let worker = DispatchQueue(label: "com.forwardinfinity.jarvisagent.continued-recovery")
    private var registeredIdentifiers = Set<String>()
    private var timer: DispatchSourceTimer?
    private var currentTask: BGContinuedProcessingTask?
    private var rolloverInProgress = false
    private var rolloverSubmissionAttempts = 0
    private var nextRolloverAttempt = Date.distantPast

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

            // Cancel a stale request before creating the one and only execution
            // owner for this explicit 48-hour operation.
            if let oldIdentifier = UserDefaults.standard.string(forKey: self.identifierKey) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: oldIdentifier)
            }
            self.clearPersistedOperation()
            let now = Date().timeIntervalSince1970
            UserDefaults.standard.set(now, forKey: self.operationStartedKey)
            UserDefaults.standard.set(false, forKey: self.handoffProofKey)
            UserDefaults.standard.set(0, forKey: self.handoffCountKey)
            UserDefaults.standard.set(0, forKey: self.expirationCountKey)
            UserDefaults.standard.set(false, forKey: self.allocationActiveKey)
            self.recordEvent("initial-submit")
            guard self.submitInitialRequest() else {
                self.clearPersistedOperation()
                self.publish(requested: false, active: false, status: "Submission rejected")
                return
            }
            self.publish(
                requested: true,
                active: false,
                status: "Waiting for visible iOS execution grant"
            )
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

    private func makeRequest(identifier: String) -> BGContinuedProcessingTaskRequest {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Jarvis integrated recovery",
            subtitle: "Secure VPS channel and fixed local controller"
        )
        request.strategy = .queue
        return request
    }

    private func submitInitialRequest() -> Bool {
        let identifier = identifierPrefix + UUID().uuidString.lowercased()
        guard register(identifier: identifier) else { return false }
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(identifier, forKey: identifierKey)
        UserDefaults.standard.set(now, forKey: sliceStartedKey)
        do {
            try BGTaskScheduler.shared.submit(makeRequest(identifier: identifier))
            return true
        } catch {
            UserDefaults.standard.removeObject(forKey: identifierKey)
            UserDefaults.standard.removeObject(forKey: sliceStartedKey)
            return false
        }
    }

    /// Queue the successor before completing the current allocation. This is a
    /// rolling handoff of one user-visible 48-hour operation, not a hidden wake
    /// mechanism. In-memory RSD/DTX handles remain owned by this process.
    private func submitSuccessor(completingCurrentSuccessfully: Bool) -> Bool {
        guard let oldTask = currentTask, !rolloverInProgress else { return false }
        let oldIdentifier = UserDefaults.standard.string(forKey: identifierKey)
        let oldSliceStart = UserDefaults.standard.object(forKey: sliceStartedKey)
        let identifier = identifierPrefix + UUID().uuidString.lowercased()
        guard register(identifier: identifier) else { return false }

        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(identifier, forKey: identifierKey)
        UserDefaults.standard.set(now, forKey: sliceStartedKey)
        do {
            try BGTaskScheduler.shared.submit(makeRequest(identifier: identifier))
        } catch {
            if let oldIdentifier {
                UserDefaults.standard.set(oldIdentifier, forKey: identifierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: identifierKey)
            }
            if let oldSliceStart {
                UserDefaults.standard.set(oldSliceStart, forKey: sliceStartedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sliceStartedKey)
            }
            return false
        }

        rolloverInProgress = true
        UserDefaults.standard.set(true, forKey: handoffProofKey)
        UserDefaults.standard.set(
            UserDefaults.standard.integer(forKey: handoffCountKey) + 1,
            forKey: handoffCountKey
        )
        UserDefaults.standard.set(false, forKey: allocationActiveKey)
        recordEvent("handoff-submitted")
        timer?.cancel()
        timer = nil
        currentTask = nil
        oldTask.setTaskCompleted(success: completingCurrentSuccessfully)
        publish(
            requested: true,
            active: false,
            status: "Rolling visible execution handoff"
        )
        return true
    }

    private func begin(_ task: BGContinuedProcessingTask, identifier: String) {
        worker.async {
            guard UserDefaults.standard.string(forKey: self.identifierKey) == identifier else {
                task.setTaskCompleted(success: false)
                return
            }
            self.currentTask = task
            self.rolloverInProgress = false
            self.rolloverSubmissionAttempts = 0
            UserDefaults.standard.set(true, forKey: self.allocationActiveKey)
            self.recordEvent("allocation-active")
            self.nextRolloverAttempt = .distantPast

            let now = Date().timeIntervalSince1970
            if UserDefaults.standard.double(forKey: self.operationStartedKey) <= 0 {
                UserDefaults.standard.set(now, forKey: self.operationStartedKey)
            }
            if UserDefaults.standard.double(forKey: self.sliceStartedKey) <= 0 {
                UserDefaults.standard.set(now, forKey: self.sliceStartedKey)
            }
            let sliceLimit = UserDefaults.standard.bool(forKey: self.handoffProofKey)
                ? self.normalSliceDuration
                : self.initialProofSliceDuration
            task.progress.totalUnitCount = Int64(sliceLimit / 10)
            task.expirationHandler = { [weak self, weak task] in
                self?.worker.async {
                    guard let self, let task else { return }
                    guard self.currentTask === task else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    // One bounded emergency handoff while iOS still grants the
                    // expiration callback. Failure ends everything fail-closed.
                    UserDefaults.standard.set(
                        UserDefaults.standard.integer(forKey: self.expirationCountKey) + 1,
                        forKey: self.expirationCountKey
                    )
                    self.recordEvent("expiration-callback")
                    AgentController.shared.continuedRecoveryPulse()
                    if !self.submitSuccessor(completingCurrentSuccessfully: false) {
                        self.recordEvent("expiration-handoff-rejected")
                        task.setTaskCompleted(success: false)
                        self.finishWithoutCompleting(status: "Expired by iOS; handoff rejected")
                    }
                }
            }
            self.publish(requested: true, active: true, status: "Active · integrated Jarvis protected")
            AgentController.shared.continuedRecoveryPulse()
            IntegratedControllerManager.shared.continuedRecoveryBecameActive()
            self.startTimer(task: task, sliceLimit: sliceLimit)
        }
    }

    private func startTimer(task: BGContinuedProcessingTask, sliceLimit: TimeInterval) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .seconds(10), leeway: .seconds(1))
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task, self.currentTask === task else { return }
            let now = Date()
            let operationStarted = Date(
                timeIntervalSince1970: UserDefaults.standard.double(forKey: self.operationStartedKey)
            )
            let sliceStarted = Date(
                timeIntervalSince1970: UserDefaults.standard.double(forKey: self.sliceStartedKey)
            )
            let totalElapsed = max(0, now.timeIntervalSince(operationStarted))
            let sliceElapsed = max(0, now.timeIntervalSince(sliceStarted))
            task.progress.completedUnitCount = min(
                task.progress.totalUnitCount,
                Int64(sliceElapsed / 10)
            )
            AgentController.shared.continuedRecoveryPulse()

            if task.progress.completedUnitCount % 6 == 0 {
                let remainingHours = max(0, Int((self.overallDuration - totalElapsed) / 3600))
                task.updateTitle(
                    "Jarvis integrated recovery",
                    subtitle: "VPS + fixed WDA controller · \(remainingHours)h remaining"
                )
            }
            if totalElapsed >= self.overallDuration {
                self.finish(success: true, status: "48-hour recovery complete")
                return
            }
            guard sliceElapsed >= sliceLimit,
                  self.rolloverSubmissionAttempts < self.maximumRolloverSubmissionAttempts,
                  now >= self.nextRolloverAttempt else { return }
            if !self.submitSuccessor(completingCurrentSuccessfully: true) {
                self.rolloverSubmissionAttempts += 1
                self.recordEvent("proactive-handoff-deferred")
                self.nextRolloverAttempt = now.addingTimeInterval(self.rolloverRetryDelay)
                self.publish(
                    requested: true,
                    active: true,
                    status: "Execution handoff deferred · attempt \(self.rolloverSubmissionAttempts)/\(self.maximumRolloverSubmissionAttempts)"
                )
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
        IntegratedControllerManager.shared.stopForRecoveryExpiration()
        timer?.cancel()
        timer = nil
        currentTask = nil
        rolloverInProgress = false
        UserDefaults.standard.set(false, forKey: allocationActiveKey)
        clearPersistedOperation()
        publish(requested: false, active: false, status: status)
    }

    private func clearPersistedOperation() {
        UserDefaults.standard.removeObject(forKey: identifierKey)
        UserDefaults.standard.removeObject(forKey: operationStartedKey)
        UserDefaults.standard.removeObject(forKey: sliceStartedKey)
        UserDefaults.standard.removeObject(forKey: handoffProofKey)
    }

    private func recordEvent(_ event: String) {
        // Values are fixed non-secret state labels consumed by heartbeat
        // telemetry; no error descriptions or caller-selected text are stored.
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
