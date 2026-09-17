import ServiceManagement
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var addFlow: AddAccountFlow
    /// Names typed but not committed yet. Held outside the view tree so closing the
    /// window cannot discard them — see `SettingsDrafts`.
    let drafts: SettingsDrafts
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    public init(store: LimitsStore, addFlow: AddAccountFlow, drafts: SettingsDrafts) {
        self.store = store
        self.addFlow = addFlow
        self.drafts = drafts
    }

    /// The RAW auto-detection result, never the effective path: its only job is to
    /// choose between "Detected: X" and the "Not found. Ran: …" diagnostic, and using
    /// the effective value hid a failed detection behind the user's own override — the
    /// UI then claimed the override had been auto-detected.
    ///
    /// Read LIVE from the store, never captured: this window is built once and cached,
    /// and `Cmd-,` is live long before the `/bin/zsh -lic` detection returns, so a
    /// captured value stayed nil ("Not found. Ran: …") for the rest of the session.
    private var claudeDetected: String? { store.claudeDetected }

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
            Section {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add an account").font(.headline)
                        Text("One click: Terminal opens with Anthropic's sign-in; Brow does the rest.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Nothing to pick or name: the folder is chosen for the user
                    // (~/.claude-accounts/account-N) and the sign-in is Anthropic's own.
                    Button { addFlow.quickAdd(claudePath: claudePath) } label: {
                        Label("Sign in…", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    // For a config folder that already exists somewhere else.
                    Button("Existing folder…") {
                        if let dir = addFlow.chooseFolder() { addFlow.begin(dir: dir) }
                    }
                }
                if let dir = addFlow.pendingDir {
                    let command = AddAccountFlow.launchCommand(dir: dir)
                    HStack {
                        Text(command).font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { AddAccountFlow.copyToPasteboard(command) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button("Open in Terminal") { AddAccountFlow.openInTerminal(dir: dir, claudePath: claudePath) }
                    }
                }
                if let s = addFlow.status { Text(s).font(.caption) }
            }
            ForEach(store.allRows) { row in
                Section {
                    // Committed on Return / focus loss / window close, not on every
                    // keystroke: each write of `store.settings` is a synchronous atomic
                    // JSON write plus a full recompute plus a panel re-render with a
                    // 0.18 s animation.
                    AccountNameField(accountID: row.id, initial: store.settings.accounts[row.id]?.name ?? "",
                                     drafts: drafts, store: store)
                    LabeledContent("Email", value: row.account.email ?? "—")
                    LabeledContent("Tier", value: PanelText.tierLabel(row.account.tier))
                    LabeledContent("Folder") {
                        Text(row.account.configDir + (row.account.aliasDirs.isEmpty ? "" : " (+\(row.account.aliasDirs.count) alias)"))
                            .font(.caption).textSelection(.enabled)
                    }
                    LabeledContent("Token", value: row.tokenStatus)
                    // The command that runs Claude Code as this account, in plain sight:
                    // paste it into any terminal. The copy button sits right on it.
                    LabeledContent("Launch") {
                        let command = AddAccountFlow.launchCommand(dir: row.account.configDir)
                        HStack(spacing: 6) {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Button { AddAccountFlow.copyToPasteboard(command) } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy the launch command")
                        }
                    }
                    HStack {
                        Toggle("Show", isOn: Binding(
                            get: { !store.settings.isHidden(row.id) },
                            set: { store.settings.accounts[row.id, default: AccountOverride(name: nil, hidden: false)].hidden = !$0 }))
                        Spacer()
                        Button {
                            AddAccountFlow.copyToPasteboard(AddAccountFlow.launchCommand(dir: row.account.configDir))
                        } label: { Label("Copy launch command", systemImage: "doc.on.doc") }
                        Button("Open in Terminal") { AddAccountFlow.openInTerminal(dir: row.account.configDir, claudePath: claudePath) }
                        Button {
                            AddAccountFlow.login(dir: row.account.configDir, claudePath: claudePath)
                        } label: { Label("Sign in again", systemImage: "person.badge.key") }
                            .help("Opens Terminal with `claude auth login` for this account; the browser window is this account's own profile.")
                    }
                    HStack {
                        Text("Browser profile: signed-in Google/claude.ai sessions persist here, like any Chrome profile.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            AddAccountFlow.openBrowserProfile(dir: row.account.configDir)
                        } label: { Label("Open browser profile", systemImage: "globe") }
                            .help("Open this account's own Chrome profile on claude.ai — sign into Google/claude.ai there once and every later `claude auth login` is one click.")
                    }
                }
            }
            Section {
                Toggle("Allow `claude -p` fallback", isOn: $store.settings.allowPromptFallback)
                Text("Used only when `claude doctor` fails to refresh a token. Spends a small amount of that account's limit and starts its 5-hour window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A name field whose edits stay local until the user is done with them — but
    /// every keystroke is recorded in `drafts`, which outlives this view. Closing the
    /// window destroys the SwiftUI tree and this `@State` with it, and the focus-loss
    /// change is not guaranteed to be delivered first, so a rename typed and then
    /// "finished" with Cmd-W used to be silently discarded. `drafts` is what
    /// `windowWillClose` flushes.
    private struct AccountNameField: View {
        let accountID: String
        let initial: String
        let drafts: SettingsDrafts
        let store: LimitsStore
        @State private var text: String
        @FocusState private var focused: Bool

        init(accountID: String, initial: String, drafts: SettingsDrafts, store: LimitsStore) {
            self.accountID = accountID
            self.initial = initial
            self.drafts = drafts
            self.store = store
            _text = State(initialValue: initial)
        }

        var body: some View {
            TextField("Name", text: $text)
                .focused($focused)
                .onChange(of: text) { _, value in drafts.record(value, for: accountID) }
                .onSubmit { drafts.flush(into: store) }
                .onChange(of: focused) { _, isFocused in if !isFocused { drafts.flush(into: store) } }
                .onChange(of: initial) { _, value in if !focused { text = value } }
        }
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { BrowLog.panel.error("launch at login: \(error.localizedDescription, privacy: .public)") }
                }
            Section {
                Toggle("Show readouts next to the notch", isOn: $store.settings.showEars)
                Text("Off: nothing is drawn until the pointer reaches the notch itself; the panel then opens with its animation.")
                    .font(.caption).foregroundStyle(.secondary)
                // The store writes config.json and publishes on every change, and the
                // panel re-reads `earsPlacement` on every render — so the strip reshapes
                // as the segment is clicked, with no relaunch.
                Picker("Ears", selection: $store.settings.earsPlacement) {
                    Text("Beside the notch").tag(EarsPlacement.beside)
                    Text("Below the notch").tag(EarsPlacement.below)
                }
                .pickerStyle(.segmented)
                .disabled(!store.settings.showEars)
                Text("Where the two readouts sit on a built-in display with a notch. An external display always shows the pill.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("One browser profile per account") {
                if let line = AddAccountFlow.shellProfileLine {
                    Text("Every sign-in Brow starts already opens the account's own Chrome profile. For sign-ins started elsewhere (cmux, any terminal), add this to your ~/.zshrc once — the router reads CLAUDE_CONFIG_DIR itself:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(line).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { AddAccountFlow.copyToPasteboard(line) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                    Text("Profiles live in ~/Library/Application Support/Brow/browser-profiles/. Brow never sees the session; Chrome keeps it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The browser router is missing from this build (Contents/Resources/brow-browser); sign-ins use the default browser.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Path to claude") {
                TextField("Auto-detected", text: Binding(
                    get: { store.settings.claudePath ?? "" },
                    set: { store.settings.claudePath = $0.isEmpty ? nil : $0 }))
                // Three states, not two: while the login shell is still running this
                // said "Not found. Ran: …" in orange, and — the window being built once
                // and cached — kept saying it after detection had succeeded.
                switch store.claudeDetection {
                case .found(let path):
                    Text("Detected: \(path)").font(.caption).foregroundStyle(.secondary)
                case .pending:
                    Text("Detecting… (\(ClaudePathResolver.detectionCommand))").font(.caption).foregroundStyle(.secondary)
                case .notFound:
                    Text("Not found. Ran: \(ClaudePathResolver.detectionCommand)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
