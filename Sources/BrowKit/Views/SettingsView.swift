// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import GroveAppKit
import GroveCore
import ServiceManagement
import SwiftUI

/// The tabs of Brow's one Settings window.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general, accounts, workspaces, about

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .workspaces: return "Workspaces"
        case .about: return "About"
        }
    }

    /// Where the links on Workspaces' screens land.
    public init(_ link: WorkspacesSettingsLink) {
        switch link {
        case .workspaces: self = .workspaces
        case .accounts: self = .accounts
        }
    }
}

/// Which tab the window shows. Owned outside the view tree, so the panel's gear can
/// turn the window to Workspaces while it is already open.
@MainActor
public final class SettingsNavigation: ObservableObject {
    @Published public var pane: SettingsPane = .general
    public init() {}
}

public struct SettingsView: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var addFlow: AddAccountFlow
    @ObservedObject var navigation: SettingsNavigation
    /// Names typed but not committed yet. Held outside the view tree so closing the
    /// window cannot discard them — see `SettingsDrafts`.
    let drafts: SettingsDrafts
    /// nil where nothing can post (the README screenshots): the permission row is left out.
    let notifier: LimitNotifier?
    /// nil where Workspaces is not hosted (tests, screenshots of the notch only).
    let workspaces: WorkspacesHost?

    @MainActor
    public init(store: LimitsStore, addFlow: AddAccountFlow, drafts: SettingsDrafts, notifier: LimitNotifier? = nil,
                workspaces: WorkspacesHost? = nil, navigation: SettingsNavigation? = nil) {
        self.store = store
        self.addFlow = addFlow
        self.drafts = drafts
        self.notifier = notifier
        self.workspaces = workspaces
        self.navigation = navigation ?? SettingsNavigation()
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
        TabView(selection: $navigation.pane) {
            general.tabItem { Text(SettingsPane.general.title) }.tag(SettingsPane.general)
            AccountsTab(store: store, addFlow: addFlow, drafts: drafts, workspaces: workspaces, claudePath: claudePath)
                .tabItem { Text(SettingsPane.accounts.title) }.tag(SettingsPane.accounts)
            workspacesTab.tabItem { Text(SettingsPane.workspaces.title) }.tag(SettingsPane.workspaces)
            AboutView().tabItem { Text(SettingsPane.about.title) }.tag(SettingsPane.about)
        }
        .frame(width: 620, height: 500)
        .padding()
    }

    @ViewBuilder private var workspacesTab: some View {
        if let workspaces {
            WorkspacesSettingsTab(host: workspaces)
        } else {
            Form {
                Text(WorkspacesSettingsTab.explanation(activation: .off, groveSetup: false))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    /// The picture the panel's share button copies: who is named on it, its shape, a
    /// half-size preview, and Save — which needs a window that can become key, so it
    /// lives here and not in the panel.
    struct UsageImageSection: View {
        @ObservedObject var store: LimitsStore
        @State private var copied = false

        var body: some View {
            Section("Usage image") {
                Toggle("Show account names on the image", isOn: $store.settings.cardShowNames)
                Text("Off: accounts appear as “Account 1”, “Account 2”. On: the names you gave them under Accounts; an account without a name stays numbered. Emails, folders and plans are never on the image.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Shape", selection: $store.settings.cardShape) {
                    Text("Wide (1200 × 630)").tag(CardShape.wide)
                    Text("Square (1080 × 1080)").tag(CardShape.square)
                }
                .pickerStyle(.segmented)
                // Half size, redrawn once a minute so the countdowns and the time stamp
                // keep up while the window stays open. Scaled from the top-leading corner:
                // scaled about its centre, the card left a gap above it in the row.
                TimelineView(.everyMinute) { context in
                    let shape = store.settings.cardShape
                    WeekCardView(model: WeekCardModel.make(rows: store.rows, aggregate: store.aggregate,
                                                           settings: store.settings, shape: shape, now: context.date),
                                 shape: shape)
                        .frame(width: shape.points.width, height: shape.points.height)
                        .scaleEffect(0.5, anchor: .topLeading)
                        .frame(width: shape.points.width / 2, height: shape.points.height / 2, alignment: .topLeading)
                        .frame(width: 300)
                        .frame(maxWidth: .infinity)
                }
                HStack {
                    Button(copied ? "Copied" : "Copy image") {
                        guard let png = WeekCardExport.png(store: store, now: Date()) else { return }
                        WeekCardExport.copy(png)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copied = false
                        }
                    }
                    Button("Save as PNG…") {
                        if let png = WeekCardExport.png(store: store, now: Date()) { WeekCardExport.save(png) }
                    }
                }
                .disabled(!store.aggregate.hasData)
            }
        }
    }

    private var general: some View {
        Form {
            LaunchAtLoginRow()
            NotificationSettings(settings: $store.settings, notifier: notifier)
            Section {
                Toggle("Show the reset calendar in the panel", isOn: $store.settings.showCalendar)
                Text("A month under the accounts: a dot per weekly reset in the account's colour, a diamond for the estimated subscription renewal. Hover a day for the details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show Brow in the notch", isOn: $store.settings.showNotch)
                Text("Off: Brow draws nothing at the top of the screen and no panel opens on hover. Limit warnings still arrive, and the panel still opens on Projects from the Brow menu and opening Brow again from Finder or Spotlight — or this window, while Workspaces is off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show readouts next to the notch", isOn: $store.settings.showEars)
                    .disabled(!store.settings.showNotch)
                Text("Off: nothing is drawn until the pointer reaches the notch itself — on a display without one, the top centre of the screen — and the panel then opens with its animation.")
                    .font(.caption).foregroundStyle(.secondary)
                // The store writes config.json and publishes on every change, and the
                // panel re-reads `earsPlacement` on every render — so the strip reshapes
                // as the segment is clicked, with no relaunch.
                Picker("Ears", selection: $store.settings.earsPlacement) {
                    Text("Beside the notch").tag(EarsPlacement.beside)
                    Text("Below the notch").tag(EarsPlacement.below)
                }
                .pickerStyle(.segmented)
                .disabled(!store.settings.showNotch || !store.settings.showEars)
                Text("Where the two readouts sit on a built-in display with a notch. An external display always shows the pill.")
                    .font(.caption).foregroundStyle(.secondary)
                // On by default: it draws only in Brow's own black, covers no number, needs no
                // permission and interrupts nothing. It lives in the notch, so with Brow out of the
                // notch there is no pet to show.
                Toggle("Show the pet", isOn: $store.settings.showPet)
                    .disabled(!store.settings.showNotch)
                Text("A small creature beside the notch that eats what your accounts use: it takes a bite when the 5-hour number goes up, sleeps when a limit is used up and wakes at the reset. It only gets hungry while you are at the Mac, and follows Reduce Motion. Nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            UsageImageSection(store: store)
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
                Text("Sign-ins, Open in Terminal, token refresh and the sessions Workspaces starts all run this claude.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › Accounts: one card per account Brow found, and — while Workspaces runs —
/// the card's Workspaces section, for the Workspaces account in the same config folder.
struct AccountsTab: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var addFlow: AddAccountFlow
    let drafts: SettingsDrafts
    let workspaces: WorkspacesHost?
    let claudePath: String

    /// `allRows`, not `rows`: a hidden account has to stay listed here or its
    /// "Show" toggle could never be turned back on.
    var body: some View {
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
                    }
                }
                if let s = addFlow.status { Text(s).font(.caption) }
            }
            ForEach(store.allRows) { row in
                Section {
                    card(row)
                    if let workspaces { WorkspacesCardSection(host: workspaces, row: row) }
                } footer: {
                    // What Capture the status line does, once, under the last card.
                    if let workspaces, row.id == store.allRows.last?.id { CaptureFootnote(host: workspaces) }
                }
            }
            if let workspaces { WorkspacesOtherAccounts(host: workspaces, cards: store.allRows.map(\.account)) }
            Section {
                Toggle("Allow `claude -p` fallback", isOn: $store.settings.allowPromptFallback)
                Text("Used only when `claude doctor` fails to refresh a token. Spends a small amount of that account's limit and starts its 5-hour window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A status line Workspaces captured stays captured while it is off: read which.
        .onAppear { workspaces?.reloadDormantAccounts() }
    }

    @ViewBuilder private func card(_ row: AccountRow) -> some View {
        // Committed on Return / focus loss / window close, not on every keystroke: each
        // write of `store.settings` is a synchronous atomic JSON write plus a full
        // recompute plus a panel re-render with a 0.18 s animation.
        AccountNameField(accountID: row.id, initial: store.settings.accounts[row.id]?.name ?? "",
                         drafts: drafts, store: store)
        LabeledContent("Email", value: row.account.email ?? "—")
        LabeledContent("Tier", value: PanelText.tierLabel(row.account.tier))
        LabeledContent("Folder") {
            Text(row.account.configDir + (row.account.aliasDirs.isEmpty ? "" : " (+\(row.account.aliasDirs.count) alias)"))
                .font(.caption).textSelection(.enabled)
        }
        LabeledContent("Token", value: row.tokenStatus)
        // The command that runs Claude Code as this account, in plain sight: paste it
        // into any terminal. The copy button sits right on it.
        LabeledContent("Launch") {
            let command = AddAccountFlow.launchCommand(dir: row.account.configDir, home: addFlow.home)
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
            if row.account.keychainLocked {
                Button {
                    Task { await store.grantKeychainAccess(row.account) }
                } label: { Label("Grant Keychain access", systemImage: "key.fill") }
                    .help("macOS asks once; choose “Always Allow”. Needed again only after a fresh `claude auth login` recreates the item.")
            }
            Button {
                AddAccountFlow.copyToPasteboard(AddAccountFlow.launchCommand(dir: row.account.configDir, home: addFlow.home))
            } label: { Label("Copy launch command", systemImage: "doc.on.doc") }
            Button {
                AddAccountFlow.login(dir: row.account.configDir, claudePath: claudePath)
            } label: { Label("Sign in again", systemImage: "person.badge.key") }
                .help("Opens Terminal with `claude auth login` for this account; the browser window is this account's own profile.")
        }
        HStack {
            Text("Browser profile: a complete Chrome profile of its own, named after the account — every site's sessions, cookies and saved passwords stay in it between launches.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                AddAccountFlow.openBrowserProfile(dir: row.account.configDir)
            } label: { Label("Open browser profile", systemImage: "globe") }
                .help("Open this account's own Chrome profile on claude.ai. Sign in there once (Apple, Google, email — and any other site you like); it all stays, and every later `claude auth login` is one click.")
        }
    }
}

/// The Workspaces part of one account card: all of it while Workspaces runs; while it
/// does not, the switch that gives back a status line it captured, which goes on
/// running Brow's wrapper until that switch is turned off.
private struct WorkspacesCardSection: View {
    @ObservedObject var host: WorkspacesHost
    let row: AccountRow

    var body: some View {
        if host.activation == .on, let state = host.state {
            WorkspacesCardJoin(state: state, row: row)
        } else if let account = WorkspacesAccountJoin.match(row.account, in: host.dormantCaptures) {
            Text("Workspaces").font(.subheadline.weight(.semibold)).padding(.top, 4)
            DormantCaptureSwitch(host: host, account: account)
        }
    }
}

/// The Workspaces accounts no card above shows (`WorkspacesAccountJoin.unmatched`), each
/// in a section of its own: every one while Workspaces runs, the ones whose status line
/// it captured while it does not.
private struct WorkspacesOtherAccounts: View {
    @ObservedObject var host: WorkspacesHost
    let cards: [DiscoveredAccount]

    var body: some View {
        if host.activation == .on, let state = host.state {
            WorkspacesOtherAccountList(state: state, cards: cards)
        } else {
            ForEach(WorkspacesAccountJoin.unmatched(host.dormantCaptures, cards: cards), id: \.name) { account in
                let gone = WorkspacesAccountJoin.isGone(account)
                Section {
                    LabeledContent("Folder") {
                        Text(account.configDir).font(.caption).textSelection(.enabled)
                    }
                    if gone {
                        GoneAccountRow(disabled: host.dormantChangeBlock != nil) { host.removeAccount(account) }
                        if let error = host.changeError(for: account) { FailureNote(text: error) }
                    } else {
                        DormantCaptureSwitch(host: host, account: account)
                    }
                } header: {
                    Text("Workspaces account “\(account.name)”")
                } footer: {
                    if gone { GoneAccountRow.footer }
                }
            }
        }
    }
}

/// Capture the status line, for an account Workspaces captured while Workspaces is off
/// or paused: on, and turning it off gives the account its own command back. Not while
/// Grove.app, or another copy of Brow running Workspaces, could write the same files.
struct DormantCaptureSwitch: View {
    @ObservedObject var host: WorkspacesHost
    let account: AccountConfig

    var body: some View {
        let waitsFor = host.dormantChangeBlock
        // Why it is still on is said once, under the account cards (`CaptureFootnote`).
        Toggle("Capture the status line", isOn: Binding(
            get: { true },
            set: { on in if !on { host.releaseStatusLine(account) } }))
            .disabled(waitsFor != nil)
            .help(Self.explanation(activation: host.activation, waitsFor: waitsFor))
        if let error = host.changeError(for: account) {
            FailureNote(text: error)
        }
    }

    /// Why a status line Workspaces captured is still on while Workspaces is not, and how
    /// to turn it off. `waitsFor`: what writes the same files meanwhile, if anything
    /// (`WorkspacesHost.dormantChangeBlock`).
    static func explanation(activation: WorkspacesActivation, waitsFor: WorkspacesPause?) -> String {
        switch (activation, waitsFor) {
        case (_, .anotherBrow?):
            return "Workspaces runs in another copy of Brow, and the status lines it captured still go through Brow's wrapper. Turn capture off there, or quit that copy to turn it off here."
        case (.paused, _):
            return "Workspaces is paused while Grove runs, and the status lines it captured still go through Brow's wrapper. Quit Grove to turn Capture the status line off here."
        case (_, .groveRunning?):
            return offText + " Grove is running and edits the same files: quit Grove to turn it off here."
        default:
            return offText + " Turn it off to put your command back."
        }
    }

    private static let offText = "Workspaces is off, but the status line of each account with Capture the status line on still goes through Brow's wrapper, which records each session for the notch and then runs your own command."
}

/// What Capture the status line does, said once under the account cards instead of in
/// every card: how it works while Workspaces runs, why it is still on while it does not.
struct CaptureFootnote: View {
    @ObservedObject var host: WorkspacesHost

    static let capturing = "Capture the status line points the account's statusLine in settings.json at Brow's wrapper, which records each session's model, context use and limits, then runs your own status-line command. Turning it off puts your command back."

    var body: some View {
        if let text = Self.text(activation: host.activation, waitsFor: host.dormantChangeBlock,
                                hasAccounts: !(host.state?.config.accounts.isEmpty ?? true),
                                hasDormantCaptures: !host.dormantCaptures.isEmpty) {
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// nil when no switch is shown above it. `waitsFor`: as `DormantCaptureSwitch` has it.
    static func text(activation: WorkspacesActivation, waitsFor: WorkspacesPause?,
                     hasAccounts: Bool, hasDormantCaptures: Bool) -> String? {
        switch activation {
        case .on: return hasAccounts ? capturing : nil
        case .paused, .off:
            return hasDormantCaptures ? DormantCaptureSwitch.explanation(activation: activation, waitsFor: waitsFor) : nil
        }
    }
}

private struct WorkspacesOtherAccountList: View {
    @ObservedObject var state: AppState
    let cards: [DiscoveredAccount]
    /// What the last Remove could not do.
    @State private var failure: String?

    var body: some View {
        ForEach(WorkspacesAccountJoin.unmatched(state.config.accounts, cards: cards), id: \.name) { account in
            let gone = WorkspacesAccountJoin.isGone(account)
            Section {
                LabeledContent("Folder") {
                    Text(account.configDir).font(.caption).textSelection(.enabled)
                }
                if gone {
                    GoneAccountRow(disabled: false) {
                        failure = state.attempt { state.removeAccount(name: account.name) }
                    }
                    if let failure { FailureNote(text: failure) }
                } else {
                    WorkspacesAccountSection(state: state, account: account)
                }
            } header: {
                Text("Workspaces account “\(account.name)”")
            } footer: {
                if gone {
                    GoneAccountRow.footer
                } else {
                    Text("Brow shows no limits for this account: its folder has no sign-in Brow can read, or it is a second folder of an account above.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A Workspaces account whose folder is gone. Nothing about it can change any more —
/// its status line, sessions and settings went with the folder, and nothing re-creates
/// it — but whether Workspaces still lists it, in its pickers and here.
struct GoneAccountRow: View {
    let disabled: Bool
    let remove: () -> Void

    var body: some View {
        LabeledContent {
            Button("Remove from Workspaces", action: remove)
                .disabled(disabled)
                .help("Takes the account out of Workspaces' list only: nothing on disk changes")
        } label: {
            Label("Its folder is gone", systemImage: "folder.badge.questionmark")
        }
    }

    static var footer: some View {
        Text(explanation)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static let explanation = "Its folder was deleted or is on a disk that isn't connected, so Brow shows no limits for it and nothing can launch in it. Remove from Workspaces takes it out of the account pickers and of Settings; a project that launched on it by default uses the first account instead."
}

private struct WorkspacesCardJoin: View {
    @ObservedObject var state: AppState
    let row: AccountRow

    var body: some View {
        if let account = WorkspacesAccountJoin.match(row.account, in: state.config.accounts) {
            Text("Workspaces").font(.subheadline.weight(.semibold)).padding(.top, 4)
            WorkspacesAccountSection(state: state, account: account)
        }
    }
}

/// A name field whose edits stay local until the user is done with them — but every
/// keystroke is recorded in `drafts`, which outlives this view. Closing the window
/// destroys the SwiftUI tree and this `@State` with it, and the focus-loss change is not
/// guaranteed to be delivered first, so a rename typed and then "finished" with Cmd-W
/// used to be silently discarded. `drafts` is what `windowWillClose` flushes.
struct AccountNameField: View {
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

/// Launch at login, as macOS has it — read back after every change, so the toggle can
/// never show on while it is off (brow#8): a register that fails, or one waiting for the
/// user's approval in System Settings, leaves it off and says why.
struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var failure: String?

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { LaunchAtLogin.isOn(status) }, set: change))
        if let note = LaunchAtLogin.note(status: status, failure: failure) {
            HStack {
                Text(note).font(.caption).foregroundStyle(.orange)
                Spacer()
                if status == .requiresApproval {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
    }

    private func change(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            failure = nil
        } catch {
            failure = error.localizedDescription
            BrowLog.panel.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
        status = SMAppService.mainApp.status
    }
}

/// The launch-at-login toggle's rules, apart from the view.
enum LaunchAtLogin {
    /// On only when macOS says it is: waiting for approval is not on.
    static func isOn(_ status: SMAppService.Status) -> Bool { status == .enabled }

    static func note(status: SMAppService.Status, failure: String?) -> String? {
        if status == .requiresApproval {
            return "Waiting for your approval in System Settings › General › Login Items."
        }
        if let failure { return "macOS did not change it: \(failure)" }
        return nil
    }
}

/// Settings › General › Notifications. A view of its own so the review render can draw
/// it without the rest of the tab.
struct NotificationSettings: View {
    @Binding var settings: BrowSettings
    let notifier: LimitNotifier?

    var body: some View {
        Section("Notifications") {
            Toggle("Warn when an account nears a limit", isOn: $settings.notifyLimits)
            Picker("Warn at", selection: $settings.notifyThresholds) {
                ForEach(LimitWarnings.presets, id: \.self) { levels in
                    Text(NoticeText.levels(levels)).tag(levels)
                }
                // A hand-edited config.json: shown as it is rather than as a blank picker.
                if !LimitWarnings.presets.contains(settings.notifyThresholds) {
                    Text(NoticeText.levels(settings.notifyThresholds)).tag(settings.notifyThresholds)
                }
            }
            .disabled(!settings.notifyLimits)
            Toggle("Also notify when that limit resets", isOn: $settings.notifyResets)
                .disabled(!settings.notifyLimits)
            Text("For each account's 5-hour and weekly limits, once per level until the limit resets. Levels already passed when Brow starts are not announced. Made on this Mac; nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.notifyLimits, let notifier {
                NotificationStatusRow(notifier: notifier)
            }
        }
    }
}

/// What macOS says about Brow's notifications, and the one thing to do about it.
struct NotificationStatusRow: View {
    @ObservedObject var notifier: LimitNotifier

    var body: some View {
        switch notifier.authorization {
        case .unknown:
            EmptyView()
        case .notDetermined:
            Button("Allow notifications…") { Task { await notifier.requestPermission() } }
        case .denied:
            HStack {
                Text("Notifications for Brow are off in System Settings.")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.artemefimov.brow") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .unavailable:
            Text("This build runs without an app bundle, so it can't post notifications.")
                .font(.caption).foregroundStyle(.secondary)
        case .allowed:
            Button("Send a test notification") { notifier.sendTest() }
        }
    }
}
