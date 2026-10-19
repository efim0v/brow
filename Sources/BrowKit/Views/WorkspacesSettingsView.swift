// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import GroveAppKit
import GroveCore
import SwiftUI

/// Settings › Workspaces: on or off, and — while it runs — the settings that are not
/// any one project's: the projects themselves, the folder new workspaces go in and the
/// transcript safety net. A project's own settings stay in the notch panel, next to the
/// project, where its scan and branch lists are.
struct WorkspacesSettingsTab: View {
    @ObservedObject var host: WorkspacesHost

    var body: some View {
        Form {
            Section {
                Toggle("Workspaces", isOn: Binding(get: { host.activation.isWanted },
                                                   set: { host.setEnabled($0) }))
                status
            } footer: {
                Text(Self.explanation(activation: host.activation, groveSetup: host.isGroveSetup))
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

    /// What Workspaces is and does, in the words that are true for this Mac: a setup
    /// Grove made carries on as Grove had it, a new one starts with nothing turned on.
    static func explanation(activation: WorkspacesActivation, groveSetup: Bool) -> String {
        var text = "Workspaces gives each feature of a multi-repo project its own folder of git worktrees and runs Claude Code sessions in them, from the Projects section of the notch panel."
        if activation == .off {
            text += " Off, none of it runs, with one exception: an account whose status line it captured keeps going through Brow's wrapper until you turn capture off for it under Accounts."
        }
        let it = activation == .off ? "Turned on, it" : "It"
        text += groveSetup
            ? " \(it) runs the projects, accounts and settings you had in Grove, from Grove's folder, ~/Library/Application Support/Grove: status lines Grove captured stay captured, and the transcript safety net keeps the setting Grove gave it."
            : " \(it) keeps its projects and settings in ~/Library/Application Support/Grove and edits no Claude Code file until you ask: capturing an account's status line is turned on per account under Accounts, and the transcript safety net starts off for a new setup."
        return text
    }

    /// While Workspaces is off or paused, the status lines it captured: they keep running
    /// Brow's wrapper until given back.
    @ViewBuilder private var capturedStatusLines: some View {
        let waitsFor = host.dormantChangeBlock
        Section {
            LabeledContent {
                Button("Give them back") { host.releaseAllStatusLines() }
                    .disabled(waitsFor != nil)
            } label: {
                Text(host.dormantCaptures.map(host.displayName(for:)).joined(separator: ", "))
            }
            ForEach(host.changeErrors(for: host.dormantCaptures), id: \.self) { error in
                FailureNote(text: error)
            }
        } header: {
            Text("Status lines still captured")
        } footer: {
            Text(waitsFor.map { WorkspacesHost.pausedChangeNote($0) }
                 ?? "Each of these accounts' status line goes through Brow's wrapper, which records each session for the notch, then runs your own command. Give them back to put your own commands in place.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        switch host.activation {
        case .on:
            Label("On — it is the notch panel's Projects section, and Brow's menu-bar item opens it.",
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
    /// What the last change made here could not do.
    @State private var failure: String?

    var body: some View {
        if let failure {
            Section { FailureNote(text: failure) }
        }
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
                    Button("Remove") { run { state.removeProject(id: project.id) } }
                        .help("Takes the project out of Workspaces only: no repository, worktree or branch is touched")
                }
            }
            Button("Add project…", action: addProject)
        }
        Section {
            Toggle("Show message previews", isOn: Binding(get: { host.showsMessagePreviews },
                                                          set: { host.showsMessagePreviews = $0 }))
        } footer: {
            Text("A session's row shows the last thing asked and the last line Claude wrote. Off, it shows the session's title only — for sharing your screen.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section {
            // The label in the form's own font; only the value, a path, is monospaced.
            LabeledContent("Workspace folder") {
                TextField("Workspace folder", text: Binding(get: { state.config.workspacesRootTemplate },
                                                            set: { template in run { state.setWorkspacesRootTemplate(template) } }))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
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
    }

    static let safetyNetExplanation = "A hard link to each transcript, so one deleted by accident can be put back. Nothing comes back by itself: a transcript that vanishes is listed here, and Restore puts it back. The safety net keeps no transcript longer than Claude Code keeps it (cleanupPeriodDays: the shortest that your organization's managed settings, the account's settings or any project's settings set), and offers none back within a day of that. A period passed to claude with \u{2011}\u{2011}settings is not visible to it."

    @ViewBuilder private var retentionRows: some View {
        ForEach(state.config.accounts, id: \.name) { account in
            if let retention = state.transcriptRetention[account.name] {
                LabeledContent(state.displayName(for: account)) {
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
                    run { state.setTranscriptMirror(settings) }
                })
    }

    private func run(_ action: () -> Void) { failure = state.attempt(action) }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder that contains your repositories."
        if panel.runModal() == .OK, let url = panel.url {
            run { state.addProject(at: url.path) }
        }
    }
}

/// What a change made in Settings could not do, under the control that made it: the
/// engine reports a failure in the panel's banner, which is not where the user is looking.
struct FailureNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An account card's Workspaces section, for the Workspaces account that shares the
/// card's config folder: sharing sessions with the other accounts, capturing the status
/// line, and the account's default model and effort.
struct WorkspacesAccountSection: View {
    @ObservedObject var state: AppState
    let account: AccountConfig
    /// What the last change made here could not do: sharing that could not link, a
    /// settings.json the capture switch could not edit, a setting not saved.
    @State private var failure: String?

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
                Button("Share sessions") { run { state.linkAccount(account) } }
                    .help("Links this account's session stores into ~/.claude, so Resume as… works in both directions")
            }
        }
        // What it does is said once, under the account cards (`CaptureFootnote`).
        Toggle("Capture the status line", isOn: Binding(
            get: { current.monitoring },
            set: { on in run { if on { state.installMonitoring(current) } else { state.disableMonitoring(current) } } }))
            .help(CaptureFootnote.capturing)
        LabeledContent("Default model") {
            ModelPicker(model: Binding(get: { current.defaultModel },
                                           set: { model in run { state.setAccountModel(name: account.name, model: model) } }))
        }
        LabeledContent("Default effort") {
            Picker("", selection: Binding(get: { current.defaultEffort },
                                          set: { effort in run { state.setAccountEffort(name: account.name, effort: effort) } })) {
                Text("(default)").tag(String?.none)
                ForEach(ClaudeService.effortLevels, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden().fixedSize()
        }
        if let failure { FailureNote(text: failure) }
    }

    private func run(_ action: () -> Void) { failure = state.attempt(action) }
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
                        Text(Self.detail(item, now: Date(), name: state.displayName(forAccountNamed:)))
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

    /// "Work · last active 3 days ago", the account named by `name` as the notch names it.
    static func detail(_ item: RestorableTranscript, now: Date, name: (String) -> String = { $0 }) -> String {
        let days = Int(max(0, now.timeIntervalSince(item.entry.lastActivity)) / 86_400)
        let age = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        return [item.accountName.map(name), "last active \(age)"].compactMap { $0 }.joined(separator: " · ")
    }

    static func outcome(asked: Int, restored: Int) -> String {
        if restored == asked { return restored == 1 ? "Put back." : "\(restored) put back." }
        return "\(restored) of \(asked) put back: the others are no longer inside Claude Code's retention, or no longer missing."
    }
}
