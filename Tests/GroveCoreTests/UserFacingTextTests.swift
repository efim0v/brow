// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import XCTest

/// The Workspaces engine came from Grove, and its code still says so in its module and
/// type names. What a user reads must not: Grove is now part of Brow. This reads every
/// string literal in GroveCore's and GroveAppKit's sources — comments skipped — and fails
/// on one that says "Grove", except the few below, which are about Grove.app itself or
/// name a file on disk.
final class UserFacingTextTests: XCTestCase {
    /// (file name, text the literal contains): each one says Grove on purpose.
    private static let allowed: [(file: String, text: String)] = [
        // The folder Workspaces keeps its files in, Grove's, which never moved, and the
        // request-pacing file the notch keeps there.
        ("WorkspacesFolders.swift", "Library/Application Support/Grove"),
        ("UsagePacingLedger.swift", "Library/Application Support/Grove"),
        // A write refused while Grove.app runs: it is about Grove.app.
        ("AppState.swift", "Grove.app is running and writes the same settings. Quit Grove"),
    ]

    func testNoUserFacingStringSaysGrove() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var found: [String] = []
        var files = 0
        for module in ["GroveCore", "GroveAppKit"] {
            let root = sources.appendingPathComponent(module)
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                files += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                for literal in Self.stringLiterals(in: source)
                where literal.text.range(of: #"\bGrove\b"#, options: .regularExpression) != nil {
                    let file = url.lastPathComponent
                    guard !Self.allowed.contains(where: { $0.file == file && literal.text.contains($0.text) }) else { continue }
                    found.append("\(module)/\(file):\(literal.line): \(literal.text.prefix(120))")
                }
            }
        }
        XCTAssertGreaterThan(files, 50, "the sources were found")
        XCTAssertEqual(found, [], "user-facing text that still says Grove:\n" + found.joined(separator: "\n"))
    }

    /// The reader itself: literals of each kind, comments skipped, interpolations read.
    func testTheReaderFindsLiteralsAndSkipsComments() {
        let source = #"""
        // "in a comment"
        let a = "plain \(b) and \"escaped\""
        /* "in a /* nested */ block" */
        let c = "outer \(d ? "inner" : "other") end"
        let e = #"raw "quoted" text"#
        let f = """
            multi "line"
            """
        """#
        let texts = Self.stringLiterals(in: source).map(\.text)
        XCTAssertEqual(texts.count, 6, "\(texts)")
        XCTAssertTrue(texts[0].hasPrefix("plain "))
        XCTAssertTrue(texts.contains("inner") && texts.contains("other"))
        XCTAssertTrue(texts.contains { $0.contains("raw \"quoted\" text") })
        XCTAssertTrue(texts.contains { $0.contains("multi \"line\"") })
        XCTAssertFalse(texts.contains { $0.contains("in a comment") || $0.contains("nested") })
        XCTAssertEqual(Self.stringLiterals(in: source).first?.line, 2)
    }

    // MARK: - A small Swift string-literal reader

    /// Every string literal in `source` with the line it starts on: its text as written,
    /// escapes and interpolations included. A literal inside an interpolation is listed on
    /// its own too. Comments, nested block comments included, are skipped.
    static func stringLiterals(in source: String) -> [(line: Int, text: String)] {
        let chars = Array(source)
        var literals: [(line: Int, text: String)] = []
        var i = 0
        var line = 1

        func at(_ k: Int, _ s: String) -> Bool {
            let pattern = Array(s)
            guard k + pattern.count <= chars.count else { return false }
            return Array(chars[k..<(k + pattern.count)]) == pattern
        }

        // Reads one literal that starts at `i` (after any `#`s, `hashes` of them), and
        // the literals nested in its interpolations.
        func readLiteral(hashes: Int) {
            let startLine = line
            let multiline = at(i, "\"\"\"")
            let quote = multiline ? "\"\"\"" : "\""
            let close = quote + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            i += quote.count
            var text = ""
            while i < chars.count {
                if at(i, close) { i += close.count; break }
                if at(i, escape) {
                    let next = i + escape.count
                    if next < chars.count, chars[next] == "(" {
                        // An interpolation: its text belongs to the literal, and any
                        // literal inside it is a literal of its own.
                        text += escape + "("
                        i = next + 1
                        var depth = 1
                        while i < chars.count, depth > 0 {
                            if chars[i] == "\"" {
                                let before = literals.count
                                readLiteral(hashes: 0)
                                text += literals[before...].map { "\"\($0.text)\"" }.joined()
                                continue
                            }
                            if chars[i] == "(" { depth += 1 }
                            if chars[i] == ")" { depth -= 1 }
                            if chars[i] == "\n" { line += 1 }
                            text.append(chars[i])
                            i += 1
                        }
                        continue
                    }
                    // Any other escape: the backslash and the escaped character together.
                    text += escape
                    i = next
                    if i < chars.count {
                        if chars[i] == "\n" { line += 1 }
                        text.append(chars[i])
                        i += 1
                    }
                    continue
                }
                if chars[i] == "\n" {
                    line += 1
                    if !multiline { i += 1; break }   // unterminated: stop at the line's end
                }
                text.append(chars[i])
                i += 1
            }
            literals.append((startLine, text))
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if at(i, "//") {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if at(i, "/*") {
                var depth = 0
                repeat {
                    if at(i, "/*") { depth += 1; i += 2 }
                    else if at(i, "*/") { depth -= 1; i += 2 }
                    else { if chars[i] == "\n" { line += 1 }; i += 1 }
                } while depth > 0 && i < chars.count
                continue
            }
            if c == "#" {
                var k = i
                while k < chars.count, chars[k] == "#" { k += 1 }
                if k < chars.count, chars[k] == "\"" {
                    let hashes = k - i
                    i = k
                    readLiteral(hashes: hashes)
                    continue
                }
                i += 1
                continue
            }
            if c == "\"" { readLiteral(hashes: 0); continue }
            i += 1
        }
        return literals
    }
}
