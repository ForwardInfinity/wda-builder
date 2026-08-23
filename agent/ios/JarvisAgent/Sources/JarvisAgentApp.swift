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

                    Text("This prototype sends only authenticated health heartbeats. It does not read the passcode, screen, photos, messages, or location.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("Keep this screen open for the first cellular reconnect test.")
                        .font(.callout.bold())

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
