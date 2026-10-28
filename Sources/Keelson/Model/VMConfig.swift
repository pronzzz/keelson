import Foundation

enum GuestOS: String, Codable, CaseIterable, Identifiable {
    case linux, windows

    var id: String { rawValue }
    var displayName: String { self == .linux ? "Linux (ARM64)" : "Windows 11 (ARM64)" }
    var symbol: String { self == .linux ? "terminal.fill" : "macwindow" }
    var defaultEngine: EngineKind { self == .linux ? .apple : .qemu }
    var recommendedMemoryMB: Int { self == .linux ? 4096 : 8192 }
    var recommendedDiskGB: Int { self == .linux ? 64 : 96 }
}

enum EngineKind: String, Codable, CaseIterable, Identifiable {
    /// Apple's Virtualization.framework, running inside Keelson's own process.
    case apple
    /// QEMU using Apple's Hypervisor.framework (HVF) for near-native speed, run as a child process.
    case qemu

    var id: String { rawValue }
    var displayName: String { self == .apple ? "Apple Virtualization" : "QEMU + Hypervisor" }
}

/// A whole physical disk handed to the guest. BSD names (disk4, disk5…) can change between
/// reconnects, so we also remember the model name and size and re-resolve at start.
struct PhysicalDiskRef: Codable, Hashable {
    var bsdName: String
    var mediaName: String
    var sizeBytes: Int64
}

enum DiskBacking: Codable, Hashable {
    /// A sparse raw image file inside the VM bundle.
    case image(fileName: String, sizeGB: Int)
    /// An entire external SSD, used as the guest's boot disk.
    case physical(PhysicalDiskRef)
}

struct SharedFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var readOnly = false
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct VMConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var guest: GuestOS
    var engine: EngineKind
    var cpuCount: Int
    var memoryMB: Int
    var disk: DiskBacking
    var installerISO: String?
    /// Second optional ISO, e.g. virtio-win drivers for Windows.
    var driversISO: String?
    var sharedFolders: [SharedFolder] = []
    var rosetta = false
    var displayWidth = 1920
    var displayHeight = 1200
    var macAddress: String
    var created = Date()

    static func randomMAC() -> String {
        // Locally administered, unicast.
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    var diskSummary: String {
        switch disk {
        case .image(_, let gb): return "\(gb) GB virtual disk"
        case .physical(let ref):
            return "Whole SSD: \(ref.mediaName) (\(ByteCountFormatter.string(fromByteCount: ref.sizeBytes, countStyle: .file)))"
        }
    }
}

/// On-disk layout of a VM: `<Name>.keelsonvm/` holding config, disk image, firmware vars, TPM state and logs.
struct VMBundle: Hashable {
    static let pathExtension = "keelsonvm"
    let url: URL

    var configURL: URL { url.appendingPathComponent("config.json") }
    var appleEFIVarsURL: URL { url.appendingPathComponent("efi-vars.vz") }
    var qemuEFIVarsURL: URL { url.appendingPathComponent("efi-vars.fd") }
    var machineIDURL: URL { url.appendingPathComponent("machine-id") }
    var tpmDirURL: URL { url.appendingPathComponent("tpm", isDirectory: true) }
    var logURL: URL { url.appendingPathComponent("keelson.log") }

    func diskURL(for config: VMConfig) -> URL? {
        if case .image(let file, _) = config.disk { return url.appendingPathComponent(file) }
        return nil
    }

    func load() throws -> VMConfig {
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VMConfig.self, from: data)
    }

    func save(_ config: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Creates the bundle folder and a sparse disk image (if the VM uses one).
    static func create(config: VMConfig, in folder: URL) throws -> VMBundle {
        let fm = FileManager.default
        let safeName = config.name.replacingOccurrences(of: "/", with: "-")
        var url = folder.appendingPathComponent("\(safeName).\(pathExtension)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safeName) \(n).\(pathExtension)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)
        if case .image(let file, let gb) = config.disk {
            let diskURL = url.appendingPathComponent(file)
            guard fm.createFile(atPath: diskURL.path, contents: nil) else {
                throw KeelsonError("Could not create the disk image at \(diskURL.path).")
            }
            let handle = try FileHandle(forWritingTo: diskURL)
            // ftruncate makes a sparse file on APFS: it only uses space as the guest writes.
            try handle.truncate(atOffset: UInt64(gb) * 1024 * 1024 * 1024)
            try handle.close()
        }
        try bundle.save(config)
        return bundle
    }
}

struct KeelsonError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
