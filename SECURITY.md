# Security policy

Brow handles things worth protecting. It reads Claude Code's sign-in tokens from the macOS Keychain, so a flaw in it could put someone's Claude account at risk. With Workspaces on, it also edits Claude Code's configuration, links and copies session transcripts between accounts, and runs git, Claude Code, cmux and your own hook commands. If you find a flaw in any of it, please report it privately.

## Supported versions

Security fixes go into the latest release.

| Version | Supported |
|---|---|
| 0.4.x | Yes |
| < 0.4 | No |

Grove, whose engine is part of Brow from 0.4.0, is no longer developed: report problems in Grove 0.2.x here, against the latest Brow.

## Reporting a vulnerability

**Please do not report it in a public issue, discussion or pull request.**

Use GitHub's private vulnerability reporting: **[Report a vulnerability](https://github.com/efim0v/brow/security/advisories/new)**. The report stays private between you and the maintainer. If you cannot use GitHub, email a.efimov@mizzle.studio instead.

Please include:

- the Brow, macOS and Claude Code versions;
- what an attacker can do, and what they need first: a crafted link, a repository or branch name, a file planted in an account folder, another app or user on the Mac;
- steps to reproduce it, or a proof of concept, and whether the problem is in the notch, Workspaces or the `brow` command-line tool.

## Scope

The code in this repository and the `Brow.app` and `brow` built from it. [What Brow does on your machine](README.md#what-brow-does-on-your-machine) lists the promises; anything that breaks one is in scope. In particular:

- **Tokens.** Brow uses each account's token only to call Anthropic's usage and profile endpoints, and never writes it to disk or logs it. A token, or the contents of a Claude Code Keychain item or `.credentials.json` file, reaching a log, a file, another process's arguments or environment, or any host other than `api.anthropic.com` is a vulnerability.
- **Sign-in.** A crafted URL, folder name or path that makes the browser router, the Terminal sign-in command or a `claude` run do something else; one account's sign-in landing in another account's browser profile.
- **Edits to Claude Code's files.** Before Brow starts Claude Code in an account folder other than `~/.claude` (a sign-in, or a session Workspaces starts), it marks the folder onboarded in its `.claude.json`. With an account's status-line capture on, Brow points `statusLine.command` in its `settings.json` at a wrapper in `~/Library/Application Support/Grove/bin`, which saves what Claude Code hands the status line under `<account>/grove/usage/`. **Migrate to…** merges the target account's `.claude.json`, `settings.json` and plugin registries. While Workspaces is off, none of this happens beyond the onboarding mark of a sign-in, and an account's `settings.json` is never touched while its capture is off. A status line captured earlier keeps running the wrapper under Claude Code until its capture is turned off, which Settings → Accounts offers whether Workspaces is on or off.
- **Session data.** Sharing an account turns its `file-history`, `tasks` and `session-env` folders, and `projects/<workspace>`, into symbolic links into `~/.claude`. The transcript safety net keeps hard links to transcripts under `~/.claude/grove/transcripts/`; it must never keep one past the retention Claude Code's settings set, nor put one back unless the user presses Restore. Migration copies a session from one account folder to another.
- **Commands Brow runs.** git, `claude`, the cmux command-line tool, AppleScript for cmux and Terminal, and the post-create hooks set for a project, with paths, branch names and workspace names among their arguments. A session may start with `--dangerously-skip-permissions` only when the launch sheet or the project asks for it. Brow reads cmux's socket password from `~/.config/cmux/cmux.json` and passes it on to cmux only.

Examples of what to report:

- a repository, branch or workspace name that makes Brow run a command or write outside the workspace;
- Brow following a symbolic link out of an account folder and changing or deleting files there;
- another user on the Mac being able to read your sessions through a file or folder Brow created;
- a transcript Claude Code's retention removed coming back.

Out of scope:

- vulnerabilities in Claude Code or Anthropic's services: report them to Anthropic, as [Claude Code's security policy](https://github.com/anthropics/claude-code/security/policy) describes;
- vulnerabilities in macOS, Terminal, cmux, git or the browsers Brow opens: report them to their vendors;
- the release build being signed ad hoc and not notarized, and Keychain access having to be granted again after an update: both are known and described under [Install](README.md#install);
- attacks that need someone who can already run programs as your macOS user;
- bugs that lose or damage data with no attacker involved: please report those as regular issues.

## What to expect

Brow is maintained by one person in their spare time, so there is no guaranteed response time. The aim is to acknowledge a report within a week, keep you posted while a fix is made, ship it in a new release, and then publish a security advisory that credits you, unless you would rather not be named.
