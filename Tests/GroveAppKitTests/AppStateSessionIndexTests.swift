// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveCore
@testable import GroveAppKit

/// The sessions as the Projects list gets them: read from made-up transcripts and session
/// records in a temporary account folder, joined to what runs, kept current while the list
/// is in view, and the folders Claude Code runs in offered as projects. The processes are
/// the test's own `/bin/sleep`, in folders it makes.
@MainActor
final class AppStateSessionIndexTests: XCTestCase {
    private var root: URL!
    private var cfg: String!
    private var shopPath: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = try FixtureLite.tempDir("session-index")
        cfg = root.appendingPathComponent("work").path
        shopPath = root.appendingPathComponent("code/acme-shop").path
        try fm.createDirectory(atPath: cfg + "/sessions", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: shopPath, withIntermediateDirectories: true)
        shop = ProjectConfig(name: "acme-shop", path: shopPath, workspacesRoot: root.appendingPathComponent("ws").path)
    }

    private var shop: ProjectConfig!

    private func makeState(projects: [ProjectConfig]? = nil) throws -> AppState {
        let url = root.appendingPathComponent("config.json")
        try ConfigStore(url: url).save(GroveConfig(version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
                                                   projects: projects ?? [shop],
                                                   accounts: [AccountConfig(name: "work", configDir: cfg)]))
        let state = AppState(configStore: ConfigStore(url: url), folders: .beside(configFile: url))
        state.cmuxOverride = stubbedCmux()
        state.suggestionTemporaryRoots = []
        return state
    }

    // MARK: - Fixtures

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }

    /// A made-up transcript: a prompt, then `tail` (Claude's reply, or a pending tool call).
    private func transcript(_ id: String, cwd: String, prompt: String, reply: String? = nil,
                            tool: (name: String, input: [String: Any])? = nil, title: String? = nil,
                            branch: String = "main", ago: TimeInterval) throws {
        let dir = cfg + "/projects/" + ClaudeService.mangle(cwd)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = Self.iso.string(from: Date().addingTimeInterval(-ago))
        let base: [String: Any] = ["cwd": cwd, "sessionId": id, "gitBranch": branch, "isSidechain": false,
                                   "userType": "external", "timestamp": stamp, "version": "2.1.302"]
        var lines = [json(base.merging(["type": "user", "uuid": id + "-1",
                                        "message": ["role": "user", "content": prompt]]) { $1 })]
        if let reply {
            lines.append(json(base.merging(["type": "assistant", "uuid": id + "-2", "message": [
                "role": "assistant", "model": "claude-opus-4-8", "content": [["type": "text", "text": reply]]]]) { $1 }))
        }
        if let tool {
            lines.append(json(base.merging(["type": "assistant", "uuid": id + "-3", "message": [
                "role": "assistant", "model": "claude-opus-4-8",
                "content": [["type": "tool_use", "id": "toolu_" + id, "name": tool.name, "input": tool.input]]]]) { $1 }))
        }
        if let title { lines.append(json(["type": "ai-title", "aiTitle": title, "sessionId": id])) }
        let path = dir + "/" + id + ".jsonl"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: path)
    }

    private func record(pid: Int32, sessionId: String, cwd: String, status: String?, waitingFor: String? = nil,
                        procStart: String? = nil, entrypoint: String = "cli") throws {
        var object: [String: Any] = ["pid": pid, "sessionId": sessionId, "cwd": cwd, "startedAt": 1_792_400_000_000,
                                     "kind": "interactive", "entrypoint": entrypoint]
        if let status { object["status"] = status }
        if let waitingFor { object["waitingFor"] = waitingFor }
        if let procStart { object["procStart"] = procStart }
        try Data(json(object).utf8).write(to: URL(fileURLWithPath: cfg + "/sessions/\(pid).json"))
    }

    private func sleeper(in dir: String? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        if let dir { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        try process.run()
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        return process
    }

    private func eventually(_ timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - The index

    /// Each session with how its conversation ends and where it stands: one stopped at a
    /// permission prompt shows the command, one closed its newest prompt and reply.
    func testTheIndexReadsEachSessionsPreviewAndState() async throws {
        try transcript("s-perm", cwd: shopPath, prompt: "run the webhook suite", tool: ("Bash", ["command": "npm test"]),
                       title: "Webhook suite", ago: 30)
        try transcript("s-old", cwd: shopPath, prompt: "tidy the README", reply: "Tidied.", ago: 3_600)
        try record(pid: 4242, sessionId: "s-perm", cwd: shopPath, status: "waiting", waitingFor: "permission prompt")
        let state = try makeState()
        state.liveProcessValidatorOverride = { _ in true }

        await state.refreshSessionIndex()

        let rows = try XCTUnwrap(state.recentSessionsByProject[shop.id])
        let perm = try XCTUnwrap(rows.first { $0.sessionId == "s-perm" })
        XCTAssertEqual(perm.state, .needsPermission)
        XCTAssertEqual(perm.preview?.pendingInput, "npm test")
        XCTAssertEqual(perm.title, "Webhook suite")
        XCTAssertEqual(perm.location, "main", "the project's own folder by its branch")
        let old = try XCTUnwrap(rows.first { $0.sessionId == "s-old" })
        XCTAssertEqual(old.state, .closed)
        XCTAssertEqual(old.preview?.prompt, "tidy the README")
        XCTAssertEqual(old.preview?.reply, "Tidied.")
        XCTAssertEqual(state.needsYouCount, 1)
        XCTAssertEqual(state.liveCountByAccount, ["work": 1])
        XCTAssertEqual(state.sessionCountByProject[shop.id], 2)
        XCTAssertEqual(state.projectsList.live.first?.shown.map(\.sessionId), ["s-perm"])
    }

    /// A session that runs is listed however old its last word, past the newest twelve.
    func testALiveSessionOlderThanTheNewestIsStillListed() async throws {
        for i in 0..<14 {
            try transcript("s-new-\(i)", cwd: shopPath, prompt: "prompt \(i)", reply: "ok", ago: TimeInterval(60 + i))
        }
        try transcript("s-live", cwd: shopPath, prompt: "a long one", reply: "still here", ago: 86_400)
        try record(pid: 4343, sessionId: "s-live", cwd: shopPath, status: "idle")
        let state = try makeState()
        state.liveProcessValidatorOverride = { _ in true }

        await state.refreshSessionIndex()

        let rows = try XCTUnwrap(state.recentSessionsByProject[shop.id])
        XCTAssertEqual(rows.count, AppState.sessionsPerProjectIndex + 1)
        XCTAssertEqual(rows.first { $0.sessionId == "s-live" }?.state, .yourTurn)
        XCTAssertEqual(state.sessionCountByProject[shop.id], 15)
        XCTAssertEqual(state.projectsList.live.first?.more, 14)
    }

    /// What runs is read again in place: the row keeps its place, its state changes; and a
    /// newer preview is read from a transcript that grew.
    func testTheLiveLayerUpdatesRowsInPlace() async throws {
        try transcript("s-a", cwd: shopPath, prompt: "first", reply: "done", ago: 60)
        try transcript("s-b", cwd: shopPath, prompt: "second", reply: "done too", ago: 30)
        try record(pid: 5001, sessionId: "s-a", cwd: shopPath, status: "idle")
        try record(pid: 5002, sessionId: "s-b", cwd: shopPath, status: "idle")
        let state = try makeState()
        state.liveProcessValidatorOverride = { _ in true }
        await state.refreshSessionIndex()
        state.freezeOrder()
        let before = state.listedSessionOrder.map(\.sessionId)

        try record(pid: 5001, sessionId: "s-a", cwd: shopPath, status: "waiting", waitingFor: "input needed")
        await state.refreshLive()
        XCTAssertEqual(state.listedSessionOrder.map(\.sessionId), before, "nothing moves while the list is in view")
        XCTAssertEqual(state.listedSessionOrder.first { $0.sessionId == "s-a" }?.state, .asksYou)
        XCTAssertEqual(state.needsYouCount, 1)

        let path = cfg + "/projects/" + ClaudeService.mangle(shopPath) + "/s-b.jsonl"
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((json(["type": "user", "cwd": shopPath!, "sessionId": "s-b", "uuid": "s-b-9",
                                                 "isSidechain": false, "timestamp": Self.iso.string(from: Date()),
                                                 "message": ["role": "user", "content": "now the changelog"]]) + "\n").utf8))
        try handle.close()
        await state.refreshPreviews()
        XCTAssertEqual(state.recentSessionsByProject[shop.id]?.first { $0.sessionId == "s-b" }?.preview?.prompt,
                       "now the changelog")

        state.thawOrder()
        XCTAssertEqual(state.listedSessionOrder.first?.sessionId, "s-a", "sorted again on the next open: it needs the user")
    }

    /// While the list is in view a session's process ending, and a new record appearing,
    /// are seen at once: a dispatch source on the process, and one on the records' folder.
    func testAnExitAndANewRecordArriveAsEvents() async throws {
        let first = try sleeper()
        let started = try XCTUnwrap(SessionRegistry.startTime(of: first.processIdentifier))
        try transcript("s-one", cwd: shopPath, prompt: "one", reply: "ok", ago: 5)
        try record(pid: first.processIdentifier, sessionId: "s-one", cwd: shopPath, status: "idle", procStart: started)
        let state = try makeState()
        await state.refreshLive()
        XCTAssertEqual(state.liveSessions.map(\.sessionId), ["s-one"])

        state.isPanelOpen = true
        defer { state.isPanelOpen = false }
        XCTAssertEqual(state.sessionWatch.watchedFolders, 1)
        XCTAssertEqual(state.sessionWatch.watchedProcesses, [first.processIdentifier])

        first.terminate()
        let ended = await eventually { state.liveSessions.isEmpty }
        XCTAssertTrue(ended, "the exit is seen without waiting for a refresh")

        let second = try sleeper()
        let secondStart = try XCTUnwrap(SessionRegistry.startTime(of: second.processIdentifier))
        try transcript("s-two", cwd: shopPath, prompt: "two", reply: "ok", ago: 1)
        try record(pid: second.processIdentifier, sessionId: "s-two", cwd: shopPath, status: "busy", procStart: secondStart)
        let started2 = await eventually { state.liveSessions.map(\.sessionId) == ["s-two"] }
        XCTAssertTrue(started2, "a new record is seen from the folder's own event")

        state.isPanelOpen = false
        XCTAssertEqual(state.sessionWatch.watchedFolders, 0, "nothing watched while the list is not in view")
    }

    // MARK: - Suggestions

    /// The folders Claude Code runs in that no project shows: each repository once, the
    /// project's own left out, an SDK's runs left out; Add makes it a project, ✕ is
    /// remembered in Grove's config.
    func testFoldersClaudeRunsInAreSuggested() async throws {
        let code = root.appendingPathComponent("code")
        let harbor = try FixtureLite.makeRepo(in: code, name: "harbor-api")
        let fleet = try FixtureLite.makeRepo(in: code, name: "fleet")
        let tool = try FixtureLite.makeRepo(in: code, name: "tool")
        try fm.createDirectory(at: harbor.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let sdk = try sleeper()
        let sdkStart = try XCTUnwrap(SessionRegistry.startTime(of: sdk.processIdentifier))
        try record(pid: sdk.processIdentifier, sessionId: "s-sdk", cwd: tool.path, status: "busy", procStart: sdkStart,
                   entrypoint: "sdk-ts")
        let state = try makeState()
        state.runningClaude = { [cfg = self.cfg!, shop = self.shopPath!] in [
            RunningClaude(pid: 701, cwd: harbor.appendingPathComponent("Sources").path, configDir: cfg),
            RunningClaude(pid: 702, cwd: harbor.path, configDir: cfg),
            RunningClaude(pid: 703, cwd: fleet.path, configDir: cfg),
            RunningClaude(pid: 704, cwd: shop, configDir: cfg),
            RunningClaude(pid: sdk.processIdentifier, cwd: tool.path, configDir: cfg),
        ] }

        await state.refreshSuggestions()
        XCTAssertEqual(state.suggestions.map(\.name), ["harbor-api", "fleet"])
        XCTAssertEqual(state.suggestions.first?.pids, [701, 702])
        XCTAssertEqual(state.account(ofConfigDir: cfg)?.config.name, "work")

        state.dismissSuggestion(try XCTUnwrap(state.suggestions.last))
        XCTAssertEqual(state.suggestions.map(\.name), ["harbor-api"])
        let saved = ConfigStore(url: root.appendingPathComponent("config.json")).load().config
        XCTAssertEqual(saved.dismissedSuggestions, [ProjectSuggestions.canonical(fleet.path)])
        await state.refreshSuggestions()
        XCTAssertEqual(state.suggestions.map(\.name), ["harbor-api"], "turned down once is enough")

        state.addSuggestion(try XCTUnwrap(state.suggestions.first))
        XCTAssertTrue(state.config.projects.contains { $0.name == "harbor-api" })
        await state.refreshSuggestions()
        XCTAssertEqual(state.suggestions, [], "a project now")
    }

    /// The switch's count is never a number the list does not explain: a session stopped on
    /// the user in a folder that is no project yet says so on its suggestion's row, one in
    /// any other folder on the Other folders row — each counted in one place only.
    func testWhatNeedsYouOutsideTheProjectsIsShownWhereItIs() throws {
        let state = try makeState()
        let harbor = ProjectSuggestion(path: "/made-up/code/harbor-api", pids: [701, 702],
                                       cwds: ["/made-up/code/harbor-api"], configDirs: [cfg])
        state.suggestions = [harbor]
        func session(_ id: String, _ cwd: String) -> ClaudeSession {
            ClaudeSession(id: id, cwd: cwd, title: nil, lastActivity: Date(), accountName: "work", gitBranch: nil)
        }
        state.otherFolders = [OtherFolder(path: "/made-up/dotfiles", sessions: [session("s-dot", "/made-up/dotfiles")]),
                              OtherFolder(path: "/made-up/code/harbor-api",
                                          sessions: [session("s-harbor", "/made-up/code/harbor-api")])]
        state.liveSessions = [
            LiveProcess(pid: 701, sessionId: "s-harbor", cwd: "/made-up/code/harbor-api", status: "waiting",
                        accountName: "work", waitingFor: "permission prompt"),
            LiveProcess(pid: 702, sessionId: "s-harbor-2", cwd: "/made-up/code/harbor-api", status: "busy",
                        accountName: "work"),
            LiveProcess(pid: 703, sessionId: "s-dot", cwd: "/made-up/dotfiles", status: "waiting",
                        accountName: "work", waitingFor: "input needed"),
        ]
        XCTAssertEqual(state.needsYouCount, 2)
        XCTAssertEqual(state.needsYou(in: harbor), 1)
        XCTAssertEqual(state.needsYou(in: state.otherFolders), 1, "harbor-api's is on its suggestion's row")
        state.dismissSuggestion(harbor)
        XCTAssertEqual(state.needsYou(in: state.otherFolders), 2, "turned down, it counts with the other folders")
    }

    /// An account's chip narrows the list, and its suggestions, to the account.
    func testOneAccountsSessionsAndFolders() async throws {
        let personal = root.appendingPathComponent("personal").path
        try transcript("s-work", cwd: shopPath, prompt: "work", reply: "ok", ago: 10)
        try record(pid: 6001, sessionId: "s-work", cwd: shopPath, status: "busy")
        let url = root.appendingPathComponent("config.json")
        try ConfigStore(url: url).save(GroveConfig(version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
                                                   projects: [shop],
                                                   accounts: [AccountConfig(name: "work", configDir: cfg),
                                                              AccountConfig(name: "personal", configDir: personal)]))
        let state = AppState(configStore: ConfigStore(url: url), folders: .beside(configFile: url))
        state.cmuxOverride = stubbedCmux()
        state.liveProcessValidatorOverride = { _ in true }
        await state.refreshSessionIndex()
        state.filter(account: "personal")
        XCTAssertEqual(state.listedSessionOrder, [])
        state.filter(account: "work")
        XCTAssertEqual(state.listedSessionOrder.map(\.sessionId), ["s-work"])
        XCTAssertEqual(state.liveCountByAccount["work"], 1)
    }

    /// The index reads what runs, then lists transcripts for a while; a record written in the
    /// meantime is read again and shown first. The index's older read never puts back what
    /// ran then — a session gone idle would show "Working" until the next read.
    func testAnOlderReadOfWhatRunsNeverWins() throws {
        let state = try makeState()
        let row = ProjectSessionRow(sessionId: "s-one", title: "checkout", cwd: shopPath, location: "acme-shop",
                                    accountName: "work", lastActivity: Date(), state: .working, cmuxWorkspaceId: nil)
        let busy = [LiveProcess(pid: 4242, sessionId: "s-one", cwd: shopPath, status: "busy", accountName: "work")]
        let idle = [LiveProcess(pid: 4242, sessionId: "s-one", cwd: shopPath, status: "idle", accountName: "work")]
        let indexRead = state.beginLiveRead()     // the index reads: busy
        let recordRead = state.beginLiveRead()    // the record changes: idle, shown first
        state.applyLive(idle, read: recordRead)
        state.apply(SessionIndex(rows: [shop.id: [row]], counts: [shop.id: 1], byProject: [:], other: [],
                                 otherFolders: [], live: busy), liveRead: indexRead)
        XCTAssertEqual(state.liveSessions, idle)
        XCTAssertEqual(state.recentSessionsByProject[shop.id]?.first?.state, .yourTurn,
                       "the index's rows take their states from the newer read")
        XCTAssertEqual(state.sessionCountByProject[shop.id], 1, "the rest of the index is taken")

        // Two reads at once, the older finishing last.
        let older = state.beginLiveRead(), newer = state.beginLiveRead()
        state.applyLive(busy, read: newer)
        state.applyLive(idle, read: older)
        XCTAssertEqual(state.liveSessions, busy)
        XCTAssertEqual(state.recentSessionsByProject[shop.id]?.first?.state, .working)
    }
}
