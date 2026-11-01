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
    /// No window or audio; used by --selftest.
    private let headless: Bool
    private let qmpPath: String
    private let tpmSocket: String
    private let tpmPIDFile: String
    private var setupMedia: URL?
    private var pid: pid_t = 0
    private var tpmPID: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var keyTask: Task<Void, Never>?
    private var stopping = false

    init(config: VMConfig, bundle: VMBundle, rawFD: Int32?, headless: Bool = false) throws {
        guard let tools = QEMUToolchain.find() else {
            throw KeelsonError("QEMU isn't installed. Windows VMs need it. Install with: \(QEMUToolchain.installHint)")
        }
        self.config = config
        self.bundle = bundle
        self.rawFD = rawFD
        self.tools = tools
        self.headless = headless
        // Unix socket paths are limited to 104 bytes, so keep them in a short temp dir, not the bundle.
        let short = config.id.uuidString.prefix(8)
        var dir = NSTemporaryDirectory()
        if dir.utf8.count > 70 { dir = "/tmp" }
        qmpPath = (dir as NSString).appendingPathComponent("keelson-\(short).qmp")
        tpmSocket = (dir as NSString).appendingPathComponent("keelson-\(short).tpm")
        tpmPIDFile = (dir as NSString).appendingPathComponent("keelson-\(short).tpm.pid")
    }

    deinit {
        keyTask?.cancel()
    }

    func start() async throws {
        do {
            try await launch()
        } catch {
            // Don't leave swtpm behind: it holds a lock on the TPM state and would block the next start.
            if pid > 0, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            cleanup()
            throw error
        }
    }

    private func launch() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: bundle.qemuEFIVarsURL.path) {
            try fm.copyItem(atPath: tools.firmwareVarsTemplate, toPath: bundle.qemuEFIVarsURL.path)
        }
        try? fm.removeItem(atPath: qmpPath)
        if config.usesWindowsSetupHelpers {
            setupMedia = try WindowsSetupMedia.ensure(in: bundle)
        }

        if config.guest == .windows, let swtpm = tools.swtpm {
            try fm.createDirectory(at: bundle.tpmDirURL, withIntermediateDirectories: true)
            Self.killStaleTPM(pidFile: tpmPIDFile)
            try? fm.removeItem(atPath: tpmSocket)
            tpmPID = try Spawner.spawn(swtpm, ["socket", "--tpm2",
                                               "--tpmstate", "dir=\(bundle.tpmDirURL.path)",
                                               "--ctrl", "type=unixio,path=\(tpmSocket)",
                                               "--pid", "file=\(tpmPIDFile)",
                                               "--terminate"], logURL: bundle.logURL)
            for _ in 0..<50 where !fm.fileExists(atPath: tpmSocket) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard fm.fileExists(atPath: tpmSocket) else { throw KeelsonError("The TPM emulator (swtpm) didn't start. See keelson.log in the VM folder.") }
        }

        let blankDisk = config.guest == .windows && config.installerISO != nil && mainDiskIsBlank()
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
        if kill(pid, 0) != 0 || exitSource?.isCancelled == true {
            throw KeelsonError("QEMU failed to start. Last log lines:\n" + tailOfLog())
        }

        // Windows' installer only boots from the ISO if a key is pressed within a few seconds of
        // "Press any key to boot from CD or DVD", otherwise the VM drops into the UEFI shell.
        // On a blank disk there's nothing else to boot, so press it for the user.
        if blankDisk { pressKeyForInstaller() }
    }

    private func pressKeyForInstaller() {
        let qmp = qmpPath
        let bundle = bundle
        bundle.log("Blank disk with an installer attached: pressing Enter for “Press any key to boot from CD”")
        keyTask = Task.detached(priority: .utility) {
            // Firmware reaches the prompt in about 3–8 s; it waits 5 s. Stop well before Setup's first page.
            for _ in 0..<36 {
                if Task.isCancelled { return }
                try? QMP.sendKey(qmp, "ret")
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    /// True when the main disk has neither an MBR signature nor a GPT header, i.e. no OS installed yet.
    func mainDiskIsBlank() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n: Int
        if let rawFD {
            n = buffer.withUnsafeMutableBytes { pread(rawFD, $0.baseAddress, 4096, 0) }
        } else if let url = bundle.diskURL(for: config), let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 4096)) ?? Data()
            buffer.replaceSubrange(0..<data.count, with: data)
            n = data.count
        } else {
            return false
        }
        guard n >= 520 else { return n >= 0 }
        let mbr = buffer[510] == 0x55 && buffer[511] == 0xAA
        let gpt = Array(buffer[512..<520]) == Array("EFI PART".utf8)
        return !mbr && !gpt
    }

    private static func killStaleTPM(pidFile: String) {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let stale = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), stale > 0 else { return }
        // Only kill it if it's really a leftover swtpm, not an unrelated process that reused the PID.
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(stale, &buffer, UInt32(buffer.count)) > 0,
           String(cString: buffer).hasSuffix("/swtpm") {
            kill(stale, SIGTERM)
            usleep(200_000)
        }
        try? FileManager.default.removeItem(atPath: pidFile)
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
        keyTask?.cancel()
        keyTask = nil
        if tpmPID > 0 { kill(tpmPID, SIGTERM); var s: Int32 = 0; waitpid(tpmPID, &s, 0); tpmPID = 0 }
        try? FileManager.default.removeItem(atPath: qmpPath)
        try? FileManager.default.removeItem(atPath: tpmSocket)
        try? FileManager.default.removeItem(atPath: tpmPIDFile)
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
            "-qmp", "unix:\(qmpPath),server=on,wait=off",
            "-netdev", "user,id=net0",
            "-device", "virtio-net-pci,netdev=net0,mac=\(config.macAddress)",
        ]

        a += headless
            ? ["-display", "none"]
            : ["-display", "cocoa,zoom-to-fit=on",
               "-audiodev", "coreaudio,id=snd0",
               "-device", "usb-audio,audiodev=snd0,bus=xhci.0"]

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
        // Fixed boot order: the installer first (while attached), then the disk.
        a += ["-device", blockDevice + ",bootindex=1"]

        // Installer and driver ISOs as USB drives (Windows Setup reads these without extra drivers).
        var images = [config.installerISO, config.driversISO].compactMap { $0 }
        if let setupMedia { images.append(setupMedia.path) }
        for (index, iso) in images.enumerated() {
            guard FileManager.default.fileExists(atPath: iso) else { throw KeelsonError("Installer image not found: \(iso)") }
            let boot = index == 0 && iso == config.installerISO ? ",bootindex=0" : ""
            a += ["-drive", "if=none,id=cd\(index),media=cdrom,readonly=on,file=\(iso)",
                  "-device", "usb-storage,drive=cd\(index),removable=on,bus=xhci.0\(boot)"]
        }

        if windows && tools.swtpm != nil {
            // ppi=off: the TPM's Physical Presence page is a 1 KB RAM region, and Apple's Hypervisor
            // only maps 16 KB-aligned memory, so with PPI on QEMU dies at start with HV_BAD_ARGUMENT.
            a += ["-chardev", "socket,id=chrtpm,path=\(tpmSocket)",
                  "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                  "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off"]
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
            try send(socketPath, #"{"execute":"\#(command)"}"#)
        }.value
    }

    /// Presses and releases one key (a QEMU "qcode" such as "ret" or "spc").
    static func sendKey(_ socketPath: String, _ qcode: String) throws {
        try send(socketPath, #"{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"\#(qcode)"}]}}"#)
    }

    private static func send(_ path: String, _ json: String) throws {
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
        write(fd, json)
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
