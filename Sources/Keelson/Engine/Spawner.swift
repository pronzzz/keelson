import Foundation

/// Thin posix_spawn wrapper. Unlike Foundation's Process it can pass an extra open
/// file descriptor (a raw disk) to the child at a fixed number.
enum Spawner {
    static func spawn(_ path: String,
                      _ args: [String],
                      stdoutFD: Int32? = nil,
                      logURL: URL? = nil,
                      passFD: (fd: Int32, as: Int32)? = nil) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let stdoutFD {
            posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1)
        } else if let logURL {
            posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        if let logURL {
            posix_spawn_file_actions_addopen(&actions, 2, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        if let passFD {
            posix_spawn_file_actions_adddup2(&actions, passFD.fd, passFD.as)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Only the descriptors set up above are inherited by the child.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        guard rc == 0 else {
            throw KeelsonError("Couldn't launch \(path): \(String(cString: strerror(rc)))")
        }
        return pid
    }
}
