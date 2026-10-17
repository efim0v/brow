// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// The working folders a config folder's Claude Code sessions ran in, read from the
/// transcripts themselves: every turn of a transcript records its `cwd`.
///
/// `ClaudeRetention` needs them. Claude Code reads `cleanupPeriodDays` from the project
/// settings of the folder a session starts in too, and that session's sweep then deletes
/// old transcripts in every project of its config folder — so a short period in any one
/// project's settings applies to all of them.
///
/// The folder name under `projects/` is no use for this: it is the path with every
/// character other than a letter or a digit turned into `-`, so it can't be turned back.
public enum TranscriptCwds {
    /// How much of a transcript is read looking for a `cwd`: its first records, never the
    /// whole conversation.
    static let maxBytes = 1 << 20
    private static let chunk = 16 << 10

    /// The `cwd` of one transcript: that of its first record that has one. nil when none
    /// of its first records does (no turn yet) or the file can't be read. A transcript's
    /// first `cwd` never changes, so the answer is kept for as long as the process runs;
    /// a nil is asked again once the file has changed.
    public static func cwd(ofTranscriptAt path: String) -> String? {
        // A found one never changes: no need even to look at the file.
        if let known = cache.found(path) { return known }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if cache.foundNone(path, modified: modified) { return nil }
        let cwd = readCwd(path)
        cache.store(path, cwd: cwd, modified: modified)
        return cwd
    }

    /// Every `cwd` the transcripts under `<configDir>/projects/*/` record — a shared
    /// workspace's link followed — and those under each of `extraFolders` (laid out the
    /// same way, `<folder>/*/*.jsonl`: the safety net's copies of transcripts that are
    /// gone). Deduplicated and sorted.
    public static func all(configDir: String, extraFolders: [String] = []) -> [String] {
        let fm = FileManager.default
        var found = Set<String>()
        for root in [configDir + "/projects"] + extraFolders {
            for folder in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !folder.hasPrefix(".") {
                let dir = root + "/" + folder
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                    if let cwd = cwd(ofTranscriptAt: dir + "/" + name) { found.insert(cwd) }
                }
            }
        }
        return found.sorted()
    }

    /// Reads the file a chunk at a time, looking at each complete line, until a record
    /// with a `cwd` turns up or `maxBytes` have been read.
    static func readCwd(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        var read = 0
        while read < maxBytes {
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            read += data.count
            buffer.append(data)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                if let cwd = cwd(inRecord: Data(buffer[lineStart..<newline])) { return cwd }
                lineStart = buffer.index(after: newline)
            }
            buffer = Data(buffer[lineStart...])
        }
        // The last line of a file that ends without a newline, if it fit.
        return read < maxBytes ? cwd(inRecord: buffer) : nil
    }

    static func cwd(inRecord line: Data) -> String? {
        guard line.range(of: Data(#""cwd""#.utf8)) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/")
        else { return nil }
        return cwd
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (cwd: String?, modified: Date?)] = [:]

        /// The `cwd` found in this file before; it stands for good.
        func found(_ path: String) -> String? {
            lock.withLock { entries[path]?.cwd }
        }

        /// Whether this file had none the last time it was read, and has not changed since.
        func foundNone(_ path: String, modified: Date?) -> Bool {
            lock.withLock {
                guard let entry = entries[path] else { return false }
                return entry.cwd == nil && entry.modified == modified
            }
        }

        func store(_ path: String, cwd: String?, modified: Date?) {
            lock.withLock { entries[path] = (cwd, modified) }
        }
    }
}
