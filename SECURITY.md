# Security policy

Brow reads Claude Code's sign-in tokens from the macOS Keychain, so a flaw in it could put someone's Claude account at risk. If you find one, please report it privately.

## Supported versions

Security fixes go into the latest release.

| Version | Supported |
|---|---|
| 0.2.x | Yes |
| < 0.2 | No |

## Reporting a vulnerability

**Please do not report it in a public issue, discussion or pull request.**

Use GitHub's private vulnerability reporting: **[Report a vulnerability](https://github.com/efim0v/brow/security/advisories/new)**. The report stays private between you and the maintainer. If you cannot use GitHub, email artem.efimov.k@gmail.com instead.

Please include:

- the Brow, macOS and Claude Code versions;
- what an attacker can do, and what they need first: a crafted link, a file on disk, another app on the Mac;
- steps to reproduce it, or a proof of concept.

## Scope

Brow uses each account's token only to call Anthropic's usage and profile endpoints, and never writes it to disk or logs it; see [What Brow does on your machine](README.md#what-brow-does-on-your-machine). Anything in this repository, or in the `Brow.app` built from it, that breaks this is in scope. For example:

- a token, or the contents of a Claude Code Keychain item or `.credentials.json` file, reaching a log, a file, another process's arguments or environment, or any host other than `api.anthropic.com`;
- a crafted URL, folder name or path that makes the browser router, the Terminal sign-in command or a `claude` run do something else;
- one account's sign-in landing in another account's browser profile.

The account, credential and usage code Brow shares with Grove lives in `GroveCore`, in the [grove repository](https://github.com/efim0v/grove). If you are not sure which repository a problem belongs to, report it here.

Out of scope:

- vulnerabilities in Claude Code or Anthropic's services: report them to Anthropic, as [Claude Code's security policy](https://github.com/anthropics/claude-code/security/policy) describes;
- vulnerabilities in macOS, Terminal or the browsers Brow opens: report them to their vendors;
- the release build being signed ad hoc and not notarized, and Keychain access having to be granted again after an update: both are known and described under [Install](README.md#install);
- attacks that need someone who can already run programs as your macOS user.

## What to expect

Brow is maintained by one person in their spare time, so there is no guaranteed response time. The aim is to acknowledge a report within a week, keep you posted while a fix is made, ship it in a new release, and then publish a security advisory that credits you, unless you would rather not be named.
