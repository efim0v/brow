// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation

/// How a session's transcript ends: the last thing asked, the last thing Claude wrote,
/// and where the turn stood when the file was last written. What a session row shows
/// so that two sessions of one project can be told apart at a glance.
public struct SessionPreview: Sendable, Equatable {
    /// Where the conversation stands, as its newest entries tell it. The file lags the
    /// session by a moment (Claude Code writes it asynchronously), and it cannot tell a
    /// tool that is running from one waiting for a permission prompt: for a live session
    /// the process's own record (`SessionRegistry`) says that, and wins.
    public enum Turn: String, Sendable, Equatable {
        /// A prompt, or a tool's result, came last: Claude owes a reply.
        case working
        /// A tool call came last, with no result yet: running, or waiting to be allowed.
        case tool
        /// Claude's reply ended the turn.
        case answered
        /// The user stopped the turn.
        case interrupted
        /// The turn ended in an API error.
        case failed
        /// Nothing in the end of the file says.
        case unknown
    }

    /// The newest prompt the user typed, on one line, at most `TranscriptTail.length`
    /// characters: the same text Claude Code's own session list shows.
    public let prompt: String?
    /// The newest text Claude wrote, on one line, markdown dropped.
    public let reply: String?
    /// The tool the newest entry calls, when `turn` is `.tool`.
    public let tool: String?
    /// The session's name: one given with `/rename` or `--name`, else the generated one.
    public let title: String?
    public let turn: Turn
    /// When the newest message was written.
    public let at: Date?

    public init(prompt: String?, reply: String?, tool: String?, title: String?, turn: Turn, at: Date?) {
        self.prompt = prompt
        self.reply = reply
        self.tool = tool
        self.title = title
        self.turn = turn
        self.at = at
    }
}

/// Reads a transcript's last 64 KiB, never the whole file, for a `SessionPreview`.
///
/// Why the end is enough: Claude Code reads the same 64 KiB at each end of a transcript
/// for its own session list, and it writes the session's metadata again (`last-prompt`,
/// `custom-title`, `ai-title`, …) after every 32 KiB it appends, so the last 64 KiB hold
/// a copy of them. The newest messages are there too, unless one of them is bigger than
/// the window (a pasted screenshot, a long tool result): then the window grows, up to
/// `maxWindow`.
///
/// The read is safe against a file being written: the first line of a window that
/// starts mid-file is dropped, a last line still being written fails to parse and is
/// skipped, and a file that shrank (Claude Code rewrites a transcript now and then) is
/// simply read again at its new end.
public enum TranscriptTail {
    public static let window = 64 << 10
    public static let maxWindow = 4 << 20
    /// Claude Code's own limit for the prompt it shows for a session.
    public static let length = 200

    public static func preview(path: String) -> SessionPreview? {
        var size = window
        while true {
            guard let tail = read(path: path, bytes: size) else { return nil }
            let result = preview(tail: tail.data, startsMidFile: tail.offset > 0)
            // Done when the window held a message, or there is nothing more to read.
            if result.found || tail.offset == 0 || size >= maxWindow { return result.preview }
            size = min(size * 4, maxWindow)
        }
    }

    /// The last `bytes` of the file, and where they start.
    static func read(path: String, bytes: Int) -> (data: Data, offset: Int)? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        let length = min(bytes, size)
        let offset = size - length
        var data = Data(count: length)
        let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset)) }
        guard got >= 0 else { return nil }
        if got < length { data.removeSubrange(got..<length) }   // shrank between fstat and pread
        return (data, offset)
    }

    /// The preview in `tail`, newest entry first. `found` is false when no message
    /// entry was in it at all, which asks for a bigger window.
    static func preview(tail: Data, startsMidFile: Bool) -> (preview: SessionPreview?, found: Bool) {
        var prompt: String?
        var promptRecord: String?          // `last-prompt`, for a window with no prompt in it
        var reply: String?
        var customTitle: String?
        var titleRecordSeen = false        // the newest `custom-title` decides, even an empty one
        var aiTitle: String?
        var turn: SessionPreview.Turn?
        var tool: String?
        var at: Date?
        var sawMessage = false

        forEachLineFromTheEnd(of: tail, startsMidFile: startsMidFile) { line in
            guard Self.mayMatter(line),
                  let object = (try? JSONSerialization.jsonObject(with: Data(buffer: line))) as? [String: Any],
                  let type = object["type"] as? String else { return true }
            switch type {
            case "custom-title":
                if !titleRecordSeen {
                    titleRecordSeen = true
                    customTitle = (object["customTitle"] as? String).flatMap(Self.oneLine)
                }
            case "ai-title":
                if aiTitle == nil { aiTitle = (object["aiTitle"] as? String).flatMap(Self.oneLine) }
            case "last-prompt":
                if promptRecord == nil { promptRecord = (object["lastPrompt"] as? String).flatMap(Self.oneLine) }
            case "system":
                // The end of a turn, written after Claude's last reply.
                if turn == nil, !sawMessage, (object["subtype"] as? String) == "turn_duration" { turn = .answered }
            case "user", "assistant":
                guard object["isSidechain"] as? Bool != true else { return true }
                let entry = Message(object, assistant: type == "assistant")
                if !sawMessage, entry.counts {
                    sawMessage = true
                    at = (object["timestamp"] as? String).flatMap(parseISODate)
                    if turn == nil { (turn, tool) = entry.turn }
                }
                if prompt == nil, let text = entry.prompt { prompt = text }
                if reply == nil, let text = entry.reply { reply = text }
            default:
                break
            }
            let titled = customTitle != nil || aiTitle != nil
            return !(prompt != nil && reply != nil && sawMessage && titled)
        }

        let title = customTitle ?? aiTitle
        let found = sawMessage || prompt != nil || reply != nil
        guard found || promptRecord != nil || title != nil else { return (nil, false) }
        return (SessionPreview(prompt: prompt ?? promptRecord, reply: reply, tool: tool, title: title,
                               turn: turn ?? .unknown, at: at), found)
    }

    /// Calls `body` with each complete line, the last one first, until it returns false.
    /// A window that starts mid-file starts mid-line: that first piece is not an entry.
    static func forEachLineFromTheEnd(of data: Data, startsMidFile: Bool,
                                      _ body: (UnsafeBufferPointer<UInt8>) -> Bool) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.assumingMemoryBound(to: UInt8.self)
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
            var floor = 0
            if startsMidFile {
                guard let newline = bytes.firstIndex(of: 0x0A) else { return }
                floor = newline + 1
            }
            var end = bytes.count
            while end > floor {
                var start = end
                while start > floor, base[start - 1] != 0x0A { start -= 1 }
                if end - start > 2, !body(UnsafeBufferPointer(start: base + start, count: end - start)) { return }
                end = start - 1
            }
        }
    }

    private static let patterns: [[UInt8]] = [
        #""type":"assistant""#, #""type":"user""#, #""type":"last-prompt""#,
        #""type":"custom-title""#, #""type":"ai-title""#, #""type":"system""#,
    ].map { Array($0.utf8) }

    /// Whether the line can be an entry a preview reads: it has one of their `"type":"…"`
    /// spelled the compact way Claude Code writes them. A string can't fake one (its
    /// quotes are escaped); a nested object can (a progress entry embeds a message), so
    /// the parsed top-level `type` has the last word.
    static func mayMatter(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        patterns.contains { pattern in
            pattern.withUnsafeBytes { memmem(line.baseAddress, line.count, $0.baseAddress, $0.count) != nil }
        }
    }

    /// One `user` or `assistant` entry, as far as a preview needs it.
    struct Message {
        /// Takes part in the conversation: not a meta entry (a command's caveat, a skill's
        /// prompt) and not the summary a compaction left.
        let counts: Bool
        let turn: (SessionPreview.Turn, String?)
        let prompt: String?
        let reply: String?

        init(_ object: [String: Any], assistant: Bool) {
            let message = object["message"] as? [String: Any]
            let content = message?["content"]
            let blocks = content as? [[String: Any]] ?? []
            let isMeta = object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true
            if assistant {
                counts = !isMeta
                let synthetic = object["isApiErrorMessage"] as? Bool == true
                    || (message?["model"] as? String) == "<synthetic>"
                let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                let call = blocks.last { $0["type"] as? String == "tool_use" }
                if synthetic {
                    turn = (.failed, nil)
                } else if let call {
                    turn = (.tool, call["name"] as? String)
                } else if texts.isEmpty {
                    turn = (.working, nil)          // thinking only: the reply is on its way
                } else {
                    turn = (.answered, nil)
                }
                prompt = nil
                reply = synthetic ? nil : texts.last.flatMap(TranscriptTail.replyLine)
            } else {
                var texts: [String] = []
                if let string = content as? String { texts = [string] }
                for block in blocks where block["type"] as? String == "text" {
                    if let text = block["text"] as? String { texts.append(text) }
                }
                let isResult = blocks.contains { $0["type"] as? String == "tool_result" }
                let interrupted = texts.contains { $0.hasPrefix("[Request interrupted by user") }
                turn = (interrupted ? .interrupted : .working, nil)   // a prompt or a result: Claude's move
                prompt = isMeta || isResult ? nil : texts.lazy.compactMap(TranscriptTail.promptLine).first
                reply = nil
                // A local command's echo (`/model`, its output) is not a turn.
                counts = !isMeta && (isResult || interrupted || prompt != nil)
            }
        }
    }

    // MARK: - text

    /// A prompt as Claude Code's session list shows it: a custom command with its
    /// arguments, `! command` for a shell line, and nothing for the wrappers Claude Code
    /// puts around command output, reminders and interruptions.
    static func promptLine(_ text: String) -> String? {
        if let command = tag("command-name", in: text) {
            guard let arguments = tag("command-args", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !arguments.isEmpty else { return nil }   // a bare command: /clear, /compact, /model
            return oneLine(command + " " + arguments)
        }
        if let shell = tag("bash-input", in: text) { return oneLine("! " + shell) }
        let trimmed = text.drop { $0.isWhitespace }
        if trimmed.hasPrefix("[Request interrupted by user") { return nil }
        if trimmed.first == "<", let second = trimmed.dropFirst().first, second.isLetter, second.isLowercase {
            return nil                                  // <local-command-stdout>, <system-reminder>, …
        }
        return oneLine(text)
    }

    /// Claude's reply on one line: code blocks left out, markdown marks dropped.
    static func replyLine(_ text: String) -> String? {
        var kept: [Substring] = []
        var inFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            var body = line.drop { "#>".contains($0) }.drop { $0 == " " }
            if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") { body = body.dropFirst(2) }
            if body.hasPrefix("|") || body.allSatisfy({ "-=*_| :".contains($0) }) { continue }   // tables, rules
            kept.append(body)
        }
        var line = kept.joined(separator: " ")
        for mark in ["**", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
        return oneLine(line)
    }

    /// Newlines and runs of spaces become one space; longer than `length`, the text is
    /// cut at a character boundary and ends in an ellipsis.
    static func oneLine(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        guard line.count > length else { return line }
        return String(line.prefix(length)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The text between `<name>` and `</name>`.
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}
