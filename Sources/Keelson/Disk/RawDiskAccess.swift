import Foundation
import DiskArbitration

/// Opens a raw disk device without running Keelson as root.
///
/// macOS ships `/usr/libexec/authopen`, which shows the standard administrator prompt, opens the
/// device itself, and hands the open file descriptor back over a Unix socket (SCM_RIGHTS).
enum RawDiskAccess {
    static func open(devicePath: String) throws -> Int32 {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw KeelsonError("socketpair failed: \(String(cString: strerror(errno)))")
        }
        let ours = fds[0], theirs = fds[1]
        defer { close(ours) }

        let pid: pid_t
        do {
            pid = try Spawner.spawn("/usr/libexec/authopen",
                                    ["-stdoutpipe", "-o", String(O_RDWR), devicePath],
                                    stdoutFD: theirs)
        } catch {
            close(theirs)
            throw error
        }
        close(theirs)

        let received = receiveFD(on: ours)
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        guard let fd = received else {
            throw KeelsonError("Access to \(devicePath) was not granted (the admin prompt was cancelled or failed).")
        }
        return fd
    }

    private static func receiveFD(on socket: Int32) -> Int32? {
        let dataSize = 1024
        let controlSize = 64
        let dataBuf = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 8)
        let controlBuf = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)
        defer { dataBuf.deallocate(); controlBuf.deallocate() }

        while true {
            var iov = iovec(iov_base: dataBuf, iov_len: dataSize)
            var msg = msghdr()
            let n: Int = withUnsafeMutablePointer(to: &iov) { iovPtr in
                msg.msg_iov = iovPtr
                msg.msg_iovlen = 1
                msg.msg_control = controlBuf
                msg.msg_controllen = socklen_t(controlSize)
                return recvmsg(socket, &msg, 0)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            if msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) {
                let header = controlBuf.assumingMemoryBound(to: cmsghdr.self).pointee
                if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                    // Darwin aligns cmsg data to 4 bytes.
                    let offset = (MemoryLayout<cmsghdr>.size + 3) & ~3
                    return controlBuf.load(fromByteOffset: offset, as: Int32.self)
                }
            }
        }
    }
}

/// Refuses macOS auto-mount requests for disks currently attached to a running VM,
/// so Finder never mounts (and writes to) a guest's EFI or data partitions mid-run.
final class MountBlocker {
    static let shared = MountBlocker()
    private let session: DASession?
    private var blocked: Set<String> = []
    private let lock = NSLock()

    private init() {
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            guard let context, let cName = DADiskGetBSDName(disk) else { return nil }
            let me = Unmanaged<MountBlocker>.fromOpaque(context).takeUnretainedValue()
            guard me.isBlocked(String(cString: cName)) else { return nil }
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy),
                                              "This disk is in use by a Keelson virtual machine." as CFString)
            return Unmanaged.passRetained(dissenter)
        }, context)
    }

    func block(_ wholeDisk: String) { lock.lock(); blocked.insert(wholeDisk); lock.unlock() }
    func unblock(_ wholeDisk: String) { lock.lock(); blocked.remove(wholeDisk); lock.unlock() }

    private func isBlocked(_ bsd: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked.contains { bsd == $0 || bsd.hasPrefix($0 + "s") }
    }
}
