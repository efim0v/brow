// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// A message one agent sent another, as it lands in the receiver's transcript: wrapped in a
/// tag the sender's Claude Code writes around it (2.1.224 and later).
///
/// - `<cross-session-message from="uds:/tmp/cc-socks/41001.sock" from-name="atlas">` — from
///   another session, on this Mac (a socket address) or another (`bridge:…`).
/// - `<teammate-message teammate_id="scout" color="blue" summary="…">` — from a teammate of
///   an agent team.
/// - `<agent-message from="lumen">` — from one of the session's own subagents.
///
/// Read leniently: attributes in any order, unknown ones kept, several envelopes in one
/// text. The formats are Claude Code's own and may change between versions.
public struct AgentEnvelope: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case crossSession = "cross-session-message"
        case teammate = "teammate-message"
        case agent = "agent-message"
    }

    public let kind: Kind
    public let attributes: [String: String]
    /// The message itself, as the sender wrote it.
    public let body: String

    public init(kind: Kind, attributes: [String: String], body: String) {
        self.kind = kind
        self.attributes = attributes
        self.body = body
    }

    /// Who sent it, as the envelope names them: `from-name` for another session,
    /// `teammate_id` for a teammate, `from` for a subagent. nil when it does not say.
    public var senderName: String? {
        let name: String?
        switch kind {
        case .crossSession: name = attributes["from-name"]
        case .teammate: name = attributes["teammate_id"]
        case .agent: name = attributes["from"]
        }
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every envelope in `text`, in order. Cheap when there is none: a text without
    /// "-message" is not searched.
    public static func all(in text: String) -> [AgentEnvelope] {
        guard text.contains("-message") else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return envelope.matches(in: text, range: range).compactMap { match in
            guard let tag = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let kind = Kind(rawValue: tag),
                  let attributeText = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                  let body = Range(match.range(at: 3), in: text).map({ String(text[$0]) }) else { return nil }
            var attributes: [String: String] = [:]
            let all = NSRange(attributeText.startIndex..<attributeText.endIndex, in: attributeText)
            for pair in attribute.matches(in: attributeText, range: all) {
                guard let key = Range(pair.range(at: 1), in: attributeText),
                      let value = Range(pair.range(at: 2), in: attributeText) else { continue }
                attributes[String(attributeText[key])] = String(attributeText[value])
            }
            return AgentEnvelope(kind: kind, attributes: attributes, body: body)
        }
    }

    // The newlines Claude Code puts after the opening tag and before the closing one are
    // not the body's.
    private static let envelope = try! NSRegularExpression(
        pattern: #"<(cross-session-message|teammate-message|agent-message)((?:\s+[A-Za-z_][A-Za-z0-9_-]*="[^"]*")*)\s*>\n?(.*?)\n?</\1>"#,
        options: [.dotMatchesLineSeparators])
    private static let attribute = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_-]*)="([^"]*)""#)
}
