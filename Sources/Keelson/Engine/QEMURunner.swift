import Foundation

/// Locates a QEMU install (Homebrew by default) plus its UEFI firmware and the optional swtpm TPM emulator.
enum QEMUToolchain {
    static let overrideKey = "KeelsonQEMUPath"

    struct Paths {
        var qemu: String
        var firmwareCode: String
        var firmwareVarsTemplate: String
        var swtpm: String?
    }

    static func find() -> Paths? {
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: overrideKey), !custom.isEmpty { candidates.append(custom) }
        candidates += ["/opt/homebrew/bin/qemu-system-aarch64", "/usr/local/bin/qemu-system-aarch64",
                       "/opt/local/bin/qemu-system-aarch64"]
        let fm = FileManager.default
        for bin in candidates where fm.isExecutableFile(atPath: bin) {
            let binURL = URL(fileURLWithPath: bin)
            let shareDirs = [binURL, binURL.resolvingSymlinksInPath()].map {
                $0.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/qemu")
            }
            for share in shareDirs {
                let code = share.appendingPathComponent("edk2-aarch64-code.fd").path
                let vars = share.appendingPathComponent("edk2-arm-vars.fd").path
                if fm.fileExists(atPath: code) && fm.fileExists(atPath: vars) {
                    let swtpm = [binURL.deletingLastPathComponent().appendingPathComponent("swtpm").path,
                                 "/opt/homebrew/bin/swtpm", "/usr/local/bin/swtpm"].first { fm.isExecutableFile(atPath: $0) }
                    return Paths(qemu: bin, firmwareCode: code, firmwareVarsTemplate: vars, swtpm: swtpm)
                }
            }
        }
        return nil
    }

    static let installHint = "brew install qemu swtpm"
}

/// Runs a VM as a QEMU child process accelerated by Apple's Hypervisor.framework (HVF).
/// This is the Windows path: it provides a TPM 2.0, NVMe storage and a UEFI framebuffer,
/// which Windows 11 needs and Apple's Virtualization.framework does not offer.
@MainActor
final class QEMURunner: VMRunner {
    var onExit: ((String?) -> Void)?

    private let config: VMConfig
    private let bundle: VMBundle
    private let rawFD: Int32?
    private let tools: QEMUToolchain.Paths
    private let qmpPath: String
    private let tpmSocket: String
    private var pid: pid_t = 0
    private var tpmPID: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var stopping = false

    init(config: VMConfig, bundle: VMBundle, rawFD: Int32?) throws {
        guard let tools = QEMUToolchain.find() else {
            throw KeelsonError("QEMU isn't installed. Windows VMs need it. Install with: \(QEMUToolchain.installHint)")
        }
        self.config = config
        self.bundle = bundle
        self.rawFD = rawFD
        self.tools = tools
        // Unix socket paths are limited to 104 bytes, so keep them in the temp dir, not the bundle.
        let short = config.id.uuidString.prefix(8)
        qmpPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("keelson-\(short).qmp")
        tpmSocket = (NSTemporaryDirectory() as NSString).appendingPathComponent("keelson-\(short).tpm")
    }

    func start() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: bundle.qemuEFIVarsURL.path) {
            try fm.copyItem(atPath: tools.firmwareVarsTemplate, toPath: bundle.qemuEFIVarsURL.path)
        }
        try? fm.removeItem(atPath: qmpPath)

        if config.guest == .windows, let swtpm = tools.swtpm {
            try fm.createDirectory(at: bundle.tpmDirURL, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: tpmSocket)
            tpmPID = try Spawner.spawn(swtpm, ["socket", "--tpm2",
                                               "--tpmstate", "dir=\(bundle.tpmDirURL.path)",
                                               "--ctrl", "type=unixio,path=\(tpmSocket)",
                                               "--terminate"], logURL: bundle.logURL)
            for _ in 0..<50 where !fm.fileExists(atPath: tpmSocket) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard fm.fileExists(atPath: tpmSocket) else { throw KeelsonError("The TPM emulator (swtpm) didn't start. See keelson.log in the VM folder.") }
        }

        let args = try arguments()
        bundle.log("Starting QEMU: \(tools.qemu) \(args.joined(separator: " "))")
        pid = try Spawner.spawn(tools.qemu, args, logURL: bundle.logURL,
                                passFD: rawFD.map { (fd: $0, as: 3) })

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            self.exitSource?.cancel()
            self.cleanup()
            let code = (status >> 8) & 0xff
            let clean = self.stopping || code == 0
            self.onExit?(clean ? nil : "QEMU exited with code \(code). See keelson.log in the VM folder.")
        }
        source.resume()
        exitSource = source

        // QEMU exits within a second if the arguments are bad; surface that as a start failure.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        if kill(pid, 0) != 0 {
            throw KeelsonError("QEMU failed to start. Last log lines:\n" + tailOfLog())
        }
    }

    func requestStop() async throws {
        stopping = true
        try await QMP.execute(qmpPath, "system_powerdown")
    }

    func forceStop() async throws {
        stopping = true
        if (try? await QMP.execute(qmpPath, "quit")) == nil, pid > 0 { kill(pid, SIGKILL) }
    }

    func pause() async throws { try await QMP.execute(qmpPath, "stop") }
    func resume() async throws { try await QMP.execute(qmpPath, "cont") }

    private func cleanup() {
        if tpmPID > 0 { kill(tpmPID, SIGTERM); var s: Int32 = 0; waitpid(tpmPID, &s, 0); tpmPID = 0 }
        try? FileManager.default.removeItem(atPath: qmpPath)
        try? FileManager.default.removeItem(atPath: tpmSocket)
    }

    private func tailOfLog() -> String {
        guard let text = try? String(contentsOf: bundle.logURL, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n").suffix(8).joined(separator: "\n")
    }

    func arguments() throws -> [String] {
        let windows = config.guest == .windows
        var a: [String] = [
            "-name", config.name,
            "-machine", "virt,highmem=on",
            "-accel", "hvf",
            "-cpu", "host",
            "-smp", String(config.cpuCount),
            "-m", String(config.memoryMB),
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(tools.firmwareCode)",
            "-drive", "if=pflash,format=raw,unit=1,file=\(bundle.qemuEFIVarsURL.path)",
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-kbd,bus=xhci.0",
            "-device", "usb-tablet,bus=xhci.0",
            "-display", "cocoa,zoom-to-fit=on",
            "-qmp", "unix:\(qmpPath),server=on,wait=off",
            "-audiodev", "coreaudio,id=snd0",
            "-device", "usb-audio,audiodev=snd0,bus=xhci.0",
            "-netdev", "user,id=net0",
            "-device", "virtio-net-pci,netdev=net0,mac=\(config.macAddress)",
        ]

        // Display: ramfb is a plain UEFI framebuffer every OS can drive with no extra drivers.
        a += windows ? ["-device", "ramfb"] : ["-device", "virtio-gpu-pci"]
        if windows { a += ["-rtc", "base=localtime"] }

        // Main disk
        let blockDevice = windows ? "nvme,drive=hd0,serial=KEELSON0001" : "virtio-blk-pci,drive=hd0"
        if rawFD != nil {
            a += ["-add-fd", "fd=3,set=3,opaque=keelson-disk",
                  "-drive", "if=none,id=hd0,format=raw,file.driver=host_device,file.filename=/dev/fdset/3,file.locking=off,cache=writeback"]
        } else if let url = bundle.diskURL(for: config) {
            a += ["-drive", "if=none,id=hd0,format=raw,discard=unmap,detect-zeroes=unmap,file=\(url.path)"]
        } else {
            throw KeelsonError("This VM has no disk configured.")
        }
        a += ["-device", blockDevice]

        // Installer and driver ISOs as USB drives (Windows Setup reads these without extra drivers).
        for (index, iso) in [config.installerISO, config.driversISO].compactMap({ $0 }).enumerated() {
            guard FileManager.default.fileExists(atPath: iso) else { throw KeelsonError("Installer image not found: \(iso)") }
            a += ["-drive", "if=none,id=cd\(index),media=cdrom,readonly=on,file=\(iso)",
                  "-device", "usb-storage,drive=cd\(index),removable=on,bus=xhci.0"]
        }

        if windows && tools.swtpm != nil {
            a += ["-chardev", "socket,id=chrtpm,path=\(tpmSocket)",
                  "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                  "-device", "tpm-tis-device,tpmdev=tpm0"]
        }

        // Shared folders: QEMU's built-in SMB server isn't on macOS builds, so use 9p for Linux.
        if !windows {
            for (i, folder) in config.sharedFolders.enumerated() {
                a += ["-virtfs", "local,path=\(folder.path),mount_tag=keelson\(i),security_model=mapped-xattr\(folder.readOnly ? ",readonly=on" : "")"]
            }
        }
        return a
    }
}

/// Minimal QEMU Machine Protocol client for power button, pause and resume.
enum QMP {
    static func execute(_ socketPath: String, _ command: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try send(socketPath, command)
        }.value
    }

    private static func send(_ path: String, _ command: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KeelsonError("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw KeelsonError("Socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { throw KeelsonError("The VM isn't responding (QMP connect failed).") }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        _ = readLine(fd)                          // greeting
        write(fd, #"{"execute":"qmp_capabilities"}"#)
        _ = readLine(fd)
        write(fd, #"{"execute":"\#(command)"}"#)
        _ = readLine(fd)
    }

    private static func write(_ fd: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private static func readLine(_ fd: Int32) -> String {
        var out: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
