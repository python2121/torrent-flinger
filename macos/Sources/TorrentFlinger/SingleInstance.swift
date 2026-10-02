import Foundation
import TorrentFlingerCore

/// Ensures only one menubar GUI instance runs at a time.
///
/// macOS only de-dupes `.app` launches that go through LaunchServices. Running
/// the executable inside the bundle directly — or `swift run`ning a dev build
/// while the installed copy is up — bypasses that entirely and produces a
/// *second* status item in the menubar (and a second poller hammering the
/// server).
///
/// So we guard the GUI path ourselves with a POSIX advisory lock (`flock`) on a
/// file in Application Support. The first process to start holds the lock for
/// its lifetime; any later one can't acquire it and bows out. The kernel
/// releases the lock on exit — clean, crashed or killed — so it can't go stale.
enum SingleInstance {
    /// Held for the process lifetime so the lock stays acquired.
    private static var lockFD: Int32 = -1

    private static var lockFileURL: URL? {
        let fm = FileManager.default
        let dir = Config.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock")
    }

    /// True if this process acquired the lock (and may start the menubar),
    /// false if another instance already holds it. If the lock file can't be
    /// opened at all we fail open — never block the app over a filesystem
    /// hiccup.
    static func acquire() -> Bool {
        guard let url = lockFileURL else { return true }

        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        if fd == -1 { return true }

        // LOCK_NB → don't wait; if another instance holds LOCK_EX we get
        // EWOULDBLOCK immediately and exit instead of blocking forever.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd   // keep the fd (and thus the lock) alive
            return true
        }

        close(fd)
        return false
    }
}
