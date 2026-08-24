import BackgroundTasks
import Combine
import Foundation
import JarvisRSDProbeFFI

/// User-visible execution grant for the fixed on-device XCTest controller.
///
/// This does not create a transport, wake the app silently, or recover a lost
/// RPPairing adapter. It only keeps a controller that the user explicitly
/// started eligible to execute while this app is no longer foreground.
@MainActor
final class ContinuedControllerManager: ObservableObject {
    static let shared = ContinuedControllerManager()

    private let identifierPrefix = "com.forwardinfinity.jarvisrsdprobe.controller."
    private let identifierKey = "jarvis-rsd-controller-task-identifier"
    private let startedKey = "jarvis-rsd-controller-task-started"
    private let duration: TimeInterval = 48 * 60 * 60
    private let timerQueue = DispatchQueue(label: "com.forwardinfinity.jarvisrsdprobe.continued-controller")
    private var registeredIdentifiers = Set<String>()
    private var currentTask: BGContinuedProcessingTask?
    private var timer: DispatchSourceTimer?
    private var startedInThisProcess = false

    @Published private(set) var active = false
    @Published private(set) var status = "Not started"

    private init() {}

    /// Register a pending dynamic identifier during launch. A task restored in
    /// a new process is rejected because its in-memory RSD/DTX handles are gone.
    func registerPendingTask() {
        guard let identifier = UserDefaults.standard.string(forKey: identifierKey) else { return }
        _ = register(identifier: identifier)
    }

    /// Called only as part of the explicit controller button action.
    @discardableResult
    func startFromUserAction() -> Bool {
        if currentTask != nil || startedInThisProcess {
            return true
        }
        let identifier = identifierPrefix + UUID().uuidString.lowercased()
        guard register(identifier: identifier) else {
            publish(active: false, status: "Continued-processing registration rejected")
            return false
        }
        startedInThisProcess = true
        UserDefaults.standard.set(identifier, forKey: identifierKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: startedKey)

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Jarvis local XCTest controller",
            subtitle: "Maintaining fixed loopback WDA control"
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            publish(active: true, status: "Starting visible 48-hour controller protection")
            return true
        } catch {
            startedInThisProcess = false
            clearPersistedTask()
            publish(active: false, status: "Continued-processing submission rejected")
            return false
        }
    }

    func stopFromUserAction() {
        if let identifier = UserDefaults.standard.string(forKey: identifierKey) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        stopControllerHandles()
        finish(success: true, status: "Stopped")
    }

    func stopAfterControllerFailure() {
        stopControllerHandles()
        finish(success: false, status: "Stopped after controller failure")
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
            Task { @MainActor [weak self, weak continued] in
                guard let self, let continued else { return }
                guard self.startedInThisProcess else {
                    continued.setTaskCompleted(success: false)
                    self.clearPersistedTask()
                    self.publish(active: false, status: "Cold restore rejected — controller handles absent")
                    return
                }
                self.begin(continued)
            }
        }
        if accepted {
            registeredIdentifiers.insert(identifier)
        }
        return accepted
    }

    private func begin(_ task: BGContinuedProcessingTask) {
        currentTask = task
        let started = UserDefaults.standard.double(forKey: startedKey)
        let startDate = started > 0 ? Date(timeIntervalSince1970: started) : Date()
        let totalTicks = Int64(duration / 10)
        task.progress.totalUnitCount = totalTicks
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                task?.setTaskCompleted(success: false)
                self?.stopControllerHandles()
                self?.finishWithoutCompleting(status: "Expired by iOS")
            }
        }
        publish(active: true, status: "Active · fixed controller protected")

        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(10), leeway: .seconds(1))
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            let elapsed = max(0, Date().timeIntervalSince(startDate))
            let completed = min(totalTicks, Int64(elapsed / 10))
            task.progress.completedUnitCount = completed
            if completed % 6 == 0 {
                let remainingHours = max(0, Int((self.duration - elapsed) / 3600))
                task.updateTitle(
                    "Jarvis local XCTest controller",
                    subtitle: "Fixed loopback WDA · \(remainingHours)h remaining"
                )
            }
            if elapsed >= self.duration {
                Task { @MainActor [weak self] in
                    self?.stopControllerHandles()
                    self?.finish(success: true, status: "48-hour controller window complete")
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func stopControllerHandles() {
        _ = jarvis_rsd_fixed_wda_stop()
        _ = jarvis_rsd_hold_stop()
    }

    private func finish(success: Bool, status: String) {
        currentTask?.setTaskCompleted(success: success)
        finishWithoutCompleting(status: status)
    }

    private func finishWithoutCompleting(status: String) {
        timer?.cancel()
        timer = nil
        currentTask = nil
        startedInThisProcess = false
        clearPersistedTask()
        publish(active: false, status: status)
    }

    private func clearPersistedTask() {
        UserDefaults.standard.removeObject(forKey: identifierKey)
        UserDefaults.standard.removeObject(forKey: startedKey)
    }

    private func publish(active: Bool, status: String) {
        self.active = active
        self.status = status
    }
}
