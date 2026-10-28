import Foundation

/// An external, physical, whole disk (e.g. a USB/Thunderbolt SSD) that could be handed to a VM.
struct ExternalDisk: Identifiable, Hashable {
    var id: String { bsdName }
    var bsdName: String
    var mediaName: String
    var sizeBytes: Int64
    var busProtocol: String
    var mountPoints: [String]
    var volumeNames: [String]

    var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var ref: PhysicalDiskRef { PhysicalDiskRef(bsdName: bsdName, mediaName: mediaName, sizeBytes: sizeBytes) }
}

/// A mounted volume where a VM bundle could live (internal disk or an external SSD).
struct StorageVolume: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var freeBytes: Int64
    var isInternal: Bool
    var fileSystem: String
}

enum DiskScanner {
    /// Lists external physical whole disks, excluding the boot disk and disk images.
    static func externalDisks() throws -> [ExternalDisk] {
        let list = try plist(["list", "-plist", "external", "physical"])
        let wholeDisks = list["WholeDisks"] as? [String] ?? []
        let all = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        let boot = bootWholeDisks()

        var result: [ExternalDisk] = []
        for bsd in wholeDisks where !boot.contains(bsd) {
            guard let info = try? plist(["info", "-plist", bsd]) else { continue }
            if (info["Internal"] as? Bool) == true { continue }
            if (info["VirtualOrPhysical"] as? String) == "Virtual" { continue }
            let entry = all.first { ($0["DeviceIdentifier"] as? String) == bsd } ?? [:]
            var mounts: [String] = []
            var names: [String] = []
            for part in (entry["Partitions"] as? [[String: Any]] ?? []) + (entry["APFSVolumes"] as? [[String: Any]] ?? []) {
                if let m = part["MountPoint"] as? String { mounts.append(m) }
                if let n = part["VolumeName"] as? String, !n.isEmpty { names.append(n) }
            }
            // APFS volumes on an external disk live in a synthesized container disk; collect those too.
            for store in all where (store["APFSPhysicalStores"] as? [[String: Any]])?.contains(where: {
                (($0["DeviceIdentifier"] as? String) ?? "").hasPrefix(bsd + "s")
            }) == true {
                for vol in store["APFSVolumes"] as? [[String: Any]] ?? [] {
                    if let m = vol["MountPoint"] as? String { mounts.append(m) }
                    if let n = vol["VolumeName"] as? String, !n.isEmpty { names.append(n) }
                }
            }
            result.append(ExternalDisk(
                bsdName: bsd,
                mediaName: (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String) ?? "External disk",
                sizeBytes: (info["TotalSize"] as? NSNumber)?.int64Value ?? (info["Size"] as? NSNumber)?.int64Value ?? 0,
                busProtocol: (info["BusProtocol"] as? String) ?? "",
                mountPoints: mounts,
                volumeNames: names))
        }
        return result
    }

    /// Whole disks that back the running macOS (never offered for raw use).
    static func bootWholeDisks() -> Set<String> {
        var set: Set<String> = []
        guard let info = try? plist(["info", "-plist", "/"]) else { return set }
        if let parent = info["ParentWholeDisk"] as? String { set.insert(parent) }
        for store in info["APFSPhysicalStores"] as? [[String: Any]] ?? [] {
            if let id = store["APFSPhysicalStore"] as? String, let whole = wholeDisk(of: id) { set.insert(whole) }
        }
        return set
    }

    static func wholeDisk(of bsd: String) -> String? {
        guard let r = bsd.range(of: #"^disk\d+"#, options: .regularExpression) else { return nil }
        return String(bsd[r])
    }

    /// Finds the disk a VM was configured with, even if its BSD name changed since.
    static func resolve(_ ref: PhysicalDiskRef) throws -> ExternalDisk {
        let disks = try externalDisks()
        let matches = disks.filter { $0.mediaName == ref.mediaName && $0.sizeBytes == ref.sizeBytes }
        if matches.count == 1 { return matches[0] }
        if let exact = matches.first(where: { $0.bsdName == ref.bsdName }) { return exact }
        if matches.isEmpty {
            throw KeelsonError("The SSD “\(ref.mediaName)” isn't connected. Plug it in and try again.")
        }
        throw KeelsonError("More than one connected SSD looks like “\(ref.mediaName)”. Open this VM's settings and pick the disk again.")
    }

    /// Unmounts every volume on the disk so macOS stops writing to it.
    static func unmountAll(_ bsd: String) throws {
        let (status, output) = run(["unmountDisk", "/dev/\(bsd)"])
        if status != 0 {
            throw KeelsonError("Couldn't unmount \(bsd): \(output.trimmingCharacters(in: .whitespacesAndNewlines)). Close any apps using the disk and try again.")
        }
    }

    /// Mounted volumes that could hold VM bundles.
    static func volumes() -> [StorageVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsInternalKey, .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
            if url.path.hasPrefix("/System/Volumes") && url.path != "/" { return nil }
            return StorageVolume(url: url,
                                 name: v.volumeName ?? url.lastPathComponent,
                                 freeBytes: v.volumeAvailableCapacityForImportantUsage ?? 0,
                                 isInternal: v.volumeIsInternal ?? false,
                                 fileSystem: v.volumeLocalizedFormatDescription ?? "")
        }
    }

    static func freeSpace(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - diskutil

    private static func plist(_ args: [String]) throws -> [String: Any] {
        let (status, data) = runData(args)
        guard status == 0,
              let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw KeelsonError("diskutil \(args.joined(separator: " ")) failed") }
        return obj
    }

    @discardableResult
    static func run(_ args: [String]) -> (Int32, String) {
        let (s, d) = runData(args)
        return (s, String(decoding: d, as: UTF8.self))
    }

    private static func runData(_ args: [String]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}
