import BackgroundTasks
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshIdentifier = "com.forwardinfinity.jarvisagent.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(refresh)
        }
        if #available(iOS 26.0, *) {
            ContinuedRecoveryManager.shared.registerPendingTask()
        }
        AgentController.shared.start()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AgentController.shared.appEnteredBackground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AgentController.shared.appBecameActive()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundLeaseManager.shared.handleEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // iOS may coalesce or reject a duplicate request; the foreground
            // reconnect loop remains active and will schedule again later.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let lock = NSLock()
        var completed = false
        func finish(_ success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { finish(false) }
        AgentController.shared.performBackgroundRefresh { finish($0) }
    }
}

@main
struct JarvisAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var agent = AgentController.shared
    @State private var recoveryRequested = false
    @State private var devicePasscode = ""
    @State private var passcodeStatus = ""

    var body: some Scene {
        WindowGroup {
            NavigationView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Jarvis Reverse Agent", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.title2.bold())

                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 10) {
                            row("Status", agent.status)
                            row("Network", agent.path)
                            row("Enrolled", agent.enrolled ? "Yes" : "No")
                            row("Last heartbeat", agent.lastSeen)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if #available(iOS 26.0, *) {
                        GroupBox("Always-on recovery") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Starts a visible 48-hour iOS continued-processing session so Jarvis can reconnect to the VPS after a cellular socket is lost.")
                                    .font(.footnote)
                                Button(recoveryRequested ? "Recovery requested" : "Start 48-Hour Recovery") {
                                    ContinuedRecoveryManager.shared.startFromUserAction()
                                    recoveryRequested = true
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(recoveryRequested)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("Device-local unlock") {
                        VStack(alignment: .leading, spacing: 10) {
                            if agent.unlockProvisioned {
                                Label("Six-digit passcode protected in this iPhone Keychain", systemImage: "checkmark.shield")
                                    .font(.footnote)
                                Button("Remove Local Unlock Secret", role: .destructive) {
                                    agent.removeDevicePasscode()
                                    devicePasscode = ""
                                    passcodeStatus = "Removed"
                                }
                            } else {
                                Text("Enter once on-device. It never enters a VPS request or result.")
                                    .font(.footnote)
                                SecureField("Six-digit iPhone passcode", text: $devicePasscode)
                                    .keyboardType(.numberPad)
                                    .textContentType(.password)
                                Button("Save in This iPhone Keychain") {
                                    let accepted = agent.provisionDevicePasscode(devicePasscode)
                                    devicePasscode = ""
                                    passcodeStatus = accepted ? "Saved locally" : "Exactly six digits required"
                                }
                                .buttonStyle(.bordered)
                            }
                            if !passcodeStatus.isEmpty {
                                Text(passcodeStatus).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("Only allowlisted command outcomes leave the device. Passcode, screenshots, UI trees, photos, messages, and location are never sent to the VPS.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding()
                .navigationTitle("Jarvis Agent")
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
