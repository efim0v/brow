import Foundation
@testable import GroveCore

/// Scripted CommandRunning double: records every invocation and replays
/// pre-baked ProcessResults in FIFO order. When the script is exhausted it
/// returns an empty success, so accidental extra calls fail assertions
/// (invocation counts / contents), not the whole test run.
/// A settable clock for code that takes `now: @Sendable () -> Date`. A captured `var`
/// is an error in Swift 6 language mode; a box is not.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class MockRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ProcessResult]
    private var recorded: [(executable: String, args: [String], env: [String: String]?)] = []

    init(results: [ProcessResult]) {
        self.script = results
    }

    var invocations: [(executable: String, args: [String], env: [String: String]?)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock {
            recorded.append((executable: executable, args: args, env: env))
            guard !script.isEmpty else {
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            return script.removeFirst()
        }
    }
}
