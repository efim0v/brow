// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import Foundation
import XCTest
import DemoFixture
@testable import GroveAppKit
import GroveCore
@testable import BrowKit

/// The made-up world the renders of the sessions, the suggestions and the agents draw:
/// the accounts of `MadeUpLimits`/`DemoAccounts` as the notch shows them, and Workspaces
/// with the snapshot fixture's project as "acme-shop", sessions in it at every state, a
/// second project waiting on a question, quiet ones, suggested folders and two other
/// folders. Every name, path, prompt and reply is invented; nothing is read from the Mac.
@MainActor
struct SessionsWorld {
    let store: LimitsStore
    let host: WorkspacesHost
    let state: AppState
    let shopID: UUID

    struct Options {
        /// False: no project yet (the first run).
        var projects = true
        /// Seven quiet projects instead of three.
        var many = false
        /// How many of `MadeUpLimits.all` the notch shows (1–8). The sessions run on the first
        /// three; with fewer, on the ones there are.
        var accounts = 3
        /// Long project, workspace, account and folder names, and long prompts: what the
        /// rows look like when nothing is short.
        var longNames = false
        /// What Settings has on: the readouts' place, the calendar, the pet.
        var settings: (inout BrowSettings) -> Void = { _ in }
    }

    /// Grove's names for Brow's first three accounts, in the panel's order.
    static let accountNames = ["default", "work", "team"]

    static func make(now renderNow: Date, _ options: Options = Options()) throws -> SessionsWorld {
        let appDir = try Fixture.tempDir("one-window-sessions-world").path
        let store = try MadeUpLimits.store(count: options.accounts, now: renderNow, appDir: appDir) { settings in
            settings.workspaces.enabled = true
            if options.longNames {
                settings.accounts["org-demo-work"]?.name = "Client — Northwind Enterprise"
            }
            options.settings(&settings)
        }
        let state = SnapshotMode.fixtureState()
        state.mayWrite = { false }
        let home = DemoAccounts.home
        // Paths are written from the made-up home, as `~/…`.
        state.folders.home = home
        let long = options.longNames
        // The sessions' accounts, by Grove's names: with fewer than three accounts, the ones
        // there are.
        let accounts = Array(Self.accountNames.prefix(max(1, min(3, options.accounts))))
        func account(_ name: String) -> String { accounts.contains(name) ? name : accounts[0] }

        var config = state.config
        let shopID = config.projects[0].id
        config.projects[0].name = long ? "acme-commerce-storefront-and-checkout-platform" : "acme-shop"
        config.projects[0].defaultAccount = account("work")
        let notes = ProjectConfig(name: long ? "field-notes-offline-first-sync-experiments" : "field-notes",
                                  path: home + "/Code/field-notes")
        let quiet = [("orbit-design-system", "Code/orbit"), ("lighthouse-docs", "Sites/lighthouse-docs"),
                     ("tide-mobile", "Code/tide-mobile")]
            + (options.many ? [("northwind-internal-tools-platform-monorepo-2026", "Clients/northwind/tools"),
                               ("sparrow-cli", "Code/sparrow-cli"), ("ledger-sync", "Code/ledger-sync"),
                               ("kiln-build-farm", "Code/kiln")] : [])
        let quietProjects = quiet.map { ProjectConfig(name: $0.0, path: home + "/" + $0.1) }
        config.projects += [notes] + quietProjects
        if !options.projects { config.projects = [] }
        config.accounts = zip(Self.accountNames, DemoAccounts.all).prefix(accounts.count).map { name, demo in
            AccountConfig(name: name, configDir: home + "/" + demo.folder, sharedStore: name != "default")
        }
        state.config = config
        state.limitsProvider = store

        let now = Date()
        let shop = home + "/Desktop/acme.shop"
        let root = "/Users/demo/Workspaces/acme.shop"
        func preview(_ prompt: String, reply: String? = nil, tool: (String, String)? = nil, question: String? = nil,
                     current: Bool = true, peer: String? = nil, branch: String? = nil) -> SessionPreview {
            SessionPreview(prompt: prompt, reply: reply, tool: question != nil ? "AskUserQuestion" : tool?.0, title: nil,
                           turn: tool != nil || question != nil ? .tool : .answered, at: nil, pendingInput: tool?.1,
                           question: question, sender: peer.map { .peer($0) } ?? .you, gitBranch: branch,
                           replyIsCurrent: current)
        }
        func row(_ id: String, _ title: String, _ cwd: String, _ place: String, _ owner: String, _ ago: TimeInterval,
                 _ sessionState: SessionState, _ preview: SessionPreview) -> ProjectSessionRow {
            ProjectSessionRow(sessionId: id, title: title, cwd: cwd, location: place, accountName: account(owner),
                              lastActivity: now.addingTimeInterval(-ago), state: sessionState,
                              cmuxWorkspaceId: sessionState.isLive ? "ws-" + id : nil, preview: preview)
        }
        let webhooks = long ? "fix-payment-webhooks-retry-and-dead-letter-queue" : "fix-payment-webhooks"
        let checkout = long ? "checkout-redesign-address-step-validation" : "checkout-redesign"
        var rows: [UUID: [ProjectSessionRow]] = [
            shopID: [
                row("s-webhooks", "Retry failed webhook deliveries", root + "/" + webhooks, webhooks,
                    "team", 120, .needsPermission,
                    preview(long ? "retry failed webhook deliveries with exponential backoff, cap at 5 attempts, then move them to a dead-letter queue we can replay from the admin screen"
                                 : "retry failed webhook deliveries with backoff, cap at 5 attempts",
                            reply: "Backoff is in: 1 s, 2 s, 4 s, 8 s, 16 s. Running the suite.",
                            tool: ("Bash", long ? "npm run test:webhooks -- --retries=5 --reporter=verbose --grep 'dead letter'"
                                                : "npm run test:webhooks -- --retries=5"))),
                row("s-checkout", "Checkout: address step validation", root + "/" + checkout, checkout,
                    "work", 20, .working,
                    preview("make the address step validate inline, with errors under each field",
                            reply: "9 of 12 checkout tests pass. Fixing the ZIP+4 rule next.",
                            tool: ("Bash", "npm test -- checkout"), peer: nil)),
                row("s-readme", "README: seed script", shop, "main", "default", 18 * 60, .yourTurn,
                    preview("update the README for the new seed script",
                            reply: "Done — Local setup now covers seeding, and the old make target is gone.")),
                // The snapshot fixture's two workspaces' sessions, as its project screen shows them.
                row("s-mu-1", "Multipart upload endpoint", root + "/media-upload", "media-upload", "work", 120, .asksYou,
                    preview("accept multipart on /media and stream it to disk",
                            question: long ? "Keep the 25 MB limit for images and raise it to 2 GB for video, or make the limit a per-plan setting that the admin screen can change?"
                                           : "Keep the 25 MB limit, or raise it for video?")),
                row("s-mp-1", "Implement media pipeline", root + "/media-pipeline", "media-pipeline", "default", 900,
                    .working,
                    preview("wire the upload progress events into the pipeline",
                            tool: ("Bash", "swift test --filter Pipeline"))),
                row("s-search", "Verify webhook signatures", root + "/" + webhooks, webhooks, "team",
                    2 * 86_400, .closed,
                    preview("verify the webhook signature before parsing the body",
                            reply: "Signature checked first; bad payloads get 401 and are not logged.")),
                row("s-promo", "Promo code endpoint and tests", root + "/checkout-promo-codes", "checkout-promo-codes", "work",
                    6 * 3_600, .closed,
                    preview("add POST /cart/promo with tests", reply: "Endpoint and 14 tests added; expired codes return 410.")),
            ],
            notes.id: [
                row("s-offline", "Offline sync conflict resolution", notes.path + "/offline-sync", "offline-sync", "default",
                    3_600, .asksYou,
                    preview("resolve offline sync conflicts without losing edits",
                            question: "Two edits hit the same note. Keep both as versions, or last write wins?")),
                row("s-share", "Share sheet freeze", notes.path, "main", "default", 5 * 86_400, .closed,
                    preview("why does the share sheet freeze on large notes?",
                            reply: "It rendered every image at full size; thumbnails now load lazily.")),
            ],
        ]
        // Each quiet project's newest session, titled the way Claude Code names one.
        let quietSessions = [("Dark palette tokens", "tokens for the dark palette, with contrast checks"),
                             ("Quick start for v3", "rewrite the quick start for v3"),
                             ("Empty tide table crash", "fix the crash when the tide table is empty"),
                             ("Billing exporter on the queue API", "migrate the billing exporter to the new queue API"),
                             ("--json for list commands", "add a --json flag to every list command"),
                             ("Ledger reconcile after partial sync", "reconcile ledger entries after a partial sync"),
                             ("Toolchain cache", "cache the toolchain between runs")]
        for (index, project) in quietProjects.enumerated() {
            let (title, prompt) = quietSessions[index % quietSessions.count]
            rows[project.id] = [row("s-q\(index)", title, project.path, "main", index % 2 == 0 ? "work" : "default",
                                    Double(index + 2) * 86_400, .closed, preview(prompt))]
        }
        state.recentSessionsByProject = options.projects ? rows : [:]
        state.sessionCountByProject = [shopID: 9, notes.id: 3]
        func session(_ id: String, _ cwd: String, _ owner: String, _ ago: TimeInterval, _ preview: SessionPreview,
                     branch: String? = nil) -> ClaudeSession {
            ClaudeSession(id: id, cwd: cwd, title: nil, lastActivity: now.addingTimeInterval(-ago), accountName: account(owner),
                          gitBranch: branch, preview: preview)
        }
        state.externalSessionsByProject = [shopID: [
            session("s-readme", shop, "default", 18 * 60, preview("update the README for the new seed script",
                    reply: "Done — Local setup now covers seeding, and the old make target is gone."), branch: "main"),
            session("s-sdk", shop, "work", 2 * 86_400, preview("bump the payments SDK and fix the deprecations",
                    reply: "SDK 7.2 in; two deprecated calls replaced, all 212 tests pass."), branch: "deps/payments-sdk"),
        ]]
        let dotfiles = [session("s-zsh", home + "/dotfiles", "default", 2 * 86_400,
                                preview("show the git branch only inside repositories",
                                        reply: "The zsh prompt now shows the git branch only inside repositories.")),
                        session("s-alias", home + "/dotfiles", "default", 6 * 86_400,
                                preview("add an alias for the staging tunnel", reply: "Added tunnel-staging; it opens the tunnel and prints its port."))]
        let scratch = [session("s-csv", home + "/Desktop/scratch", "work", 4 * 86_400,
                               preview("how many rows have a missing date?",
                                       reply: "The CSV has 1,204 rows; 17 have a missing date, listed in missing.txt."))]
        state.otherSessions = dotfiles + scratch
        state.otherFolders = [OtherFolder(path: home + "/dotfiles", sessions: dotfiles),
                              OtherFolder(path: home + "/Desktop/scratch", sessions: scratch)]
        let harborPath = long ? home + "/Clients/northwind/internal-tools/harbor-api-gateway-service" : home + "/Code/harbor-api"
        func configDir(_ owner: String) -> String {
            let index = Self.accountNames.firstIndex(of: account(owner)) ?? 0
            return home + "/" + DemoAccounts.all[index].folder
        }
        state.suggestions = [ProjectSuggestion(path: harborPath, pids: [41001, 41002], cwds: [harborPath],
                                               configDirs: [configDir("work")]),
                             ProjectSuggestion(path: home + "/Code/fleet", pids: [41003], cwds: [home + "/Code/fleet"],
                                               configDirs: [configDir("default")])]
        var live = [
            LiveProcess(pid: 41010, sessionId: "s-webhooks", cwd: root, status: "waiting", accountName: account("team"),
                        waitingFor: "permission prompt"),
            LiveProcess(pid: 41011, sessionId: "s-checkout", cwd: root, status: "busy", accountName: account("work")),
            LiveProcess(pid: 41012, sessionId: "s-readme", cwd: shop, status: "idle", accountName: account("default")),
            LiveProcess(pid: 41013, sessionId: "s-offline", cwd: notes.path, status: "waiting", accountName: account("default"),
                        waitingFor: "input needed"),
            LiveProcess(pid: 41001, sessionId: "s-harbor", cwd: harborPath, status: "idle", accountName: account("work")),
            LiveProcess(pid: 41002, sessionId: "s-harbor-2", cwd: harborPath, status: "busy", accountName: account("work")),
            LiveProcess(pid: 41003, sessionId: "s-fleet", cwd: home + "/Code/fleet", status: "idle",
                        accountName: account("default")),
            // The snapshot fixture's own: media-pipeline working, media-upload asking.
            LiveProcess(pid: 4242, sessionId: "s-mp-1", cwd: root + "/media-pipeline", status: "busy",
                        accountName: account("default")),
            LiveProcess(pid: 4343, sessionId: "s-mu-1", cwd: root + "/media-upload", status: "waiting",
                        accountName: account("work"), waitingFor: "input needed"),
        ]
        if !options.projects {
            // The first run: nothing is a project yet, so what runs is where Claude is
            // running — the suggestions. One of them waits on a permission.
            state.suggestions.append(ProjectSuggestion(path: home + "/Sites/lighthouse-docs", pids: [41004],
                                                       cwds: [home + "/Sites/lighthouse-docs"],
                                                       configDirs: [configDir("team")]))
            live = [
                LiveProcess(pid: 41001, sessionId: "s-harbor", cwd: harborPath, status: "waiting",
                            accountName: account("work"), waitingFor: "permission prompt"),
                LiveProcess(pid: 41002, sessionId: "s-harbor-2", cwd: harborPath, status: "busy",
                            accountName: account("work")),
                LiveProcess(pid: 41003, sessionId: "s-fleet", cwd: home + "/Code/fleet", status: "idle",
                            accountName: account("default")),
                LiveProcess(pid: 41004, sessionId: "s-docs", cwd: home + "/Sites/lighthouse-docs", status: "idle",
                            accountName: account("team")),
            ]
        }
        state.liveSessions = live
        state.lastRefreshAt = Date().addingTimeInterval(-12)

        let host = WorkspacesHost(store: store, folders: state.folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                  groveConfigExists: { true }, watchRunningApps: { _ in NSObject() })
        host.preview(state: state, activation: .on)
        return SessionsWorld(store: store, host: host, state: state, shopID: shopID)
    }

    /// The made-up agents in the world's Agents tab, keyed by its accounts as the notch has them:
    /// Personal, Work and Team in the panel's order, whatever names they carry.
    func showAgents(now: Date, _ graph: (AgentsSnapshot.Accounts) -> AgentGraph) {
        let accounts = host.agentsAccounts()
        func key(_ index: Int) -> String { accounts.indices.contains(index) ? accounts[index].key : accounts.first?.key ?? "" }
        let keys = AgentsSnapshot.Accounts(work: key(1), team: key(2), personal: key(0))
        host.agents.setAccounts(accounts)
        host.agents.order = []
        host.agents.preview(graph: graph(keys), now: now)
    }
}
