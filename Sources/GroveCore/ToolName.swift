// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// The command-line tool's name as it was run: `brow`, or `grove`, the second name it
/// keeps for scripts written for Grove's tool (a symlink next to it in `brow-cli.zip`,
/// never a second binary).
///
/// Usage and error text say the name that was typed, so a script calling `grove` sees
/// exactly the text it always saw; subcommands, flags, JSON and exit codes are the same
/// under both names.
public enum ToolName {
    public static let primary = "brow"
    public static let legacy = "grove"

    /// `argv[0]`'s last component decides: `grove` is `grove`, anything else is `brow`.
    public static func resolve(argv0: String) -> String {
        (argv0 as NSString).lastPathComponent == legacy ? legacy : primary
    }

    /// The tool's help text, for the name it was run as.
    public static func usage(_ name: String) -> String {
        """
        \(name) — git-worktree / Claude Code orchestration

        usage:
          \(name) scan <path> [--json]
          \(name) workspaces <path> [--json]
          \(name) sessions <cwd> [--json]
          \(name) create <path> <name> [--repos a,b] [--branch x] [--from workspace] [--from-branch <repoDir>=<branch>] [--json]
          \(name) graph <repoPath> [--limit N] [--json]
          \(name) doctor [--json]
          \(name) --version

        create flags:
          --from-branch <repoDir>=<branch>   Fork a specific repo from <branch> instead of the default
                                             start point. Repeatable; takes precedence over --from.

        doctor:
          Exits 1 when it can't run git or claude. cmux is optional.
        """
    }
}
