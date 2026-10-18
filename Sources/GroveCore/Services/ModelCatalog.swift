// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// What the model pickers offer (launch sheet, project defaults, account cards).
///
/// Claude Code's aliases come first: `claude --model opus` is always the current Opus,
/// so a picker built from them never goes stale. The pinned ids are for keeping a
/// session on one version; that list ages with every release, which is why any other
/// id can be typed in as well (grove#10).
public enum ModelCatalog {
    /// `claude --model <alias>`: the latest model of each family.
    public static let aliases: [String] = ["opus", "sonnet", "haiku"]

    /// Full ids, for pinning a version.
    public static let knownModels: [String] = [
        "claude-fable-5",
        "claude-haiku-4-5",
        "claude-opus-4-6",
        "claude-opus-4-7",
        "claude-opus-4-8",
        "claude-opus-5-5",
        "claude-sonnet-4-6",
    ]

    /// Whether `model` is one the picker does not list — typed in, or written by an
    /// older or newer build. Such a value is shown as it is, never dropped.
    public static func isCustom(_ model: String) -> Bool {
        !aliases.contains(model) && !knownModels.contains(model)
    }

    /// A typed-in id as the launch will use it: trimmed; nil when empty or when it
    /// could not be a model id at all (whitespace inside, a leading dash that would
    /// read as a flag).
    public static func customID(_ typed: String) -> String? {
        let id = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.hasPrefix("-"),
              id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return id
    }
}
