// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation

/// `open Brow.app --args -petPerfLog YES`: once a minute, to `BrowLog.pet`, the frames drawn in each
/// frame class, the main thread's time per frame (the layer's body with its pose, and the canvas drawing
/// it), and the process CPU over the minute. Nothing here exists unless it was asked for.
///
///     log stream --predicate 'subsystem == "dev.artemefimov.brow" AND category == "pet"'
///
/// Fed from the main thread only (the layer's `TimelineView` and its `Canvas`), so it needs no lock.
final class PetPerfLog: @unchecked Sendable {
    private var frames: [PetFrameClass: Int] = [:]
    private var bodies: [Double] = []
    private var draws: [Double] = []
    private var timer: Timer?
    private var since = Date()
    private var cpuSince = PetPerfLog.processCPU()

    func start() {
        guard timer == nil else { return }
        since = Date()
        cpuSince = Self.processCPU()
        let timer = Timer(timeInterval: PetTuning.Budget.logEvery, repeats: true) { [weak self] _ in self?.flush() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One frame of the layer: its class and how long its body took, the pose included.
    func frame(_ frameClass: PetFrameClass, body: Duration) {
        frames[frameClass, default: 0] += 1
        bodies.append(Self.seconds(body))
    }

    /// How long the canvas took to draw one frame.
    func draw(_ duration: Duration) {
        draws.append(Self.seconds(duration))
    }

    private func flush() {
        let now = Date()
        let cpu = Self.processCPU()
        let wall = max(now.timeIntervalSince(since), 1)
        let percent = 100 * (cpu - cpuSince) / wall
        let counts = PetFrameClass.allCases.map { "\($0) \(frames[$0, default: 0])" }.joined(separator: ", ")
        let line = String(format: "frames %@; body mean %.3f ms p95 %.3f ms; draw mean %.3f ms p95 %.3f ms; cpu %.2f %% of a core",
                          counts, 1000 * Self.mean(bodies), 1000 * Self.p95(bodies), 1000 * Self.mean(draws),
                          1000 * Self.p95(draws), percent)
        BrowLog.pet.info("perf: \(line, privacy: .public)")
        frames = [:]
        bodies = []
        draws = []
        since = now
        cpuSince = cpu
    }

    /// User plus system CPU time of the whole process, in seconds (`getrusage`).
    static func processCPU() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func p95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
}
