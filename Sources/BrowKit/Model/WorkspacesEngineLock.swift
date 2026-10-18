// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

/// One Workspaces engine at a time on one Grove config, however many copies of Brow the
/// user runs: the installed app, a second copy somewhere else, the build
/// `Scripts/dev-run.sh` starts. Two engines would race on Grove's `config.json` and run
/// two safety nets and two status-line reconcilers, as Brow and Grove.app would.
///
/// An engine holds an advisory lock (`flock`) on a file beside Grove's config for as long
/// as it runs; a copy of Brow that finds it taken waits, the way it waits for Grove.app.
/// Bundle ids could not tell the copies apart — the dev build runs as a bare executable
/// with no bundle id at all — and the lock needs no such knowledge. The kernel lets go of
/// it when the process holding it exits, crashed or not, so it never outlives its holder.
final class WorkspacesEngineLock {
    let path: String
    private var descriptor: Int32 = -1

    init(path: String) { self.path = path }

    /// The lock of the engine that works on `folders`: beside Grove's `config.json`.
    convenience init(folders: WorkspacesFolders) {
        self.init(path: folders.configFile.deletingLastPathComponent()
            .appendingPathComponent("workspaces.lock").path)
    }

    deinit { release() }

    /// Whether this copy of Brow holds the lock.
    var isHeld: Bool { descriptor >= 0 }

    /// Takes the lock unless another process holds it; true when no one else does. A file
    /// that cannot be opened or locked at all (a folder that cannot be written, a volume
    /// without locks) does not stop Workspaces: the lock keeps a second copy of Brow out,
    /// it is not a condition for running.
    @discardableResult
    func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        let path = self.path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            BrowLog.workspaces.error("workspaces lock not taken, \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { return false }
            BrowLog.workspaces.error("workspaces lock not taken, \(path, privacy: .public): \(String(cString: strerror(error)), privacy: .public)")
            return true
        }
        descriptor = fd
        return true
    }

    /// Lets go of the lock, if this copy holds it.
    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
