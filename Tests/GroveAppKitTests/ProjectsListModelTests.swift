// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveCore
@testable import GroveAppKit

/// The Projects list's rules: what shows, in what order, what a search finds, and that
/// nothing moves while the list is in view. Made-up projects and sessions only.
final class ProjectsListModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_400_000)
    private let shop = ProjectConfig(name: "acme-shop", path: "/Users/demo/Code/acme-shop")
    private let notes = ProjectConfig(name: "field-notes", path: "/Users/demo/Code/field-notes")
    private let harbor = ProjectConfig(name: "harbor-api", path: "/Users/demo/Code/harbor-api")

    private func row(_ id: String, _ state: SessionState, ago: TimeInterval, project: ProjectConfig,
                     account: String = "work", prompt: String = "a prompt", reply: String? = nil,
                     place: String? = nil) -> ProjectSessionRow {
        ProjectSessionRow(sessionId: id, title: "Title \(id)", cwd: project.path, location: place ?? project.name,
                          accountName: account, lastActivity: now.addingTimeInterval(-ago), state: state,
                          cmuxWorkspaceId: nil,
                          preview: SessionPreview(prompt: prompt, reply: reply, tool: nil, title: nil, turn: .answered, at: nil))
    }

    func testWhatNeedsTheUserComesFirstThenWorkThenTheRest() {
        let rows = [row("closed", .closed, ago: 1, project: shop), row("turn", .yourTurn, ago: 5, project: shop),
                    row("work-old", .working, ago: 100, project: shop), row("work-new", .working, ago: 10, project: shop),
                    row("ask", .asksYou, ago: 300, project: shop), row("perm", .needsPermission, ago: 30, project: shop)]
        XCTAssertEqual(ProjectsListModel.sorted(rows).map(\.sessionId),
                       ["perm", "ask", "work-new", "work-old", "turn", "closed"])
    }

    /// A project with something running shows at most three of its live sessions and says
    /// how many more it has; one with nothing running is a line, under NOTHING RUNNING.
    func testLiveProjectsShowThreeCardsAndQuietOnesALine() {
        let rows: [UUID: [ProjectSessionRow]] = [
            shop.id: [row("a", .working, ago: 1, project: shop), row("b", .yourTurn, ago: 2, project: shop),
                      row("c", .asksYou, ago: 3, project: shop), row("d", .yourTurn, ago: 4, project: shop),
                      row("e", .closed, ago: 5, project: shop)],
            notes.id: [row("n", .closed, ago: 50, project: notes)],
        ]
        let lists = ProjectsListModel.entries(projects: [shop, notes], rows: rows, counts: [shop.id: 9, notes.id: 4])
        XCTAssertEqual(lists.live.map(\.project.name), ["acme-shop"])
        XCTAssertEqual(lists.live.first?.shown.map(\.sessionId), ["c", "a", "b"])
        XCTAssertEqual(lists.live.first?.more, 6, "nine in all, three shown")
        XCTAssertEqual(lists.live.first?.needsYou, 1)
        XCTAssertEqual(lists.live.first?.working, 1)
        XCTAssertEqual(lists.quiet.map(\.project.name), ["field-notes"])
        XCTAssertEqual(lists.quiet.first?.newest?.sessionId, "n")
    }

    /// Projects with something that needs the user first, then working, then the rest.
    func testProjectsInOrderOfWhatTheyNeed() {
        let rows: [UUID: [ProjectSessionRow]] = [
            shop.id: [row("s", .yourTurn, ago: 1, project: shop)],
            notes.id: [row("n", .working, ago: 50, project: notes)],
            harbor.id: [row("h", .needsPermission, ago: 500, project: harbor)],
        ]
        let lists = ProjectsListModel.entries(projects: [shop, notes, harbor], rows: rows, counts: [:])
        XCTAssertEqual(lists.live.map(\.project.name), ["harbor-api", "field-notes", "acme-shop"])
    }

    /// While the list is in view nothing moves: states change in place, a session that
    /// starts is put after the others, and a project whose last session closes keeps its
    /// place with the closed card. The next open sorts again.
    func testNothingMovesWhileTheListIsInView() {
        var rows: [UUID: [ProjectSessionRow]] = [
            shop.id: [row("a", .yourTurn, ago: 1, project: shop), row("b", .working, ago: 2, project: shop)],
            notes.id: [row("n", .working, ago: 50, project: notes)],
            harbor.id: [row("h", .closed, ago: 500, project: harbor)],
        ]
        let opened = ProjectsListModel.entries(projects: [shop, notes, harbor], rows: rows, counts: [:])
        XCTAssertEqual(opened.live.map(\.project.name), ["acme-shop", "field-notes"])
        XCTAssertEqual(opened.live.first?.shown.map(\.sessionId), ["b", "a"])
        let order = ProjectsListModel.order(of: opened)

        // a stops on the user, n closes, a new session starts in shop, harbor wakes up
        rows[shop.id] = [row("a", .needsPermission, ago: 0, project: shop), row("b", .working, ago: 2, project: shop),
                         row("c", .working, ago: 0, project: shop)]
        rows[notes.id] = [row("n", .closed, ago: 0, project: notes)]
        rows[harbor.id] = [row("h", .working, ago: 0, project: harbor)]
        let kept = ProjectsListModel.entries(projects: [shop, notes, harbor], rows: rows, counts: [:], order: order)
        XCTAssertEqual(kept.live.map(\.project.name), ["acme-shop", "field-notes"])
        XCTAssertEqual(kept.live.first?.shown.map(\.sessionId), ["b", "a", "c"], "in place; the new one after")
        XCTAssertEqual(kept.live.first?.shown[1].state, .needsPermission, "the state changes in place")
        XCTAssertEqual(kept.live.last?.shown.map(\.state), [.closed], "closed, where it was")
        XCTAssertEqual(kept.quiet.map(\.project.name), ["harbor-api"], "it stays under NOTHING RUNNING until the next open")

        let next = ProjectsListModel.entries(projects: [shop, notes, harbor], rows: rows, counts: [:])
        XCTAssertEqual(next.live.map(\.project.name), ["acme-shop", "harbor-api"])
        XCTAssertEqual(next.live.first?.shown.map(\.sessionId), ["a", "c", "b"])
    }

    /// An account's chip narrows the list to its sessions.
    func testOneAccountsSessions() {
        let rows: [UUID: [ProjectSessionRow]] = [
            shop.id: [row("w", .working, ago: 1, project: shop, account: "work"),
                      row("p", .yourTurn, ago: 2, project: shop, account: "personal")],
            notes.id: [row("n", .closed, ago: 5, project: notes, account: "personal")],
        ]
        let lists = ProjectsListModel.entries(projects: [shop, notes], rows: rows, counts: [shop.id: 10], account: "work")
        XCTAssertEqual(lists.live.flatMap(\.shown).map(\.sessionId), ["w"])
        XCTAssertEqual(lists.live.first?.more, 0, "counted among the account's own")
        XCTAssertEqual(lists.quiet.map(\.project.name), [], "a project without the account's sessions is left out")
    }

    /// A search finds sessions by what they show — the prompt, Claude's line, the title,
    /// the folder or workspace — closed ones included; a project found by its name keeps all.
    func testTheSearchFindsClosedSessionsByWhatTheyShow() {
        let rows: [UUID: [ProjectSessionRow]] = [
            shop.id: [row("p", .needsPermission, ago: 1, project: shop, prompt: "retry failed webhook deliveries"),
                      row("c", .closed, ago: 999, project: shop, prompt: "verify the signature", reply: "Webhook payloads checked"),
                      row("w", .closed, ago: 999, project: shop, prompt: "nothing", place: "fix-payment-webhooks"),
                      row("x", .working, ago: 2, project: shop, prompt: "unrelated")],
            notes.id: [row("n", .closed, ago: 5, project: notes, prompt: "index the archive")],
        ]
        let found = ProjectsListModel.entries(projects: [shop, notes], rows: rows, counts: [:], needle: "webhook")
        XCTAssertEqual(found.live.map(\.project.name), ["acme-shop"])
        XCTAssertEqual(found.live.first?.shown.map(\.sessionId), ["p", "c", "w"])
        XCTAssertEqual(found.quiet, [])
        let byName = ProjectsListModel.entries(projects: [shop, notes], rows: rows, counts: [:], needle: "field")
        XCTAssertEqual(byName.live.first?.shown.map(\.sessionId), ["n"])
    }

    /// Sessions outside every project, by the folder around them, newest folder first.
    func testOtherFoldersGroupByTheirRepository() {
        func session(_ id: String, _ cwd: String, ago: TimeInterval) -> ClaudeSession {
            ClaudeSession(id: id, cwd: cwd, title: nil, lastActivity: now.addingTimeInterval(-ago), accountName: "work",
                          gitBranch: nil)
        }
        let folders = OtherFolder.group([session("a", "/Users/demo/dotfiles/zsh", ago: 50),
                                         session("b", "/Users/demo/Desktop/scratch", ago: 10),
                                         session("c", "/Users/demo/dotfiles", ago: 5)]) { cwd in
            cwd.hasPrefix("/Users/demo/dotfiles") ? "/Users/demo/dotfiles" : nil
        }
        XCTAssertEqual(folders.map(\.name), ["dotfiles", "scratch"])
        XCTAssertEqual(folders.first?.sessions.map(\.id), ["c", "a"])
    }
}

/// What a session card says, in each state.
final class SessionCardContentTests: XCTestCase {
    private func preview(turn: SessionPreview.Turn = .answered, tool: String? = nil, input: String? = nil,
                         question: String? = nil, reply: String? = "Done.", current: Bool = true,
                         sender: SessionPreview.Sender = .you) -> SessionPreview {
        SessionPreview(prompt: "make the uploader retry", reply: reply, tool: tool, title: "Uploader retries", turn: turn,
                       at: nil, pendingInput: input, question: question, sender: sender, replyIsCurrent: current)
    }

    func testNeedsPermissionShowsWhatItWantsToRun() {
        let content = SessionCardContent.make(state: .needsPermission,
                                              preview: preview(turn: .tool, tool: "Bash", input: "npm test"),
                                              title: "t", showsPreviews: true)
        XCTAssertEqual(content.claude, .wants(verb: "Wants to run", input: "npm test"))
        XCTAssertEqual(content.step, "Bash")
        XCTAssertEqual(content.prompt, "make the uploader retry")
        XCTAssertEqual(SessionCardContent.make(state: .needsPermission,
                                               preview: preview(turn: .tool, tool: "Edit", input: "Sources/Upload.swift"),
                                               title: "t", showsPreviews: true).claude,
                       .wants(verb: "Wants to edit", input: "Sources/Upload.swift"))
    }

    func testAsksYouShowsTheQuestion() {
        let content = SessionCardContent.make(state: .asksYou,
                                              preview: preview(turn: .tool, tool: "AskUserQuestion", question: "Keep both?"),
                                              title: "t", showsPreviews: true)
        XCTAssertEqual(content.claude, .question("Keep both?"))
    }

    /// Working with nothing written for the newest prompt yet: the step it is on.
    func testWorkingWithNoTextYetShowsTheStep() {
        let content = SessionCardContent.make(state: .working,
                                              preview: preview(turn: .tool, tool: "Bash", input: "npm test", current: false),
                                              title: "t", showsPreviews: true)
        XCTAssertEqual(content.claude, .step("Bash · npm test"))
        XCTAssertEqual(content.step, "Bash · npm test")
        XCTAssertEqual(SessionCardContent.make(state: .working, preview: preview(turn: .working, current: false),
                                               title: "t", showsPreviews: true).claude, .step("Thinking…"))
        XCTAssertEqual(SessionCardContent.make(state: .working, preview: preview(turn: .working, reply: "On it."),
                                               title: "t", showsPreviews: true).claude, .reply("On it."))
    }

    func testAPeersPromptIsLabelledWithItsName() {
        let content = SessionCardContent.make(state: .working, preview: preview(sender: .peer("atlas")), title: "t",
                                              showsPreviews: true)
        XCTAssertEqual(content.speaker, "atlas")
    }

    /// Previews off — for screen sharing — the title alone, in place of both lines.
    func testWithPreviewsOffTheTitleShows() {
        let content = SessionCardContent.make(state: .yourTurn, preview: preview(), title: "Uploader retries",
                                              showsPreviews: false)
        XCTAssertEqual(content.title, "Uploader retries")
        XCTAssertNil(content.prompt)
        XCTAssertNil(content.claude)
    }
}
