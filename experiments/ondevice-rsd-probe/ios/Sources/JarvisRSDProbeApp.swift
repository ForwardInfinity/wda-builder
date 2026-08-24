import SwiftUI
import UniformTypeIdentifiers

@main
struct JarvisRSDProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}

private struct ProbeView: View {
    @StateObject private var controller = ProbeController()
    @State private var showingImporter = false

    private static let pairingTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
        .propertyList,
        .data,
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Safety boundary") {
                    Label("Read-only foreground experiment", systemImage: "checkmark.shield")
                    Text("Fixed endpoint: LocalDevVPN fake peer 10.7.0.1:49152")
                        .font(.footnote.monospaced())
                    Text("No pair-setup, PIN callback, relay, DVT, XCTest, WDA, HID, passcode, or VPS command channel is compiled into this app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Pairing record") {
                    HStack {
                        Text("Device-local record")
                        Spacer()
                        Text(controller.hasPairingRecord ? "Present" : "Absent")
                            .foregroundStyle(controller.hasPairingRecord ? .green : .secondary)
                    }
                    Button {
                        controller.importUSBStagedPairingRecord()
                    } label: {
                        Label("Import fixed USB-staged record", systemImage: "cable.connector")
                    }
                    .disabled(controller.isBusy)
                    Text("Reads only Documents/bootstrap.mobiledevicepairing, then removes it after moving the validated record into Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Import pairing record from Files…") {
                        showingImporter = true
                    }
                    .disabled(controller.isBusy)
                    Button("Delete local pairing record", role: .destructive) {
                        controller.deletePairingRecord()
                    }
                    .disabled(controller.isBusy || !controller.hasPairingRecord)
                }

                Section("Gate 1") {
                    Text("Start LocalDevVPN first, request the official iOS Local Network permission once, then run one bounded probe.")
                        .font(.footnote)
                    Button {
                        controller.requestFixedLocalNetworkAccess()
                    } label: {
                        Label("Request Local Network access", systemImage: "network.badge.shield.half.filled")
                    }
                    .disabled(controller.isBusy)
                    Text("Uses one bounded Network-framework connection to the same fixed 10.7.0.1:49152 endpoint only to trigger the system permission flow. It sends no application data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        controller.runReadOnlyProbe()
                    } label: {
                        Label("Run read-only RSD probe", systemImage: "network.badge.shield.half.filled")
                    }
                    .disabled(
                        controller.isBusy || !controller.hasPairingRecord || controller.hasHeldSession
                    )
                    if controller.isBusy {
                        ProgressView()
                    }
                }

                Section("Warm continuity — read-only") {
                    LabeledContent(
                        "Held adapter",
                        value: controller.hasHeldSession ? "Active" : "None"
                    )
                    Text("This is not cold recoverability. It only tests whether an already-established userspace RSD adapter survives Wi-Fi to Cellular while this foreground app process remains alive. The hold expires after ten minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        controller.startHeldReadOnlySession()
                    } label: {
                        Label("Start held read-only RSD session", systemImage: "link.badge.plus")
                    }
                    .disabled(
                        controller.isBusy || !controller.hasPairingRecord || controller.hasHeldSession
                    )
                    Button {
                        controller.checkHeldReadOnlySession()
                    } label: {
                        Label("Check held RSD session", systemImage: "checkmark.shield")
                    }
                    .disabled(controller.isBusy || !controller.hasHeldSession)
                    Button("Stop held RSD session", role: .destructive) {
                        controller.stopHeldReadOnlySession()
                    }
                    .disabled(controller.isBusy || !controller.hasHeldSession)
                }

                Section("Gate 2 — fixed DTX transports") {
                    Text("Opens exactly one dtservicehub transport and two testmanagerd transports, performs only their DTX capability handshakes, then closes all three. It does not open a DTX service channel, initialise or authorise XCTest, launch a runner, or access WDA/UI input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        controller.runHeldDtxChannelProbe()
                    } label: {
                        Label("Probe three fixed DTX transports", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(controller.isBusy || !controller.hasHeldSession)
                    HStack {
                        Text("dtservicehub")
                        Spacer()
                        Image(systemName: controller.dtxServiceHubReady ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(controller.dtxServiceHubReady ? .green : .secondary)
                    }
                    HStack {
                        Text("testmanagerd control")
                        Spacer()
                        Image(systemName: controller.dtxTestManagerControlReady ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(controller.dtxTestManagerControlReady ? .green : .secondary)
                    }
                    HStack {
                        Text("testmanagerd main")
                        Spacer()
                        Image(systemName: controller.dtxTestManagerMainReady ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(controller.dtxTestManagerMainReady ? .green : .secondary)
                    }
                }

                Section("Sanitized result") {
                    LabeledContent("Status", value: controller.status)
                    LabeledContent("Stage", value: controller.stage)
                    if controller.protocolVersion > 0 {
                        LabeledContent(
                            "Protocol version",
                            value: String(controller.protocolVersion)
                        )
                        LabeledContent(
                            "Advertised services",
                            value: String(controller.advertisedServiceCount)
                        )
                    }
                    ForEach(controller.services) { service in
                        HStack {
                            Text(service.name)
                            Spacer()
                            Image(systemName: service.available ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(service.available ? .green : .secondary)
                                .accessibilityLabel(service.available ? "Available" : "Not observed")
                        }
                    }
                }
            }
            .navigationTitle("Jarvis RSD Probe")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.pairingTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                return
            }
            controller.importPairingRecord(from: url)
        }
    }
}
