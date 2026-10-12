import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var status = Note()
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { status.login }, set: { on in
                    status.text = LoginItem.set(on) ?? ""
                    status.login = LoginItem.enabled
                }))
                Toggle("Check for updates daily", isOn: $updater.daily)
                HStack {
                    Text(updater.line).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer()
                    if case .available(let tag) = updater.phase, LoginItem.installed {
                        Button("Update to \(tag)") { Task { await updater.update(to: tag) } }
                    }
                    Button("Check now") { Task { await updater.check() } }.disabled(updater.busy)
                }
            }

            AlertsSection(notifier: model.notifier, changed: model.refresh, test: model.testAlert)

            Section("Pricing") {
                Text(model.pricing.url.path).font(.caption).textSelection(.enabled)
                Text("Regional premium applies to messages from regional or US-only endpoints. \(model.transcripts.endpoints.summary).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open pricing.json") { NSWorkspace.shared.open(model.pricing.url) }
                    Button("Re-read all transcripts") { model.transcripts.rescanFromZero() }
                }
            }

            Section("Claude Code telemetry") {
                HStack {
                    Text(model.telemetry.line).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    switch model.telemetry.action {
                    case .setUp?: Button("Set up telemetry") { model.changeTelemetry(.setUp) }
                    case .remove?: Button("Remove") { model.changeTelemetry(.remove) }
                    case nil: EmptyView()
                    }
                }
                if let e = model.telemetryError ?? model.otel?.lastError {
                    Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Telemetry adds the calls Claude Code doesn't write to transcripts. Burn receives its logs on 127.0.0.1:\(Telemetry.port) and nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onAppear(perform: model.checkTelemetry)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.checkTelemetry() }

            if !status.text.isEmpty { Text(status.text).font(.caption) }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so it has no height of its own; without this the window opens empty.
        .frame(width: 540, height: 740)
        .padding()
    }
}

struct AlertsSection: View {
    @ObservedObject var notifier: Notifier
    let changed: () -> Void
    let test: () -> Void
    @AppStorage("alert.sound") private var sound = Settings.defaultSound
    @AppStorage("alert.day") private var daily: Double?
    @AppStorage("alert.week") private var weekly: Double?
    @AppStorage("alert.month") private var monthly: Double?

    var body: some View {
        Section("Alerts") {
            AmountField(label: "Daily", amount: amount($daily))
            AmountField(label: "Weekly", amount: amount($weekly))
            AmountField(label: "Monthly", amount: amount($monthly))
            Picker("Sound", selection: Binding(get: { sound }, set: { sound = $0; NSSound(named: $0)?.play() })) {
                Text("None").tag("")
                ForEach(Settings.systemSounds, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                switch notifier.status {
                case .denied?:
                    Text("Notifications are turned off for Burn.")
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                case .authorized?, .provisional?:
                    Text("Notifications allowed.")
                default:
                    Text("Notifications not requested yet.")
                }
                Spacer()
                Button("Send test notification", action: test)
            }
            if !notifier.error.isEmpty { Text(notifier.error).font(.caption).foregroundStyle(.red) }
            Text("Each alert fires once per period; changing the amount re-arms it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: notifier.refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in notifier.refreshStatus() }
    }

    private func amount(_ stored: Binding<Double?>) -> Binding<Double?> {
        Binding(get: { stored.wrappedValue }, set: {
            guard $0 != stored.wrappedValue else { return }
            stored.wrappedValue = $0
            if $0 != nil { notifier.authorize() }
            changed()
        })
    }
}

/// Saves on Return or focus loss only; a value TextField saves each keystroke, so typing 100 fired a $1 alert.
private struct AmountField: View {
    let label: String
    @Binding var amount: Double?
    @StateObject private var draft = Draft()
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 2) {
                Text("$").foregroundStyle(.secondary)
                TextField(label, text: $draft.text, prompt: Text("Off"))
                    .labelsHidden()
                    .frame(width: 80)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
            }
        }
        .onAppear(perform: show)
    }

    private func commit() {
        amount = try? Double(draft.text, format: .number)
        show()
    }

    private func show() { draft.text = amount?.formatted(.number) ?? "" }
}

private final class Draft: ObservableObject {
    @Published var text = ""
}

final class Note: ObservableObject {
    @Published var text = ""
    @Published var login = LoginItem.enabled
}
