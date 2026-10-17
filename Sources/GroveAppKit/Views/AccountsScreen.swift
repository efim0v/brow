import SwiftUI
import AppKit
import GroveCore

/// How AccountsScreen resolves an account's identity. Default: the real
/// ClaudeService (reads ~/.claude.json / <configDir>/.claude.json). SnapshotMode
/// overrides this with SnapshotMode.fixtureIdentity so an offscreen render
/// NEVER touches the user's real Claude config.
struct ClaudeIdentityProviderKey: EnvironmentKey {
    static let defaultValue: (AccountConfig) -> AccountIdentity? = { account in
        ClaudeService().identity(account: account)
    }
}

extension EnvironmentValues {
    var claudeIdentityProvider: (AccountConfig) -> AccountIdentity? {
        get { self[ClaudeIdentityProviderKey.self] }
        set { self[ClaudeIdentityProviderKey.self] = newValue }
    }
}

/// Accounts screen (route .accounts): sessions by account. Back header,
/// identity rows (email · organization · tier via the injectable identity provider),
/// live/recent-session usage aggregated across ALL loaded snapshots with a workspace
/// -> project drill-down, and each account's session cards. Adding an account,
/// sharing its sessions, capturing its status line and its default model live in the
/// host's Settings window (`openSettings(.accounts)`); this screen shows their state.
struct AccountsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.claudeIdentityProvider) private var identityProvider

    @State private var expandedAccounts: Set<String> = []

    var body: some View {
        VStack(spacing: 6) {
            header
            cardList
        }
        .onAppear {
            guard !isSnapshotRender else { return }
            state.verifySharedStore()
        }
    }

    private var header: some View {
        ScopeHeader(title: "Accounts",
                    onBack: { state.goBack() })
    }

    /// The account settings are a window away.
    @ViewBuilder private var settingsLink: some View {
        if isSnapshotRender {
            Text("Account settings…").font(.caption).foregroundStyle(Palette.primary)
        } else if let open = state.openSettings {
            Button("Account settings…") { open(.accounts) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Palette.primary)
                .help("Sign in, sharing, status-line capture and default models: Settings › Accounts")
        }
    }

    @ViewBuilder private var cardList: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                settingsLink
            }
            ForEach(state.config.accounts, id: \.name) { account in
                accountCard(account)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

        // ScrollView content is not rendered offscreen -> plain stack in snapshots.
        if isSnapshotRender {
            content
        } else {
            ScrollView { content }
        }
    }

    // MARK: - Account card

    private func accountCard(_ account: AccountConfig) -> some View {
        let usage = accountUsage(account: account, snapshots: Array(state.snapshots.values))
        let isExpanded = expandedAccounts.contains(account.name) || isSnapshotRender
        return VStack(alignment: .leading, spacing: 8) {
            // Identity on its OWN full-width row so the long email · org · tier
            // no longer wraps into (and collides with) the controls.
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).font(.callout.weight(.semibold))
                    identityLine(account)
                }
                Spacer(minLength: 8)
            }
            // Status + controls on a separate, aligned row.
            HStack(spacing: 12) {
                usageSummary(usage, account: account)
                Spacer(minLength: 0)
                sharedStoreControl(account)
                monitorControl(account)
                rootDirControl(account)
            }
            if isExpanded && !usage.entries.isEmpty {
                Divider()
                drillDown(usage)
            }
            if isExpanded {
                sessionCards(account)
            }
            Text(account.configDir)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            ForEach(account.aliasDirs, id: \.self) { alias in
                Text("+ \(alias)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("Also signed in as this account; its sessions are listed here")
            }
        }
        .padding(10)
        .glassCard()
    }

    /// Reveals the account's config dir in Finder. Snapshot-safe: a Button is
    /// AppKit-backed and draws offscreen, so render a plain Image in snapshot mode.
    @ViewBuilder
    private func rootDirControl(_ account: AccountConfig) -> some View {
        if isSnapshotRender {
            Image(systemName: "folder").foregroundStyle(.secondary)
        } else {
            Button { state.openConfigDir(account) } label: { Image(systemName: "folder") }
                .controlSize(.small)
                .help("Reveal \(account.configDir) in Finder")
        }
    }

    /// Status-line capture, as a label: it is turned on and off in Settings › Accounts.
    @ViewBuilder
    private func monitorControl(_ account: AccountConfig) -> some View {
        if account.monitoring {
            Label("capturing", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2).foregroundStyle(Palette.primary).labelStyle(.titleAndIcon)
                .help("Brow's status-line wrapper records this account's sessions")
        }
    }

    private func identityLine(_ account: AccountConfig) -> some View {
        Group {
            // Prefer the OFF-MAIN cache (state.identityByAccount, populated by
            // refreshUsage) so the body never reads .claude.json on the main thread.
            // Fall back to the injected provider only before the first refresh — which
            // is also the snapshot seam (SnapshotMode injects fixtureIdentity; offscreen
            // renders never populate the cache, so they always use the fixture).
            if let identity = state.identityByAccount[account.name] ?? identityProvider(account) {
                // FIX I2: prefer the CANONICAL organizationRateLimitTier (the namespace
                // RateLimitModel.tierWeights keys on) so the card's tier matches the
                // weight table; fall back to the legacy `tier` (userRateLimitTier).
                let tier = identity.organizationRateLimitTier ?? identity.tier
                Text([identity.email, identity.organization, tier]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                    .foregroundStyle(.secondary)
            } else {
                Text("not logged in")
                    .foregroundStyle(Palette.mid)
            }
        }
        .font(.caption)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func usageSummary(_ usage: AccountUsage, account: AccountConfig) -> some View {
        HStack(spacing: 8) {
            if usage.liveCount > 0 {
                Label("\(usage.liveCount) live", systemImage: "circle.fill")
                    .foregroundStyle(Palette.primary)
            }
            Label("\(usage.sessionCount) sessions", systemImage: "text.bubble")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        if !usage.entries.isEmpty {
            Button {
                if expandedAccounts.contains(account.name) {
                    expandedAccounts.remove(account.name)
                } else {
                    expandedAccounts.insert(account.name)
                }
            } label: {
                Image(systemName: expandedAccounts.contains(account.name)
                      ? "chevron.down" : "chevron.right")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Where this account is active")
        }
    }

    /// Sharing, as a label: an account is shared from Settings › Accounts.
    @ViewBuilder
    private func sharedStoreControl(_ account: AccountConfig) -> some View {
        let isCanonical = expandTilde(account.configDir) == state.canonicalDir
        if isCanonical {
            Label("default", systemImage: "star.fill")
                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .help("The default account (~/.claude): the others share their sessions into it")
        } else if account.sharedStore {
            Label("shared", systemImage: "link")
                .font(.caption2).foregroundStyle(Palette.primary).labelStyle(.titleAndIcon)
        }
    }

    /// workspace -> project rows (spec §6.3 "раскрытие — где именно").
    private func drillDown(_ usage: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(usage.entries) { entry in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.location)
                        .font(.caption.weight(.medium))
                    Text("· \(entry.project)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if entry.liveCount > 0 {
                        Text("\(entry.liveCount) live")
                            .font(.caption2)
                            .foregroundStyle(Palette.primary)
                    }
                    Text("\(entry.sessionCount) session\(entry.sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Per-session cards (spec §C.5/C.6)

    /// One session's resolved view-model: the ClaudeSession (for Resume/Relaunch),
    /// the latest statusline capture (context %, effort, captured model) and whether
    /// a process is live.
    private struct SessionCardModel: Identifiable {
        let session: ClaudeSession
        let capture: UsageSnapshot?
        let isLive: Bool
        var id: String { session.id }
    }

    /// All of this account's sessions across every loaded snapshot, deduped by
    /// sessionId (most-recent activity first), each joined to its latest capture
    /// and live-process status.
    private func sessionCardModels(_ account: AccountConfig) -> [SessionCardModel] {
        var byId: [String: ClaudeSession] = [:]
        var liveIds: Set<String> = []
        for snapshot in state.snapshots.values {
            for workspace in snapshot.workspaces {
                for s in workspace.sessions where s.accountName == account.name { byId[s.id] = s }
                for p in workspace.liveProcesses where p.accountName == account.name { liveIds.insert(p.sessionId) }
            }
            for loose in snapshot.loose {
                for s in loose.sessions where s.accountName == account.name { byId[s.id] = s }
                for p in loose.liveProcesses where p.accountName == account.name { liveIds.insert(p.sessionId) }
            }
        }
        // Latest capture per sessionId (snapshotsByAccount may hold several over time).
        var latestCapture: [String: UsageSnapshot] = [:]
        for snap in state.snapshotsByAccount[account.name] ?? [] {
            let existing = latestCapture[snap.sessionId]?.capturedAt ?? .distantPast
            if (snap.capturedAt ?? .distantPast) >= existing { latestCapture[snap.sessionId] = snap }
        }
        return byId.values
            .map { SessionCardModel(session: $0, capture: latestCapture[$0.id], isLive: liveIds.contains($0.id)) }
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    @ViewBuilder
    private func sessionCards(_ account: AccountConfig) -> some View {
        let models = sessionCardModels(account)
        if !models.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(models) { model in
                    sessionCard(model, account: account)
                }
                Text("A running process can't be re-modeled — relaunch applies the new model.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sessionCard(_ model: SessionCardModel, account: AccountConfig) -> some View {
        let session = model.session
        let project = state.owningProject(forCwd: session.cwd)
        let displayModel = model.capture?.modelDisplayName ?? model.capture?.modelId ?? model.session.model
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if model.isLive {
                    Label("live", systemImage: "circle.fill")
                        .font(.caption2).foregroundStyle(Palette.primary).labelStyle(.titleAndIcon)
                }
                Text(session.title ?? (session.cwd as NSString).lastPathComponent)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(relativeActivity(model))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            sessionStatsRow(model, displayModel: displayModel)
            sessionControls(model, account: account, project: project, displayModel: displayModel)
        }
        .padding(8)
        .background(.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous))
    }

    private func sessionStatsRow(_ model: SessionCardModel, displayModel: String?) -> some View {
        HStack(spacing: 8) {
            if let pct = model.capture?.contextUsedPercentage {
                Text("ctx \(Int(pct.rounded()))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let displayModel {
                Text(displayModel)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            if let effort = model.capture?.effort {
                Text("effort \(effort)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    /// Resume + model/effort default pickers (writing the SESSION's owning project)
    /// + "Relaunch with <model>". The card offers the session's OWN account (V1),
    /// so relaunch routes straight through `relaunchSession`. Snapshot-safe: real
    /// Pickers/Buttons render as error placeholders offscreen, so swap in static
    /// lookalikes when `isSnapshotRender`.
    @ViewBuilder
    private func sessionControls(_ model: SessionCardModel, account: AccountConfig,
                                 project: ProjectConfig?, displayModel: String?) -> some View {
        let session = model.session
        HStack(spacing: 6) {
            if isSnapshotRender {
                Text("Resume").font(.caption2).foregroundStyle(Palette.primary)
                SnapshotPickerLookalike(text: project?.defaultModel ?? "(default)")
                SnapshotPickerLookalike(text: project?.defaultEffort ?? "(default)")
                Text("Relaunch").font(.caption2).foregroundStyle(Palette.primary)
            } else {
                Button("Resume") {
                    Task { await state.resumeSession(session, as: account) }
                }
                .controlSize(.small)
                if let project {
                    modelPicker(project: project)
                    effortPicker(project: project)
                }
                Button("Relaunch with \(displayModel ?? "model")") {
                    Task {
                        await state.relaunchSession(session, as: account,
                                                    model: project?.defaultModel,
                                                    effort: project?.defaultEffort)
                    }
                }
                .controlSize(.small)
                .help("Resumes under \(account.name) with the project's current model/effort")
            }
            Spacer()
        }
    }

    private func modelPicker(project: ProjectConfig) -> some View {
        ModelPicker(model: modelBinding(project), size: .small)
    }

    private func effortPicker(project: ProjectConfig) -> some View {
        Picker("", selection: effortBinding(project)) {
            Text("(default)").tag(String?.none)
            ForEach(ClaudeService.effortLevels, id: \.self) { e in
                Text(e).tag(String?.some(e))
            }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
    }

    private func modelBinding(_ project: ProjectConfig) -> Binding<String?> {
        Binding(
            get: { (state.config.projects.first { $0.id == project.id })?.defaultModel },
            set: { state.setProjectModel(projectID: project.id, model: $0) })
    }

    private func effortBinding(_ project: ProjectConfig) -> Binding<String?> {
        Binding(
            get: { (state.config.projects.first { $0.id == project.id })?.defaultEffort },
            set: { state.setProjectEffort(projectID: project.id, effort: $0) })
    }

    private func relativeActivity(_ model: SessionCardModel) -> String {
        let date = model.capture?.capturedAt ?? model.session.lastActivity
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
