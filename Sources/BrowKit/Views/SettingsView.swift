import ServiceManagement
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var addFlow: AddAccountFlow
    let claudeDetected: String?
    @State private var newFolder = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    public init(store: LimitsStore, addFlow: AddAccountFlow, claudeDetected: String?) {
        self.store = store
        self.addFlow = addFlow
        self.claudeDetected = claudeDetected
    }

    private var claudePath: String { store.settings.claudePath ?? claudeDetected ?? "claude" }

    public var body: some View {
        TabView {
            accounts.tabItem { Text("Accounts") }
            general.tabItem { Text("General") }
        }
        .frame(width: 560, height: 420)
        .padding()
    }

    /// `allRows`, not `rows`: a hidden account has to stay listed here or its
    /// "Show" toggle could never be turned back on.
    private var accounts: some View {
        Form {
            ForEach(store.allRows) { row in
                Section {
                    TextField("Name", text: Binding(
                        get: { store.settings.accounts[row.id]?.name ?? "" },
                        set: { store.settings.accounts[row.id, default: AccountOverride(name: nil, hidden: false)].name = $0 }))
                    LabeledContent("Email", value: row.account.email ?? "—")
                    LabeledContent("Tier", value: AccountBlockView.tierLabel(row.account.tier))
                    LabeledContent("Folder") {
                        Text(row.account.configDir + (row.account.aliasDirs.isEmpty ? "" : " (+\(row.account.aliasDirs.count) alias)"))
                            .font(.caption).textSelection(.enabled)
                    }
                    LabeledContent("Token", value: row.tokenStatus)
                    HStack {
                        Toggle("Show", isOn: Binding(
                            get: { !store.settings.isHidden(row.id) },
                            set: { store.settings.accounts[row.id, default: AccountOverride(name: nil, hidden: false)].hidden = !$0 }))
                        Spacer()
                        Button("Open in Terminal") { AddAccountFlow.openInTerminal(dir: row.account.configDir, claudePath: claudePath) }
                    }
                }
            }
            Section("Add account") {
                HStack {
                    TextField("Folder name (e.g. work)", text: $newFolder)
                    Button("Add…") { addFlow.begin(folderName: newFolder, claudePath: claudePath); newFolder = "" }
                        .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Opens Terminal with `claude auth login` for a new folder under ~/.claude-accounts. Sign-in happens in Anthropic's own flow; Brow never sees your password.")
                    .font(.caption).foregroundStyle(.secondary)
                if let s = addFlow.status { Text(s).font(.caption) }
            }
            Section {
                Toggle("Allow `claude -p` fallback", isOn: $store.settings.allowPromptFallback)
                Text("Used only when `claude doctor` fails to refresh a token. Spends a small amount of that account's limit and starts its 5-hour window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { BrowLog.panel.error("launch at login: \(error.localizedDescription, privacy: .public)") }
                }
            Section("Path to claude") {
                TextField("Auto-detected", text: Binding(
                    get: { store.settings.claudePath ?? "" },
                    set: { store.settings.claudePath = $0.isEmpty ? nil : $0 }))
                if let claudeDetected {
                    Text("Detected: \(claudeDetected)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not found. Ran: \(ClaudePathResolver.detectionCommand)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
