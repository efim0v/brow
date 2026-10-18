// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// Made-up transcripts laid out the way Claude Code 2.1 writes them: one compact JSON
/// object per line, the session's metadata written again after every 32 KiB appended.
/// Every name and word in them is invented.
struct TranscriptBuilder {
    let sessionId: String
    let cwd: String
    private(set) var lines: [String] = []
    /// The file's length so far, newlines included.
    private(set) var byteCount = 0
    private var parent: String?
    private var counter = 0
    private var bytesSinceMetadata = 0
    private var lastPrompt: String?
    var aiTitle: String?
    var customTitle: String?
    /// Re-append the metadata as Claude Code does (`false` writes it only where asked).
    var stampsMetadata = true

    init(sessionId: String = "5b1f0c2a-7d3e-4c1b-9a8f-0e6d5c4b3a21", cwd: String = "/Users/demo/Code/harbor") {
        self.sessionId = sessionId
        self.cwd = cwd
    }

    private mutating func uuid() -> String {
        counter += 1
        return String(format: "00000000-0000-4000-8000-%012d", counter)
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func stamp(_ seconds: Int) -> String {
        Self.iso.string(from: Date(timeIntervalSince1970: 1_792_000_000 + TimeInterval(seconds)))
    }

    private mutating func add(_ line: String) {
        lines.append(line)
        byteCount += line.utf8.count + 1
    }

    private mutating func append(_ object: [String: Any]) {
        let line = Self.json(object)
        add(line)
        bytesSinceMetadata += line.utf8.count + 1
        if stampsMetadata, bytesSinceMetadata >= 32 << 10 { appendMetadata() }
    }

    private mutating func entry(_ type: String, _ fields: [String: Any], at seconds: Int) -> [String: Any] {
        let id = uuid()
        var object: [String: Any] = [
            "parentUuid": parent ?? NSNull(), "isSidechain": false, "type": type, "uuid": id,
            "timestamp": stamp(seconds), "userType": "external", "entrypoint": "cli", "cwd": cwd,
            "sessionId": sessionId, "version": "2.1.302", "gitBranch": "main",
        ]
        for (key, value) in fields { object[key] = value }
        parent = id
        return object
    }

    mutating func prompt(_ text: String, at seconds: Int) {
        append(entry("user", ["message": ["role": "user", "content": text], "promptId": "p\(counter)"], at: seconds))
        lastPrompt = text.replacingOccurrences(of: "\n", with: " ")
    }

    mutating func promptWithImage(_ text: String, imageBytes: Int, at seconds: Int) {
        let image = String(repeating: "QUJD", count: imageBytes / 4)
        let content: [[String: Any]] = [
            ["type": "text", "text": text],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image]],
        ]
        append(entry("user", ["message": ["role": "user", "content": content], "imagePasteIds": [1]], at: seconds))
        lastPrompt = text
    }

    mutating func meta(_ text: String, at seconds: Int) {
        append(entry("user", ["message": ["role": "user", "content": text], "isMeta": true], at: seconds))
    }

    mutating func reply(_ text: String, at seconds: Int) {
        append(entry("assistant", ["message": [
            "id": "msg_\(counter)", "type": "message", "role": "assistant", "model": "claude-opus-4-8",
            "content": [["type": "text", "text": text]], "stop_reason": "end_turn",
        ], "requestId": "req_\(counter)"], at: seconds))
    }

    mutating func thinking(at seconds: Int) {
        append(entry("assistant", ["message": [
            "id": "msg_\(counter)", "type": "message", "role": "assistant", "model": "claude-opus-4-8",
            "content": [["type": "thinking", "thinking": "Weighing the two options.", "signature": "c2ln"]],
        ]], at: seconds))
    }

    mutating func toolCall(_ name: String, input: [String: Any], at seconds: Int) {
        append(entry("assistant", ["message": [
            "id": "msg_\(counter)", "type": "message", "role": "assistant", "model": "claude-opus-4-8",
            "content": [["type": "tool_use", "id": "toolu_\(counter)", "name": name, "input": input]],
            "stop_reason": "tool_use",
        ]], at: seconds))
    }

    /// A tool's result, `bytes` long (a file read, a test run's output).
    mutating func toolResult(bytes: Int, at seconds: Int) {
        let output = String(repeating: "line of build output\n", count: max(1, bytes / 21))
        append(entry("user", [
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_\(counter)", "content": output]]],
            "toolUseResult": ["stdout": output, "stderr": "", "interrupted": false],
        ], at: seconds))
    }

    mutating func apiError(at seconds: Int) {
        append(entry("assistant", ["message": [
            "id": "msg_\(counter)", "type": "message", "role": "assistant", "model": "<synthetic>",
            "content": [["type": "text", "text": "API Error: 529 overloaded"]],
        ], "isApiErrorMessage": true], at: seconds))
    }

    mutating func interrupt(at seconds: Int) {
        append(entry("user", ["message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]], at: seconds))
    }

    /// A line as it is, for odd cases (a torn write, a hand-made record).
    mutating func raw(_ line: String) {
        add(line)
    }

    mutating func turnEnd(at seconds: Int) {
        append(["type": "system", "subtype": "turn_duration", "durationMs": 61_000, "messageCount": 12,
                "timestamp": stamp(seconds), "uuid": uuid(), "isMeta": false])
    }

    mutating func progress(at seconds: Int) {
        append(["type": "progress", "data": ["type": "agent_progress", "message": [
            "type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "subagent chatter"]]],
        ]], "toolUseID": "toolu_x", "timestamp": stamp(seconds), "uuid": uuid()])
    }

    mutating func sidechainReply(_ text: String, at seconds: Int) {
        var object = entry("assistant", ["message": [
            "id": "msg_\(counter)", "type": "message", "role": "assistant", "model": "claude-opus-4-8",
            "content": [["type": "text", "text": text]],
        ]], at: seconds)
        object["isSidechain"] = true
        append(object)
    }

    /// The metadata Claude Code writes again after every 32 KiB.
    mutating func appendMetadata() {
        bytesSinceMetadata = 0
        if let lastPrompt { add(Self.json(["type": "last-prompt", "lastPrompt": String(lastPrompt.prefix(200)), "leafUuid": parent ?? "", "sessionId": sessionId])) }
        if let customTitle { add(Self.json(["type": "custom-title", "customTitle": customTitle, "sessionId": sessionId])) }
        if let aiTitle { add(Self.json(["type": "ai-title", "aiTitle": aiTitle, "sessionId": sessionId])) }
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A long, ordinary session: prompts, thinking, tool calls with sizeable results,
    /// replies and turn ends, until the file is about `bytes` long.
    static func long(bytes: Int, sessionId: String = "5b1f0c2a-7d3e-4c1b-9a8f-0e6d5c4b3a21",
                     cwd: String = "/Users/demo/Code/harbor") -> TranscriptBuilder {
        var b = TranscriptBuilder(sessionId: sessionId, cwd: cwd)
        b.aiTitle = "Retry uploads on flaky networks"
        var t = 0
        var turn = 0
        while b.byteCount < bytes {
            turn += 1
            b.prompt("Step \(turn): make the uploader retry with backoff and keep the progress bar honest", at: t)
            b.thinking(at: t + 1)
            for call in 0..<4 {
                b.toolCall(call % 2 == 0 ? "Read" : "Bash", input: ["file_path": "/Users/demo/Code/harbor/Sources/Upload\(call).swift"], at: t + 2)
                b.toolResult(bytes: 6_000, at: t + 3)
            }
            b.reply("Done with step \(turn): the uploader now retries three times with jittered backoff.", at: t + 4)
            b.turnEnd(at: t + 5)
            t += 60
        }
        return b
    }
}
