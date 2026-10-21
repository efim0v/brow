// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// A made-up CLAUDE_CONFIG_DIR, laid out the way Claude Code 2.1.302 writes it when agents
/// message each other: one account, "work", with two sessions talking over their sockets,
/// a named subagent, an in-process teammate of an agent team, a session on another Mac and
/// a send that failed. Every name, path, id and text in it is invented.
///
///     sessions/<pid>.json                       the session records
///     sessions/<pid>.<sha256>.key               an inbox key: a decoy, mode 000, never opened
///     projects/<folder>/<session>.jsonl         the main transcripts
///     projects/<folder>/<session>/subagents/agent-<id>.jsonl (+ .meta.json)
///     teams/session-<8>/config.json, inboxes/<member>.json
enum AgentCommsFixture {
    static let atlas = "1a2b3c4d-1111-4111-8111-111111111111"
    static let harbor = "2b3c4d5e-2222-4222-8222-222222222222"
    static let atlasCwd = "/Users/demo/Code/atlas"
    static let harborCwd = "/Users/demo/Code/harbor"
    static let atlasSocket = "/tmp/cc-socks/41001.sock"
    static let harborSocket = "/tmp/cc-socks/41002.sock"
    static let team = "session-" + String(atlas.prefix(8))
    static let lumen = "a0123456789abcdef"
    static let scout = "a89abcdef01234567"
    static let m1 = "5f0e2a10-3b4c-4d5e-8f60-718293a4b5c6"   // atlas -> harbor
    static let m2 = "6a1f3b21-4c5d-4e6f-9071-8293a4b5c6d7"   // harbor -> atlas
    static let m3 = "7b204c32-5d6e-4f70-8182-93a4b5c6d7e8"   // team-lead -> scout
    static let m4 = "8c315d43-6e7f-4081-9293-a4b5c6d7e8f9"   // scout -> team-lead
    static let keyFile = "41001." + String(repeating: "0", count: 64) + ".key"

    static func mangle(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// An envelope exactly as the sender's Claude Code builds it.
    static func envelope(_ tag: String, _ attributes: [(String, String)], _ body: String) -> String {
        let text = attributes.map { " \($0.0)=\"\($0.1)\"" }.joined()
        return "<\(tag)\(text)>\n\(body)\n</\(tag)>"
    }

    static func entry(_ session: String, _ cwd: String, _ type: String, _ uuid: String, _ parent: String?,
                      _ ts: String, _ extra: [String: Any], agent: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["parentUuid": parent ?? NSNull(), "isSidechain": agent != nil,
                                  "userType": "external", "cwd": cwd, "sessionId": session, "version": "2.1.302",
                                  "gitBranch": "main", "type": type, "uuid": uuid, "timestamp": ts]
        if let agent { row["agentId"] = agent }
        for (key, value) in extra { row[key] = value }
        return row
    }

    static func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["message": ["id": "msg_" + id.suffix(8), "type": "message", "role": "assistant", "model": "claude-opus-4-8",
                     "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    static func toolResult(_ id: String, _ data: [String: Any]) -> [String: Any] {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        return ["message": ["role": "user", "content": [["tool_use_id": id, "type": "tool_result",
                                                         "content": [["type": "text", "text": text]]]]],
                "toolUseResult": data]
    }

    static func json(_ object: Any, pretty: Bool = false) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func writeLines(_ rows: [[String: Any]], to path: String, partial: String? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var text = rows.map { json($0) + "\n" }.joined()
        if let partial { text += partial }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func write(_ object: Any, to path: String, pretty: Bool = true) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(json(object, pretty: pretty).utf8).write(to: URL(fileURLWithPath: path))
    }

    /// The partial last line of harbor's transcript, and what finishes it.
    static let partial = #"{"parentUuid":"u-h05","isSidechain":false,"type":"assistant","message":{"content":[{"type":"tool_use","name":"SendMe"#
    static let partialRest = #"ssage","input":{"to":"atlas","message":"done"}}]},"uuid":"u-h06"}"# + "\n"

    /// Builds the tree under `root`; returns the config folder.
    @discardableResult
    static func build(at root: URL) throws -> String {
        let cfg = root.appendingPathComponent("config-work").path

        // --- the session records ---
        try write(["pid": 41001, "sessionId": atlas, "cwd": atlasCwd, "startedAt": 1_792_400_280_000,
                   "procStart": "Sun Oct 19 08:58:00 2026", "version": "2.1.302", "peerProtocol": 1,
                   "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
                   "kind": "interactive", "entrypoint": "cli", "pidDomain": "darwin",
                   "messagingSocketPath": atlasSocket, "name": "atlas", "nameSource": "user",
                   "nameSince": 1_792_400_280_000, "status": "busy", "statusUpdatedAt": 1_792_400_400_000,
                   "updatedAt": 1_792_400_400_000], to: cfg + "/sessions/41001.json", pretty: false)
        try write(["pid": 41002, "sessionId": harbor, "cwd": harborCwd, "startedAt": 1_792_400_100_000,
                   "procStart": "Sun Oct 19 08:55:00 2026", "version": "2.1.302", "peerProtocol": 1,
                   "peerFeatures": ["notify_idle", "artifact_yield"], "kind": "bg", "pidDomain": "darwin",
                   "messagingSocketPath": harborSocket, "name": "harbor", "nameSource": "derived",
                   "jobId": "k7f2q9ab", "updatedAt": 1_792_400_300_000], to: cfg + "/sessions/41002.json", pretty: false)
        // The inbox key: never to be opened by an observer.
        let key = cfg + "/sessions/" + keyFile
        try write(["peerToken": String(repeating: "0", count: 32), "pidDomain": "darwin"], to: key, pretty: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: key)

        // --- atlas: the team lead, sends and receives ---
        let aDir = cfg + "/projects/" + mangle(atlasCwd)
        let reply = envelope("cross-session-message", [("from", "uds:" + harborSocket), ("from-name", "harbor")],
                             "Thanks — rebasing on main now.")
        let atlasRows: [[String: Any]] = [
            entry(atlas, atlasCwd, "user", "u-a01", nil, "2026-10-19T09:00:00.000Z",
                  ["message": ["role": "user", "content": "Tell harbor the schema migration is done"]]),
            entry(atlas, atlasCwd, "assistant", "u-a02", "u-a01", "2026-10-19T09:00:02.000Z",
                  toolUse("toolu_01AtlasSend0001", "SendMessage", [
                      "to": "harbor", "summary": "schema migration done",
                      "message": "Schema migration finished\nThe new column is tenant_id."])),
            entry(atlas, atlasCwd, "user", "u-a03", "u-a02", "2026-10-19T09:00:02.300Z",
                  toolResult("toolu_01AtlasSend0001", [
                      "success": true, "message": "“schema migration done” → harbor",
                      "display": "“schema migration done” → harbor", "msg_id": m1])),
            // harbor's reply arrives while atlas works: a queue record, then the attachment
            ["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-10-19T09:00:09.000Z",
             "sessionId": atlas, "content": reply],
            entry(atlas, atlasCwd, "attachment", "u-a04", "u-a03", "2026-10-19T09:00:09.400Z",
                  ["attachment": ["type": "queued_command", "prompt": reply, "source_uuid": "q-a04",
                                  "origin": ["kind": "peer", "from": "uds:" + harborSocket, "verifiedPeerPid": 41002,
                                             "msg_id": m2, "name": "harbor", "body": "Thanks — rebasing on main now."],
                                  "isMeta": true]]),
            // a named background subagent
            entry(atlas, atlasCwd, "assistant", "u-a05", "u-a04", "2026-10-19T09:00:12.000Z",
                  toolUse("toolu_01AtlasAgent01", "Agent", [
                      "description": "Check tenant indexes", "subagent_type": "general-purpose", "name": "lumen",
                      "run_in_background": true, "prompt": "List the indexes on tables that carry tenant_id."])),
            entry(atlas, atlasCwd, "user", "u-a06", "u-a05", "2026-10-19T09:00:12.500Z",
                  toolResult("toolu_01AtlasAgent01", [
                      "status": "async_launched", "isAsync": true, "agentId": lumen,
                      "description": "Check tenant indexes",
                      "prompt": "List the indexes on tables that carry tenant_id.",
                      "outputFile": "/tmp/claude-501/demo/tasks/" + lumen + ".output"])),
            entry(atlas, atlasCwd, "assistant", "u-a07", "u-a06", "2026-10-19T09:00:20.000Z",
                  toolUse("toolu_01AtlasSend0002", "SendMessage", [
                      "to": "lumen", "summary": "also check FKs", "message": "Also check the foreign keys on tenant_id."])),
            entry(atlas, atlasCwd, "user", "u-a08", "u-a07", "2026-10-19T09:00:20.200Z",
                  toolResult("toolu_01AtlasSend0002", [
                      "success": true, "message": "Message queued for delivery to lumen at its next tool round.",
                      "pin": ["name": "lumen", "id": lumen, "ref": "3fa9c1"]])),
            entry(atlas, atlasCwd, "user", "u-a09", "u-a08", "2026-10-19T09:01:05.000Z",
                  ["message": ["role": "user", "content": envelope("agent-message", [("from", "lumen")],
                                                                   "Indexes are fine; one FK is missing.")],
                   "isMeta": true,
                   "origin": ["kind": "peer", "from": "lumen", "senderTaskId": "a7k2m9q1x", "name": "lumen",
                              "body": "Indexes are fine; one FK is missing."]]),
            // an agent-team teammate
            entry(atlas, atlasCwd, "assistant", "u-a10", "u-a09", "2026-10-19T09:01:30.000Z",
                  toolUse("toolu_01AtlasAgent02", "Agent", [
                      "description": "Find the flaky test", "name": "scout",
                      "prompt": "Find which test fails only sometimes and why."])),
            entry(atlas, atlasCwd, "user", "u-a11", "u-a10", "2026-10-19T09:01:30.600Z",
                  toolResult("toolu_01AtlasAgent02", [
                      "status": "teammate_spawned", "prompt": "Find which test fails only sometimes and why.",
                      "agentId": scout, "teammate_id": "scout@" + team, "agent_id": scout,
                      "agent_type": "general-purpose", "model": "claude-opus-4-8", "name": "scout",
                      "color": "blue", "tmux_session_name": "in-process", "tmux_window_name": "in-process",
                      "tmux_pane_id": "in-process", "team_name": team, "is_splitpane": false,
                      "plan_mode_required": false])),
            entry(atlas, atlasCwd, "assistant", "u-a12", "u-a11", "2026-10-19T09:01:40.000Z",
                  toolUse("toolu_01AtlasSend0003", "SendMessage", [
                      "to": "scout", "summary": "start with CI logs", "message": "Start with the last three CI runs."])),
            entry(atlas, atlasCwd, "user", "u-a13", "u-a12", "2026-10-19T09:01:40.100Z",
                  toolResult("toolu_01AtlasSend0003", [
                      "success": true, "message": "Message sent to scout's inbox", "msg_id": m3,
                      "routing": ["sender": "team-lead", "senderColor": "purple", "target": "@scout",
                                  "targetColor": "blue", "summary": "start with CI logs",
                                  "content": "Start with the last three CI runs."]])),
            entry(atlas, atlasCwd, "user", "u-a14", "u-a13", "2026-10-19T09:03:00.000Z",
                  ["message": ["role": "user", "content": envelope(
                      "teammate-message", [("teammate_id", "scout"), ("color", "blue"), ("summary", "flaky test cause")],
                      "It depends on the wall clock.")], "isMeta": true]),
            // a send nobody could take
            entry(atlas, atlasCwd, "assistant", "u-a15", "u-a14", "2026-10-19T09:04:00.000Z",
                  toolUse("toolu_01AtlasSend0004", "SendMessage", ["to": "nobody-here", "message": "Are you there?"])),
            entry(atlas, atlasCwd, "user", "u-a16", "u-a15", "2026-10-19T09:04:00.200Z",
                  toolResult("toolu_01AtlasSend0004", [
                      "success": false,
                      "message": "No agent named 'nobody-here' is reachable.\nUse ListAgents to see everyone you can message.",
                      "display": "Not sent — no agent named 'nobody-here' is reachable."])),
        ]
        try writeLines(atlasRows, to: aDir + "/" + atlas + ".jsonl")

        // the subagent's own transcript and sidecar
        let sub = aDir + "/" + atlas + "/subagents"
        try writeLines([
            entry(atlas, atlasCwd, "user", "u-l01", nil, "2026-10-19T09:00:12.600Z",
                  ["message": ["role": "user", "content": "List the indexes on tables that carry tenant_id."]], agent: lumen),
            entry(atlas, atlasCwd, "user", "u-l02", "u-l01", "2026-10-19T09:00:24.000Z",
                  ["message": ["role": "user", "content": "Also check the foreign keys on tenant_id."],
                   "isMeta": true, "origin": ["kind": "coordinator"]], agent: lumen),
            entry(atlas, atlasCwd, "assistant", "u-l03", "u-l02", "2026-10-19T09:01:04.000Z",
                  toolUse("toolu_01LumenSend0001", "SendMessage", [
                      "to": "main", "summary": "FK missing", "message": "Indexes are fine; one FK is missing."]),
                  agent: lumen),
        ], to: sub + "/agent-" + lumen + ".jsonl")
        try write(["agentType": "general-purpose", "description": "Check tenant indexes", "name": "lumen",
                   "toolUseId": "toolu_01AtlasAgent01", "spawnDepth": 1, "cwd": atlasCwd],
                  to: sub + "/agent-" + lumen + ".meta.json")
        try write(["agentType": "general-purpose", "description": "Find the flaky test", "name": "scout",
                   "toolUseId": "toolu_01AtlasAgent02", "taskKind": "in_process_teammate", "teamName": team,
                   "color": "blue"], to: sub + "/agent-" + scout + ".meta.json")
        // an in-process teammate's transcript lives with the lead's subagents; its turns come wrapped
        try writeLines([
            entry(atlas, atlasCwd, "user", "u-s01", nil, "2026-10-19T09:01:30.700Z",
                  ["message": ["role": "user", "content": envelope(
                      "teammate-message", [("teammate_id", "team-lead"), ("summary", "Find the flaky test")],
                      "Find which test fails only sometimes and why.")]], agent: scout),
            entry(atlas, atlasCwd, "user", "u-s02", "u-s01", "2026-10-19T09:01:41.000Z",
                  ["message": ["role": "user", "content": envelope(
                      "teammate-message",
                      [("teammate_id", "team-lead"), ("color", "purple"), ("summary", "start with CI logs")],
                      "Start with the last three CI runs.")], "isMeta": true], agent: scout),
            entry(atlas, atlasCwd, "assistant", "u-s03", "u-s02", "2026-10-19T09:02:57.000Z",
                  toolUse("toolu_01ScoutSend00001", "SendMessage", [
                      "to": "team-lead", "summary": "flaky test cause", "message": "It depends on the wall clock."]),
                  agent: scout),
            entry(atlas, atlasCwd, "user", "u-s04", "u-s03", "2026-10-19T09:02:58.100Z",
                  toolResult("toolu_01ScoutSend00001", [
                      "success": true, "message": "Message sent to team-lead's inbox", "msg_id": m4,
                      "routing": ["sender": "scout", "senderColor": "blue", "target": "@team-lead",
                                  "targetColor": "purple", "summary": "flaky test cause",
                                  "content": "It depends on the wall clock."]]), agent: scout),
        ], to: sub + "/agent-" + scout + ".jsonl")

        // --- harbor: a background session that receives and replies ---
        let hDir = cfg + "/projects/" + mangle(harborCwd)
        try writeLines([
            entry(harbor, harborCwd, "user", "u-h01", nil, "2026-10-19T09:00:02.900Z",
                  ["message": ["role": "user", "content": envelope(
                      "cross-session-message", [("from", "uds:" + atlasSocket), ("from-name", "atlas")],
                      "Schema migration finished\nThe new column is tenant_id.")],
                   "isMeta": true,
                   "origin": ["kind": "peer", "from": "uds:" + atlasSocket, "verifiedPeerPid": 41001, "msg_id": m1,
                              "name": "atlas", "body": "Schema migration finished\nThe new column is tenant_id."]]),
            entry(harbor, harborCwd, "assistant", "u-h02", "u-h01", "2026-10-19T09:00:08.000Z",
                  toolUse("toolu_01HarborSend001", "SendMessage", [
                      "to": "uds:" + atlasSocket, "summary": "thanks, rebasing", "message": "Thanks — rebasing on main now."])),
            entry(harbor, harborCwd, "user", "u-h03", "u-h02", "2026-10-19T09:00:08.300Z",
                  toolResult("toolu_01HarborSend001", [
                      "success": true, "message": "“thanks, rebasing” → uds:" + atlasSocket, "msg_id": m2])),
            entry(harbor, harborCwd, "user", "u-h04", "u-h03", "2026-10-19T09:05:00.000Z",
                  ["message": ["role": "user", "content": envelope(
                      "cross-session-message",
                      [("from", "bridge:session_01FixtureRemote7"), ("from-name", "studio-mac")],
                      "Release notes are ready for review.")],
                   "isMeta": true,
                   "origin": ["kind": "peer", "from": "bridge:session_01FixtureRemote7", "name": "studio-mac",
                              "body": "Release notes are ready for review."]]),
            // attributes in another order, plus one this reader has never seen
            entry(harbor, harborCwd, "user", "u-h05", "u-h04", "2026-10-19T09:06:00.000Z",
                  ["message": ["role": "user", "content":
                      "<cross-session-message from-name=\"atlas\" from-x=\"1\" from=\"uds:" + atlasSocket
                      + "\">\nOne more thing.\n</cross-session-message>"], "isMeta": true]),
        ], to: hDir + "/" + harbor + ".jsonl", partial: partial)

        // --- the team (only while the lead session runs with agent teams on) ---
        let tDir = cfg + "/teams/" + team
        try write(["name": team, "createdAt": 1_792_400_400_000, "leadAgentId": "team-lead@" + team,
                   "leadSessionId": atlas,
                   "members": [
                       ["agentId": "team-lead@" + team, "name": "team-lead", "agentType": "team-lead",
                        "joinedAt": 1_792_400_400_000, "tmuxPaneId": "leader", "cwd": atlasCwd,
                        "subscriptions": [], "backendType": "in-process"],
                       ["agentId": "scout@" + team, "name": "scout", "color": "blue", "agentType": "general-purpose",
                        "planModeRequired": false, "joinedAt": 1_792_400_490_000, "tmuxPaneId": "in-process",
                        "cwd": atlasCwd, "subscriptions": [], "backendType": "in-process"],
                   ]], to: tDir + "/config.json")
        try write([["from": "team-lead", "text": "Start with the last three CI runs.", "summary": "start with CI logs",
                    "timestamp": "2026-10-19T09:01:40.050Z", "color": "purple", "read": true, "msg_id": m3]],
                  to: tDir + "/inboxes/scout.json")
        let idle = json(["type": "idle_notification", "from": "scout", "timestamp": "2026-10-19T09:03:10.000Z",
                         "idleReason": "available", "summary": "found the cause"])
        try write([["from": "scout", "text": "It depends on the wall clock.", "summary": "flaky test cause",
                    "timestamp": "2026-10-19T09:02:58.000Z", "color": "blue", "read": true, "msg_id": m4],
                   ["from": "scout", "text": idle, "timestamp": "2026-10-19T09:03:10.000Z", "color": "blue",
                    "read": false]], to: tDir + "/inboxes/team-lead.json")
        return cfg
    }

    /// Gives the decoy key its mode back, so the temp folder can be removed.
    static func release(_ cfg: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfg + "/sessions/" + keyFile)
    }
}
