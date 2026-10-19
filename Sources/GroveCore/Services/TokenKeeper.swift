// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import os

public enum TokenRefreshOutcome: Sendable, Equatable {
    /// More than `TokenKeeper.threshold` of life remained; nothing was run.
    case fresh
    /// An attempt ran less than the current retry interval ago; nothing was run.
    case skippedRateLimited
    /// The network is down. Nothing was run and nothing was recorded: the CLI could not
    /// have refreshed anything, so this must not cost the account its one attempt.
    case skippedOffline
    /// The CLI could not run at all — the spawn failed, the watchdog fired, or it exited
    /// 127. No evidence about the token, so the floor is not consumed, the breaker does
    /// not count it, and `-p` is not tried.
    case couldNotAttempt(String)
    case refreshedByDoctor
    case refreshedByPrompt
    case failed(String)
    /// The account's login is dead: the CLI said so (`signInLine`), or attempts in a
    /// row stopped helping (`promptGiveUpAfter`). Nothing the keeper can run
    /// fixes that; the user has to sign in again. The verdict stands for the token it was
    /// reached on, until that token is replaced or a refresh lands, and the keeper repeats
    /// it without running anything while its attempt floor holds.
    case signInRequired(String)
}

/// Keeps an idle account's OAuth access token alive by running the REAL Claude
/// Code CLI in that account's config dir — never by touching the refresh token
/// ourselves (the legal page forbids third parties from handling Claude.ai
/// credentials; the unmodified CLI is the sanctioned path).
///
/// Verified on Claude Code 2.1.273: `claude doctor` refreshes the Keychain token
/// with NO model call, so the account's 5-hour window stays unstarted — once the
/// token is inside the CLI's own refresh window (see `threshold`). That is
/// an undocumented side effect, so a `claude -p` fallback (which does spend a
/// sliver of limit and starts the window) exists behind a user setting.
///
/// Success is judged by the ONLY thing that matters: did `expiresAt` move
/// forward. Exit codes are not trusted as success — but they ARE reported, and a
/// `claude` that never ran at all (exit 127, a failed spawn, a fired watchdog) is
/// `.couldNotAttempt`: it says so instead of hiding behind "neither … refreshed
/// the token", and it is charged neither the attempt floor nor the breaker.
public actor TokenKeeper {
    /// Claude Code renews a token only inside the token's last five minutes: every
    /// refresh it makes, short of answering a 401, first asks `now + 5 min >= expiresAt`
    /// (read out of 2.1.290–2.1.302). A `doctor` started earlier changes nothing.
    public static let cliRefreshWindow: TimeInterval = 5 * 60
    /// The keeper acts only inside the CLI's window, with half a minute to spare for the
    /// CLI's own start-up. At 30 min, as it was, the first `doctor` of every token did
    /// nothing, counted as a failure, and the `-p` after it spent limit and started the
    /// account's 5-hour window for nothing; only a later attempt, at or past the expiry,
    /// refreshed anything.
    public static let threshold: TimeInterval = cliRefreshWindow - 30
    /// Floor between two attempts for one account — the spec's "one token-refresh
    /// attempt per account per 30 min". Consecutive ineffective attempts double it.
    public static let attemptInterval: TimeInterval = 30 * 60
    /// Ceiling for that doubling. Without it a permanently dead sign-in is retried
    /// 48 times a day forever.
    public static let maxAttemptInterval: TimeInterval = 12 * 3600
    /// After this many consecutive ineffective attempts the `-p` leg is dropped for
    /// good: `doctor` is free, `-p` spends the account's limit and starts its
    /// 5-hour window, and by now we know it does not help. The next ineffective
    /// attempt is the keeper's word that the login needs a new sign-in.
    public static let promptGiveUpAfter = 3
    /// Quiet period after a CLI that could not run at all. The attempt floor is
    /// deliberately NOT consumed by `.couldNotAttempt` (the spec: no evidence, no
    /// charge) — but "not charged" turned into "not bounded by anything": a wrong
    /// "Path to claude" spawned a process per account per poll, and a `claude doctor`
    /// that hangs means a 90 s watchdog kill re-spawned every 60 s, forever, in an app
    /// that runs for weeks. This gate is separate from the floor and from the breaker:
    /// it holds neither, counts nothing, and hands back the SAME `.couldNotAttempt`
    /// reason, so the account row's text does not change while it is in force.
    public static let couldNotAttemptInterval: TimeInterval = 300
    public static let doctorTimeout: TimeInterval = 90
    public static let promptTimeout: TimeInterval = 120
    /// What `doctor` and `-p` get between SIGTERM and SIGKILL when they run past their
    /// timeout. On its way out Claude Code waits up to 2 s for a token refresh in flight
    /// to land and be saved (read out of 2.1.290–2.1.302), and the refresh token rotates
    /// with every refresh: a SIGKILL inside that wait, as the runner's default half
    /// second allowed, could throw away the one refresh token that still works.
    public static let killGrace: TimeInterval = 5

    private static let log = Logger(subsystem: "dev.artemefimov.brow", category: "TokenKeeper")

    /// One account's attempt bookkeeping, persisted so relaunching (or launch-at-login)
    /// does not hand a dead account a fresh `doctor` + `-p` every time.
    struct Attempt: Codable, Sendable, Equatable {
        var at: Date
        var failures: Int
        /// This attempt was forced by a rejected token (`authRejected: true`). It is what
        /// makes that bypass happen ONCE: the next rejection sees it and obeys the floor
        /// like anyone else, so a permanently rejected account is not handed a `doctor`
        /// on every cycle. Persisted with the rest for the same reason the rest is — a
        /// relaunch must not reopen the bypass.
        var forced: Bool
        /// The CLI found this account's login dead (`.signInRequired`), about the token
        /// that expires at `expiresAt`. Persisted with the rest, so a relaunch does not
        /// take the sign-in key off an account that still needs it.
        var signedOut: SignedOut?

        struct SignedOut: Codable, Sendable, Equatable {
            var reason: String
            var expiresAt: Date
        }

        init(at: Date, failures: Int, forced: Bool = false, signedOut: SignedOut? = nil) {
            self.at = at
            self.failures = failures
            self.forced = forced
            self.signedOut = signedOut
        }

        /// Hand-written because the synthesised decoder throws `keyNotFound` on a
        /// `token-attempts.json` written before `forced` (or `signedOut`) existed — which
        /// would discard every account's gate on the first launch after an update.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            at = try container.decode(Date.self, forKey: .at)
            failures = try container.decode(Int.self, forKey: .failures)
            forced = try container.decodeIfPresent(Bool.self, forKey: .forced) ?? false
            signedOut = try container.decodeIfPresent(SignedOut.self, forKey: .signedOut)
        }
    }

    private let runner: CommandRunning
    private let credentials: CredentialsReading
    /// Read through a closure, not captured once: Settings › General can correct a
    /// wrong "Path to claude" at any time and the next cycle must use the new one.
    private let claudePath: @Sendable () -> String
    private let allowPromptFallback: @Sendable () -> Bool
    /// Network reachability, fed by the controller from `NWPathMonitor`. Read per call
    /// for the same reason `claudePath` is: the answer changes while the app runs.
    private let isOnline: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    /// nil → attempts live in memory only (tests, and any caller that wants no file).
    private let stateDirectory: String?
    private var attempts: [String: Attempt] = [:]
    /// When the CLI last failed to run at all for a dir, and why. In memory only: the
    /// attempt record on disk is what must survive a relaunch, and this one is a
    /// spawn-rate gate, not evidence about the account.
    private var couldNotAttemptAt: [String: (at: Date, reason: String)] = [:]
    private var loadedState = false

    public init(runner: CommandRunning, credentials: CredentialsReading,
                claudePath: @escaping @Sendable () -> String,
                allowPromptFallback: @escaping @Sendable () -> Bool,
                isOnline: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                stateDirectory: String? = nil) {
        self.runner = runner
        self.credentials = credentials
        self.claudePath = claudePath
        self.allowPromptFallback = allowPromptFallback
        self.isOnline = isOnline
        self.now = now
        self.stateDirectory = stateDirectory
    }

    /// Fixed-path convenience (tests and any caller whose path cannot change).
    public init(runner: CommandRunning, credentials: CredentialsReading, claudePath: String,
                allowPromptFallback: @escaping @Sendable () -> Bool,
                isOnline: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                stateDirectory: String? = nil) {
        self.init(runner: runner, credentials: credentials, claudePath: { claudePath },
                  allowPromptFallback: allowPromptFallback, isOnline: isOnline, now: now,
                  stateDirectory: stateDirectory)
    }

    /// - Parameter authRejected: the server answered 401/403 for this account. That is
    ///   the authoritative word on the token and it outranks `expiresAt`, so the "still
    ///   fresh" shortcut is skipped for as long as the rejection stands; the attempt
    ///   floor is bypassed ONCE (see `Attempt.forced`). For a token past its own expiry it
    ///   buys that one attempt and nothing else: such a token is renewed like a due one.
    public func ensureFresh(configDir: String, authRejected: Bool = false) async -> TokenRefreshOutcome {
        loadStateIfNeeded()
        let at = now()
        // First, before the Keychain and before any bookkeeping: with no network the CLI
        // cannot refresh anything, so this cycle is not evidence about the account and
        // must leave no trace — otherwise a flight's worth of offline cycles walks the
        // breaker up to its 12 h gap for an account that was never broken.
        guard isOnline() else {
            Self.log.info("token refresh skipped for \(configDir, privacy: .public): offline")
            return .skippedOffline
        }
        guard let before = credentials.token(configDir: configDir)?.expiresAt else {
            return fail("no readable token", configDir: configDir)
        }
        // A login the CLI found dead stays dead for the token it was found on: a new
        // sign-in, or a session that did manage to refresh, brings a different one.
        let signedOut = attempts[configDir]?.signedOut.flatMap { $0.expiresAt == before ? $0.reason : nil }
        if !authRejected, before.timeIntervalSince(at) > Self.threshold {
            if let signedOut { return .signInRequired(signedOut) }
            return observedFresh(configDir: configDir)
        }
        // The spawn-rate gate. Checked AFTER the "still fresh" shortcut, so a CLI that
        // cannot run costs nothing at all for an account that does not need it, and
        // BEFORE the floor, because the floor is the thing a could-not-attempt leaves
        // untouched by design.
        if let last = couldNotAttemptAt[configDir],
           at.timeIntervalSince(last.at) < Self.couldNotAttemptInterval {
            Self.log.info("""
                token refresh not attempted for \(configDir, privacy: .public): \
                still inside the \(Self.couldNotAttemptInterval, privacy: .public) s quiet period \
                after "\(last.reason, privacy: .public)"
                """)
            return .couldNotAttempt(last.reason)
        }
        let failures = attempts[configDir]?.failures ?? 0
        let forcesThroughTheFloor = authRejected && !(attempts[configDir]?.forced ?? false)
        if !forcesThroughTheFloor, let last = attempts[configDir]?.at,
           at.timeIntervalSince(last) < Self.retryInterval(failures: failures) {
            return signedOut.map(TokenRefreshOutcome.signInRequired) ?? .skippedRateLimited
        }
        // Recorded BEFORE the attempt, so a crash mid-`doctor` still leaves a floor;
        // `previous` is what the could-not-attempt paths roll back to.
        let previous = record(configDir: configDir, at: at, failures: failures, forced: authRejected)

        var details: [String] = []
        do {
            let doctor = Self.invocation(claude: claudePath(), args: ["doctor"], configDir: configDir)
            let result = try await runner.run(doctor.executable, doctor.args, cwd: nil, env: doctor.env,
                                              timeout: Self.doctorTimeout, killGrace: Self.killGrace)
            // 127 is the shell's "command not found": a wrong "Path to claude", or a GUI
            // app's PATH without the CLI on it. The binary never ran.
            if result.exitCode == 127 {
                return couldNotAttempt(Self.detail("doctor", result) ?? "doctor exit 127",
                                       configDir: configDir, restoring: previous)
            }
            switch reread(after: before, configDir: configDir) {
            case .advanced:   return succeed(.refreshedByDoctor, configDir: configDir)
            case .unreadable: return fail("token became unreadable after claude doctor", configDir: configDir, counts: true)
            case .unchanged:
                // Not worth a `-p`: no run of the CLI can renew a login it says is dead.
                if let line = Self.signInLine(result) {
                    return signInRequired("doctor: \(line)", configDir: configDir, token: before)
                }
                if let d = Self.detail("doctor", result) { details.append(d) }
            }
        } catch let error as GroveError where Self.cliNeverRan(error) {
            // A spawn failure or a fired watchdog says nothing about the token — and a
            // timeout is far likelier to be the network than the token, so `-p` (which
            // spends the account's limit and starts its 5-hour window) is not tried.
            return couldNotAttempt(String(describing: error), configDir: configDir, restoring: previous)
        } catch {
            return fail("claude doctor failed: \(error)", configDir: configDir, counts: true)
        }

        // A rejection says more than the token's own clock only about a token with life
        // left. One past its expiry is refused for that alone — the store never sends it,
        // and flags it as rejected only so that the floor lets one attempt through — and
        // it is renewed like any token that is due.
        let refusedWithLifeLeft = authRejected && before > at
        // Circuit breaker. Three ineffective rounds in a row are enough to conclude that
        // nothing Brow runs renews this login, with the `-p` leg or without it. Not for a
        // token refused with life left: `doctor` does not try to renew a token outside the
        // CLI's own window, so its failing says nothing about the login.
        guard failures < Self.promptGiveUpAfter || refusedWithLifeLeft else {
            return signInRequired("\(failures) attempts in a row did not renew the token"
                                    .appending(Self.suffix(details)), configDir: configDir, token: before)
        }
        // `-p` spends the account's limit and starts its 5-hour window, so it runs only
        // when `doctor` failing is real evidence about the TOKEN. After a 401/403 for a
        // token with life left it is not: the server rejected the bearer, which a token
        // with hours of nominal life left can do for reasons no CLI can fix (a revoked
        // session, an org change), and the account is then charged a fresh 5-hour window
        // on every rejection episode. Same reasoning the spec already applies to a
        // timed-out `doctor`.
        guard allowPromptFallback(), !refusedWithLifeLeft else {
            return fail("claude doctor did not refresh the token".appending(Self.suffix(details)),
                        configDir: configDir, counts: true)
        }
        do {
            let prompt = Self.invocation(claude: claudePath(), args: ["-p", ".", "--model", "haiku", "--max-turns", "1"],
                                         configDir: configDir)
            let result = try await runner.run(prompt.executable, prompt.args, cwd: nil, env: prompt.env,
                                              timeout: Self.promptTimeout, killGrace: Self.killGrace)
            switch reread(after: before, configDir: configDir) {
            case .advanced:   return succeed(.refreshedByPrompt, configDir: configDir)
            case .unreadable: return fail("token became unreadable after claude -p", configDir: configDir, counts: true)
            case .unchanged:
                if let line = Self.signInLine(result) {
                    return signInRequired("-p: \(line)", configDir: configDir, token: before)
                }
                if let d = Self.detail("-p", result) { details.append(d) }
            }
        } catch {
            return fail("claude -p failed: \(error)", configDir: configDir, counts: true)
        }
        return fail("neither claude doctor nor claude -p refreshed the token".appending(Self.suffix(details)),
                    configDir: configDir, counts: true)
    }

    /// How the CLI is run FOR `configDir`. An account folder is selected with
    /// `CLAUDE_CONFIG_DIR`. The default dir is selected by the variable's ABSENCE — set
    /// to `~/.claude` the CLI reads a different Keychain item (see `isDefaultClaudeDir`),
    /// finds no login there, and `doctor` can never refresh the token Brow is reading.
    /// `env -u` rather than an empty environment entry: the runner merges into this
    /// process's environment, which may carry the variable itself.
    static func invocation(claude: String, args: [String], configDir: String)
        -> (executable: String, args: [String], env: [String: String]?) {
        if isDefaultClaudeDir(configDir) {
            return ("/usr/bin/env", ["-u", "CLAUDE_CONFIG_DIR", claude] + args, nil)
        }
        return (claude, args, ["CLAUDE_CONFIG_DIR": configDir])
    }

    /// A CLI that never ran: the spawn failed, or the watchdog killed it before it could
    /// say anything. Distinct from `processFailed`, which is a CLI that DID run and
    /// reported something — real evidence about the account, and counted as such.
    private static func cliNeverRan(_ error: GroveError) -> Bool {
        switch error {
        case .timeout, .io: return true
        default: return false
        }
    }

    /// 30 min, doubling with each consecutive ineffective attempt, capped at 12 h.
    static func retryInterval(failures: Int) -> TimeInterval {
        guard failures > 0 else { return attemptInterval }
        return min(attemptInterval * pow(2, Double(failures - 1)), maxAttemptInterval)
    }

    enum Reread: Sendable, Equatable {
        /// The expiry moved forward — the CLI really did refresh the token.
        case advanced
        /// Still the same expiry.
        case unchanged
        /// The token cannot be read at all any more (prompt denied, item gone). NOT
        /// the same as `unchanged`: running `-p` on a token we cannot verify spends
        /// the account's limit and starts its 5-hour window for nothing.
        case unreadable
    }

    /// Drops any cached copy and re-reads.
    private func reread(after before: Date, configDir: String) -> Reread {
        credentials.invalidate(configDir: configDir)
        guard let after = credentials.token(configDir: configDir)?.expiresAt else { return .unreadable }
        return after > before ? .advanced : .unchanged
    }

    /// A CLI result worth reporting: the exit code plus the last stderr line.
    /// Nothing to say when the command exited 0 with an empty stderr.
    static func detail(_ label: String, _ result: ProcessResult) -> String? {
        let stderr = result.stderr.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if result.exitCode == 0 && stderr.isEmpty { return nil }
        return stderr.isEmpty ? "\(label) exit \(result.exitCode)" : "\(label) exit \(result.exitCode): \(stderr)"
    }

    private static func suffix(_ details: [String]) -> String {
        details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
    }

    /// The line in which the CLI says the login itself is dead, from either stream and
    /// without terminal colours: "Not logged in · Please run /login", "OAuth token
    /// revoked · Please run /login", "Login expired · Please run /login" — and, as a run
    /// that is not interactive words them (`claude -p`), "Failed to authenticate: OAuth
    /// session expired and could not be refreshed", "Failed to authenticate: OAuth token
    /// revoked. …" (2.1.290–2.1.303). "Failed to authenticate through the broker" is an
    /// Azure sign-in's log line, not one of these.
    ///
    /// Not "Failed to authenticate. API Error: …", with a full stop: that is how `-p`
    /// reports any 401/403 still standing after its own one forced refresh, and that
    /// refresh also fails when the token endpoint errors or does not answer, or another
    /// process is in the middle of a refresh. Taken for a dead login, it would light the
    /// sign-in key on every account whose token ran out while Anthropic's token endpoint
    /// was down. A refresh token the CLI found dead reads "OAuth session expired …", and
    /// the CLI clears it from the Keychain, which the next scan sees as no token.
    static func signInLine(_ result: ProcessResult) -> String? {
        let colours = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
        for line in (result.stderr + "\n" + result.stdout).split(whereSeparator: \.isNewline) {
            let text = String(line).replacingOccurrences(of: colours, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if text.range(of: "please run /login", options: .caseInsensitive) != nil
                || text.range(of: "failed to authenticate:", options: .caseInsensitive) != nil {
                return String(text.prefix(160))
            }
        }
        return nil
    }

    /// A token with more than `threshold` of life left is proof this account is
    /// healthy again — whoever moved it: a later `doctor`, Claude Code itself running
    /// in that config dir, a fresh sign-in. The breaker has to be reset HERE, because
    /// nothing else on this path ever does: `succeed` runs only when THIS keeper moved
    /// the expiry, and `ensureFresh` returns before it. With the count persisted to
    /// `token-attempts.json` a spell of three failures otherwise survived every
    /// relaunch, permanently disabling the `-p` leg and holding the retry gap at 12 h —
    /// the opposite of the spec's "always current".
    ///
    /// The attempt TIMESTAMP is deliberately kept: the spec's floor is "one
    /// token-refresh attempt per account per 30 min", and a token that was refreshed
    /// out of band is no reason to spawn the CLI sooner than that.
    ///
    /// `forced` is deliberately kept too. Getting here means `expiresAt > threshold` —
    /// which is exactly the signal `authRejected` exists to distrust, because a
    /// server-revoked token still carries hours of nominal life. Re-arming the bypass on
    /// it would hand every subsequent 401 its own `doctor`, forever. Only `succeed`
    /// clears it: there the CLI verifiably MOVED the expiry, which no revoked token can
    /// fake. A `forced` left standing cannot lock out a later genuine 401 either — by
    /// then the recorded attempt is old and the ordinary floor check lets the call
    /// through anyway.
    ///
    /// A dead-login verdict reaching here is about an older token (`ensureFresh` answers
    /// with it while the token is the same), so it goes too.
    private func observedFresh(configDir: String) -> TokenRefreshOutcome {
        if var attempt = attempts[configDir], attempt.failures != 0 || attempt.signedOut != nil {
            attempt.failures = 0
            attempt.signedOut = nil
            attempts[configDir] = attempt
            saveState()
        }
        return .fresh
    }

    private func succeed(_ outcome: TokenRefreshOutcome, configDir: String) -> TokenRefreshOutcome {
        if var attempt = attempts[configDir] {
            attempt.failures = 0
            // A refresh this keeper watched land ends the rejection episode: the NEXT 401
            // is a new one and deserves its own bypass, not the leftovers of this one.
            // This is the ONLY place `forced` is cleared — see `observedFresh` for why a
            // merely plausible `expiresAt` does not qualify.
            attempt.forced = false
            attempt.signedOut = nil
            attempts[configDir] = attempt
            saveState()
        }
        return outcome
    }

    /// The CLI says the login is dead. Counted like any ineffective attempt, and kept with
    /// the expiry of the token it is about, so the account goes on saying so.
    private func signInRequired(_ reason: String, configDir: String, token expiresAt: Date) -> TokenRefreshOutcome {
        Self.log.error("token refresh failed for \(configDir, privacy: .public): sign in again (\(reason, privacy: .public))")
        if var attempt = attempts[configDir] {
            attempt.failures += 1
            attempt.signedOut = Attempt.SignedOut(reason: reason, expiresAt: expiresAt)
            attempts[configDir] = attempt
            saveState()
        }
        return .signInRequired(reason)
    }

    /// Nothing is swallowed: the reason goes to the unified log AND back to the
    /// caller, which puts it in the account row's status slot.
    private func fail(_ reason: String, configDir: String, counts: Bool = false) -> TokenRefreshOutcome {
        Self.log.error("token refresh failed for \(configDir, privacy: .public): \(reason, privacy: .public)")
        if counts, var attempt = attempts[configDir] {
            attempt.failures += 1
            attempts[configDir] = attempt
            saveState()
        }
        return .failed(reason)
    }

    /// Nothing is swallowed here either: the CLI's silence is logged and travels back to
    /// the account row. Nothing is charged for it, though — the attempt record is rolled
    /// back, so the floor and the breaker are exactly where they were.
    private func couldNotAttempt(_ reason: String, configDir: String, restoring previous: Attempt?) -> TokenRefreshOutcome {
        Self.log.error("token refresh not attempted for \(configDir, privacy: .public): \(reason, privacy: .public)")
        unrecord(configDir: configDir, restoring: previous)
        // The floor and the breaker stay exactly where they were; only the spawn rate
        // is bounded. See `couldNotAttemptInterval`.
        couldNotAttemptAt[configDir] = (at: now(), reason: reason)
        return .couldNotAttempt(reason)
    }

    /// Returns what was there before, for `unrecord` to put back.
    private func record(configDir: String, at: Date, failures: Int, forced: Bool) -> Attempt? {
        // An attempt is about to run, so the quiet period (if any) is over. Whatever
        // this attempt turns out to be, the gate is re-armed only by `couldNotAttempt`.
        couldNotAttemptAt.removeValue(forKey: configDir)
        let previous = attempts[configDir]
        // The verdict carries over: only what this attempt finds can change it.
        attempts[configDir] = Attempt(at: at, failures: failures, forced: forced, signedOut: previous?.signedOut)
        saveState()
        return previous
    }

    private func unrecord(configDir: String, restoring previous: Attempt?) {
        if let previous { attempts[configDir] = previous } else { attempts.removeValue(forKey: configDir) }
        saveState()
    }

    // MARK: - persistence

    private var stateFile: String? { stateDirectory.map { $0 + "/token-attempts.json" } }

    private func loadStateIfNeeded() {
        guard !loadedState else { return }
        loadedState = true
        guard let path = stateFile, let data = FileManager.default.contents(atPath: path) else { return }
        do { attempts = try JSONDecoder().decode([String: Attempt].self, from: data) }
        catch { Self.log.error("token attempt state unreadable at \(path, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    private func saveState() {
        guard let directory = stateDirectory, let path = stateFile else { return }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(attempts).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            Self.log.error("token attempt state unwritable at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
