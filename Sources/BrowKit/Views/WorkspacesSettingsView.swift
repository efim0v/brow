// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import GroveAppKit
import GroveCore
import SwiftUI

/// Settings › Workspaces: on or off, and — while it runs — the settings that are not
/// any one project's: the projects themselves, the folder new workspaces go in, the
/// transcript safety net and the panel's material. A project's own settings stay in
/// the panel, next to the project, where its scan and branch lists are.
struct WorkspacesSettingsTab: View {
    @ObservedObject var host: WorkspacesHost

    var body: some View {
        Form {
            Section {
                Toggle("Workspaces", isOn: Binding(get: { host.activation.isWanted },
                                                   set: { host.setEnabled($0) }))
                status
            } footer: {
                Text(Self.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if host.activation == .on, let state = host.state {
                WorkspacesEngineSettings(state: state, host: host)
            } else if !host.dormantCaptures.isEmpty {
                capturedStatusLines
            }
        }
        .formStyle(.grouped)
        .onAppear { host.reloadDormantAccounts() }
    }

    static let explanation = "Workspaces gives each feature of a multi-repo project its own folder of git worktrees and runs Claude Code sessions in them, from Brow's menu-bar item. Off, none of it runs, with one exception: an account whose status line it captured keeps going through Brow's wrapper until you turn capture off for it under Accounts. On, it reads the projects you had in Grove and keeps its files in ~/Library/Application Support/Grove. It edits no Claude Code file until you ask: capturing an account's status line is turned on per account under Accounts, and the transcript safety net below starts off."

    /// While Workspaces is off or paused, the status lines it captured: they keep running
    /// Brow's wrapper until given back.
    @ViewBuilder private var capturedStatusLines: some View {
        Section {
            LabeledContent {
                Button("Give them back") { host.releaseAllStatusLines() }
                    .disabled(host.activation == .paused)
            } label: {
                Text(host.dormantCaptures.map(\.name).joined(separator: ", "))
            }
            if let error = host.captureError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Status lines still captured")
        } footer: {
            Text(host.activation == .paused
                 ? WorkspacesHost.pausedCaptureNote(host.pause)
                 : "Each of these accounts' status line goes through Brow's wrapper, which records each session for the notch, then runs your own command. Give them back to put your own commands in place.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        switch host.activation {
        case .on:
            Label("On — Brow's menu-bar item opens it, and so does the button in the notch panel.",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .paused where host.pause == .anotherBrow:
            HStack {
                Label("Paused: another copy of Brow is running Workspaces. It starts here when that copy quits.",
                      systemImage: "pause.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Try Again") { host.refresh() }
            }
        case .paused:
            HStack {
                Label("Paused: Grove is still running. Workspaces starts when Grove quits.",
                      systemImage: "pause.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Quit Grove") { host.quitGrove() }
            }
        case .off:
            EmptyView()
        }
    }
}

/// The engine's own settings; only while it runs, never while Grove.app might be
/// writing the same file.
struct WorkspacesEngineSettings: View {
    @ObservedObject var state: AppState
    let host: WorkspacesHost
    @State private var material = WindowSubstrateStyle.current

    var body: some View {
        Section("Projects") {
            if state.config.projects.isEmpty {
                Text("No projects yet. A project is a folder that holds your repositories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.config.projects) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                        Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Remove") { state.removeProject(id: project.id) }
                        .help("Takes the project out of Workspaces only: no repository, worktree or branch is touched")
                }
            }
            Button("Add project…", action: addProject)
        }
        Section {
            TextField("Workspace folder", text: Binding(get: { state.config.workspacesRootTemplate },
                                                        set: { state.setWorkspacesRootTemplate($0) }))
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("Workspace folders")
        } footer: {
            Text("Where a project's workspaces are made. {project} is the project's name; a project's own setting wins.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Keep a backup of every session transcript", isOn: mirrorBinding(\.enabled))
            Stepper("Keep for at most \(state.config.transcriptMirror.maxDays) days",
                    value: mirrorBinding(\.maxDays), in: 1...365)
            Stepper("Use at most \(state.config.transcriptMirror.maxMB) MB",
                    value: mirrorBinding(\.maxMB), in: 10...10_000, step: 10)
            retentionRows
            if state.config.transcriptMirror.enabled {
                RestorableTranscriptRows(state: state)
            }
        } header: {
            Text("Transcript safety net")
        } footer: {
            Text(Self.safetyNetExplanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            if state.config.transcriptMirror.enabled { await state.reconcileTranscripts() }
            else { await state.refreshTranscriptRetention() }
        }
        Section("Panel") {
            Picker("Material", selection: Binding(get: { material }, set: { style in
                material = style
                host.setPanelMaterial(style)
            })) {
                ForEach(WindowSubstrateStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    static let safetyNetExplanation = "A hard link to each transcript, so one deleted by accident can be put back. Nothing comes back by itself: a transcript that vanishes is listed here, and Restore puts it back. The safety net keeps no transcript longer than Claude Code keeps it (cleanupPeriodDays: the shortest that your organization's managed settings, the account's settings or any project's settings set), and offers none back within a day of that. A period passed to claude with \u{2011}\u{2011}settings is not visible to it."

    @ViewBuilder private var retentionRows: some View {
        ForEach(state.config.accounts, id: \.name) { account in
            if let retention = state.transcriptRetention[account.name] {
                LabeledContent(account.name) {
                    Text("Claude Code keeps \(retention.summary)")
                        .font(.caption)
                        .foregroundStyle(retention.isCertain ? Color.secondary : Color.orange)
                }
            }
        }
    }

    private func mirrorBinding<T>(_ keyPath: WritableKeyPath<TranscriptMirrorSettings, T>) -> Binding<T> {
        Binding(get: { state.config.transcriptMirror[keyPath: keyPath] },
                set: { value in
                    var settings = state.config.transcriptMirror
                    settings[keyPath: keyPath] = value
                    state.setTranscriptMirror(settings)
                })
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder that contains your repositories."
        if panel.runModal() == .OK, let url = panel.url {
            state.addProject(at: url.path)
        }
    }
}

/// An account card's Workspaces section, for the Workspaces account that shares the
/// card's config folder: sharing sessions with the other accounts, capturing the status
/// line, and the account's default model and effort.
struct WorkspacesAccountSection: View {
    @ObservedObject var state: AppState
    let account: AccountConfig

    private var current: AccountConfig {
        state.config.accounts.first { $0.name == account.name } ?? account
    }

    var body: some View {
        let account = current
        LabeledContent("Share sessions") {
            if expandTilde(account.configDir) == state.folders.canonicalDir {
                Text("The default account: the others share into it").font(.caption).foregroundStyle(.secondary)
            } else if account.sharedStore {
                Label("Shared with the default account", systemImage: "link").font(.caption)
            } else {
                Button("Share sessions") { state.linkAccount(account) }
                    .help("Links this account's session stores into ~/.claude, so Resume as… works in both directions")
            }
        }
        Toggle("Capture the status line", isOn: Binding(
            get: { current.monitoring },
            set: { on in if on { state.installMonitoring(current) } else { state.disableMonitoring(current) } }))
        Text("Points this account's statusLine in settings.json at Brow's wrapper, which records each session's model, context use and limits, then runs your own status-line command. Turning it off puts your command back.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent("Default model") {
            ModelPicker(model: Binding(get: { current.defaultModel },
                                           set: { state.setAccountModel(name: account.name, model: $0) }))
        }
        LabeledContent("Default effort") {
            Picker("", selection: Binding(get: { current.defaultEffort },
                                          set: { state.setAccountEffort(name: account.name, effort: $0) })) {
                Text("(default)").tag(String?.none)
                ForEach(ClaudeService.effortLevels, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden().fixedSize()
        }
    }
}

/// The transcripts the safety net can put back, newest first, each with Restore: gone from
/// Claude Code's folders, inside every retention that applies. Nothing comes back without
/// the button — Claude Code may have removed one on purpose, under a period Brow can't see.
struct RestorableTranscriptRows: View {
    @ObservedObject var state: AppState
    @State private var working = false
    @State private var note: String?

    /// How many are listed one by one; Restore all covers the rest.
    static let shown = 6

    var body: some View {
        let all = state.restorableTranscripts
        if !all.isEmpty {
            LabeledContent {
                if all.count > 1 {
                    Button("Restore all \(all.count)") { restore(all) }.disabled(working)
                }
            } label: {
                Text(all.count == 1 ? "1 transcript is gone from Claude Code's folders"
                                    : "\(all.count) transcripts are gone from Claude Code's folders")
            }
            ForEach(all.prefix(Self.shown)) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.place(item))
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text(Self.detail(item, now: Date()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { restore([item]) }.disabled(working)
                }
            }
            if all.count > Self.shown {
                Text("and \(all.count - Self.shown) more").font(.caption).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func restore(_ chosen: [RestorableTranscript]) {
        working = true
        Task { @MainActor in
            let restored = await state.restoreTranscripts(chosen)
            note = Self.outcome(asked: chosen.count, restored: restored)
            working = false
        }
    }

    /// Where the session ran, `~/Code/shop`; its id when the transcript names no folder.
    static func place(_ item: RestorableTranscript) -> String {
        item.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? item.entry.sessionId
    }

    /// "work · last active 3 days ago".
    static func detail(_ item: RestorableTranscript, now: Date) -> String {
        let days = Int(max(0, now.timeIntervalSince(item.entry.lastActivity)) / 86_400)
        let age = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        return [item.accountName, "last active \(age)"].compactMap { $0 }.joined(separator: " · ")
    }

    static func outcome(asked: Int, restored: Int) -> String {
        if restored == asked { return restored == 1 ? "Put back." : "\(restored) put back." }
        return "\(restored) of \(asked) put back: the others are no longer inside Claude Code's retention, or no longer missing."
    }
}
