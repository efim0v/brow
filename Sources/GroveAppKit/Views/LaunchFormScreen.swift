// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// New session / Resume with options, as a screen of its own pushed over the one it was
/// asked from: which account (the host's, in its order, each with its limits), where it
/// opens, the model, the effort, and whether permission prompts are skipped. Cancel and
/// Esc go back; Start session launches and hands the user to it.
struct LaunchFormScreen: View {
    @ObservedObject var state: AppState
    @State private var request: LaunchRequest?
    @Environment(\.groveAccent) private var accent
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    private var current: LaunchRequest? { request ?? state.launchRequest }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current {
                ScopeHeader(title: current.isResume ? "Resume session" : "New session",
                            subtitle: placeLine(current), onBack: { state.cancelLaunch() })
                FadingScrollView {
                    form(current)
                        .padding(.bottom, 10)
                }
            } else {
                ScopeHeader(title: "New session", onBack: { state.cancelLaunch() })
                Spacer()
            }
        }
        .onAppear { if request == nil { request = state.launchRequest } }
        .onChange(of: state.launchRequest) { _, new in if let new, new.id != request?.id { request = new } }
    }

    /// "acme-shop › checkout-redesign": the project, then where the session runs.
    private func placeLine(_ request: LaunchRequest) -> String {
        let place = (request.cwd as NSString).lastPathComponent
        guard let project = state.owningProject(forCwd: request.cwd) else { return place }
        return project.name == place ? project.name : "\(project.name) › \(place)"
    }

    private func form(_ current: LaunchRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACCOUNT").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                accountList(current)
            }
            options(current)
            HStack(spacing: 8) {
                Spacer()
                Button { state.cancelLaunch() } label: {
                    Text("Cancel").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(Capsule().fill(.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                Button { start() } label: {
                    HStack(spacing: 6) {
                        Text("Start session").font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "return").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color(red: 0x2A / 255, green: 0x22 / 255, blue: 0x18 / 255))
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    func start() {
        guard let request = current else { return }
        Task { await state.confirmLaunch(request) }
    }

    // MARK: - Accounts

    private func accountList(_ current: LaunchRequest) -> some View {
        let accounts = state.accounts
        let projectDefault = state.owningProject(forCwd: current.cwd)?.defaultAccount
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                let selected = account.config.name == current.account
                Button { request?.account = account.config.name; if request == nil { self.request = withAccount(account) } } label: {
                    accountRow(account, selected: selected, isDefault: account.config.name == projectDefault)
                }
                .buttonStyle(.plain)
                if index < accounts.count - 1 {
                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 40)
                }
            }
        }
        .background(shape.fill(.white.opacity(0.055)))
        .overlay(shape.strokeBorder(.white.opacity(0.07), lineWidth: 1))
        .clipShape(shape)
    }

    private func withAccount(_ account: WorkspacesAccount) -> LaunchRequest? {
        guard var copy = state.launchRequest else { return nil }
        copy.account = account.config.name
        return copy
    }

    private func accountRow(_ account: WorkspacesAccount, selected: Bool, isDefault: Bool) -> some View {
        let limits = state.limits(for: account.config)
        return HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(selected ? accent : .white.opacity(0.35), lineWidth: 1.5)
                if selected { Circle().fill(accent).frame(width: 8, height: 8) }
            }
            .frame(width: 16, height: 16)
            Circle().fill(account.dot ?? .white.opacity(0.5)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if isDefault {
                        Text("project default")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                }
                if let plan = account.plan {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let limits {
                meter("5h", limits.fiveHour, stale: limits.stale)
                meter("week", limits.weekly, stale: limits.stale)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.white.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// "5h 41%" over a bar, in the limit's own severity colour.
    private func meter(_ label: String, _ used: Double?, stale: Bool) -> some View {
        let value = min(max(used ?? 0, 0), 100)
        let color: Color = stale || used == nil ? .gray : value >= 90 ? .red : value >= 70 ? .orange : .green
        return VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Text(used.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                Capsule().fill(color).frame(width: 52 * value / 100)
            }
            .frame(width: 52, height: 3)
        }
    }

    // MARK: - Options

    private func options(_ current: LaunchRequest) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 0) {
            optionRow("Open in") {
                HStack(spacing: 2) {
                    ForEach(LaunchTarget.allCases, id: \.self) { target in
                        let on = current.target == target
                        Button { request?.target = target } label: {
                            Text(target.label).font(.system(size: 12, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? .white : .white.opacity(0.6))
                                .padding(.horizontal, 10).frame(height: 22)
                                .background { if on { Capsule().fill(accent.opacity(0.17)) } }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(.white.opacity(0.075)))
            }
            divider
            optionRow("Model") {
                if isSnapshotRender {
                    SnapshotPickerLookalike(text: current.model ?? "(default)", monospaced: false)
                } else {
                    ModelPicker(model: Binding(get: { request?.model ?? current.model },
                                               set: { request?.model = $0 }), size: .small)
                }
            }
            divider
            optionRow("Effort") {
                if isSnapshotRender {
                    SnapshotPickerLookalike(text: current.effort ?? "(default)", monospaced: false)
                } else {
                    Picker("", selection: Binding(get: { request?.effort ?? current.effort },
                                                  set: { request?.effort = $0 })) {
                        Text("(default)").tag(String?.none)
                        ForEach(ClaudeService.effortLevels, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                }
            }
            divider
            optionRow("Skip permission prompts") {
                Button { request?.skipPermissions.toggle() } label: {
                    ZStack(alignment: current.skipPermissions ? .trailing : .leading) {
                        Capsule().fill(current.skipPermissions ? accent : .white.opacity(0.18))
                        Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                    }
                    .frame(width: 34, height: 20)
                }
                .buttonStyle(.plain)
                .help("Launch with --dangerously-skip-permissions for this session")
                .accessibilityLabel("Skip permission prompts")
                .accessibilityValue(current.skipPermissions ? "on" : "off")
            }
        }
        .background(shape.fill(.white.opacity(0.055)))
        .overlay(shape.strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 12)
    }

    private func optionRow<Control: View>(_ label: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5))
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }
}
