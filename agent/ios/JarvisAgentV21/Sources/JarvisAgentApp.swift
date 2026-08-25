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
    @StateObject private var recovery = ContinuedRecoveryManager.shared
    @StateObject private var integratedController = IntegratedControllerManager.shared
    @StateObject private var fullUI = FullUIBridge.shared
    @State private var devicePasscode = ""
    @State private var passcodeStatus = ""

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("Jarvis Integrated Agent", systemImage: "antenna.radiowaves.left.and.right")
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

                        GroupBox("Single execution owner") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("One visible 48-hour iOS Continued Processing task owns both the authenticated VPS channel and the fixed local XCTest controller.")
                                    .font(.footnote)
                                row("Recovery", recovery.status)
                                if recovery.requested {
                                    Button("Stop integrated recovery", role: .destructive) {
                                        recovery.stopFromUserAction()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GroupBox("Integrated fixed controller") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Fixed LocalDevVPN peer 10.7.0.1:49152, fixed WDA runner, and loopback WDA only. No VPS-selected host, port, bundle, selector, or pairing bytes.")
                                    .font(.footnote)
                                row("Pairing record", integratedController.pairingPresent ? "Present" : "Absent")
                                row("Status", integratedController.status)
                                row("Stage", integratedController.stage)
                                Button("Import fixed USB-staged record") {
                                    integratedController.importUSBStagedPairingRecord()
                                }
                                .disabled(integratedController.busy || integratedController.controllerActive)
                                Button("Request fixed Local Network access") {
                                    integratedController.requestFixedLocalNetworkAccess()
                                }
                                .disabled(integratedController.busy || integratedController.controllerActive)
                                Button("Start Full Jarvis") {
                                    fullUI.enableFromUserAction()
                                    integratedController.startProtectedFromUserAction()
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(
                                    integratedController.busy
                                        || integratedController.controllerActive
                                        || !integratedController.pairingPresent
                                )
                                if integratedController.controllerActive {
                                    Button("Check integrated controller") {
                                        integratedController.check()
                                    }
                                    Button("Stop integrated controller", role: .destructive) {
                                        integratedController.stopFromUserAction()
                                    }
                                }
                                Text("If iOS presents a real XCTest authorization prompt, enter it only directly on this iPhone.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GroupBox("Full UI from VPS") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Explicit opt-in for unlocked screens. VPS may receive screenshots/UI trees and send bounded WDA tap, swipe, type, app, and URL actions. Every generic request is rejected while the iPhone is locked.")
                                    .font(.footnote)
                                row("Full UI", fullUI.status)
                                if fullUI.enabled {
                                    Button("Disable Full UI", role: .destructive) {
                                        fullUI.disableFromUserAction()
                                    }
                                } else {
                                    Button("Enable Full UI") {
                                        fullUI.enableFromUserAction()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!recovery.active || !integratedController.controllerActive)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
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

                        Text("Pairing material and passcode never leave this iPhone. During an explicitly enabled Full UI session, unlocked-screen screenshots, UI trees, and operator-requested text may traverse the authenticated VPS channel in root-only bounded files.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
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
