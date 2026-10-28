import SwiftUI
import UniformTypeIdentifiers

enum StorageMode: String, CaseIterable, Identifiable {
    case file, wholeDisk
    var id: String { rawValue }
    var title: String { self == .file ? "Virtual disk file" : "Entire external SSD" }
}

struct NewVMSheet: View {
    let onCreate: (VMInstance) -> Void
    @EnvironmentObject var library: VMLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var guest: GuestOS = .linux
    @State private var engine: EngineKind = .apple
    @State private var iso: String?
    @State private var driversISO: String?
    @State private var cpus = min(4, ProcessInfo.processInfo.activeProcessorCount)
    @State private var memoryGB = 4
    @State private var rosetta = true
    @State private var storage: StorageMode = .file
    @State private var folder = VMLibrary.defaultFolder
    @State private var diskGB = 64
    @State private var selectedDisk: ExternalDisk?
    @State private var confirmText = ""
    @State private var error: String?
    @State private var creating = false

    private let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let hostMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Operating system") {
                    TextField("Name", text: $name, prompt: Text(guest == .linux ? "Ubuntu" : "Windows 11"))
                    Picker("Guest", selection: $guest) {
                        ForEach(GuestOS.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: guest) { _, g in
                        engine = g.defaultEngine
                        memoryGB = min(g.recommendedMemoryMB / 1024, max(2, hostMemoryGB / 2))
                        diskGB = g.recommendedDiskGB
                    }
                    Picker("Engine", selection: $engine) {
                        Text("Apple Virtualization" + (guest == .windows ? " (experimental)" : " (recommended)")).tag(EngineKind.apple)
                        Text("QEMU + Hypervisor" + (guest == .windows ? " (recommended)" : "")).tag(EngineKind.qemu)
                    }
                    if engine == .qemu && QEMUToolchain.find() == nil { QEMUMissingBanner() }
                    ISOField(title: "Installer ISO", path: $iso)
                    if guest == .windows {
                        ISOField(title: "Drivers ISO (optional)", path: $driversISO)
                    }
                }

                Section("Resources") {
                    Stepper("CPU cores: \(cpus)", value: $cpus, in: 1...hostCPUs)
                    Stepper("Memory: \(memoryGB) GB", value: $memoryGB, in: 2...max(2, hostMemoryGB - 2))
                    if memoryGB > hostMemoryGB / 2 {
                        Text("More than half of this Mac's \(hostMemoryGB) GB can slow macOS down.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if guest == .linux && engine == .apple {
                        Toggle("Rosetta for x86-64 Linux apps", isOn: $rosetta)
                    }
                }

                Section("Storage") {
                    Picker("Install to", selection: $storage) {
                        ForEach(StorageMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if storage == .file {
                        FileStorageFields(folder: $folder, diskGB: $diskGB)
                    } else {
                        WholeDiskPicker(selected: $selectedDisk, confirmText: $confirmText,
                                        blockedPaths: library.bundlePaths() + [folder.path])
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.callout).lineLimit(2) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || creating)
            }
            .padding()
        }
        .frame(width: 600, height: 640)
    }

    private var canCreate: Bool {
        switch storage {
        case .file: return diskGB >= 8
        case .wholeDisk: return selectedDisk != nil && confirmText == "ERASE"
        }
    }

    private func create() {
        error = nil
        creating = true
        defer { creating = false }
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (guest == .linux ? "Linux" : "Windows 11") : name.trimmingCharacters(in: .whitespaces)
        let disk: DiskBacking
        switch storage {
        case .file:
            disk = .image(fileName: "disk.img", sizeGB: diskGB)
        case .wholeDisk:
            guard let d = selectedDisk else { return }
            disk = .physical(d.ref)
        }
        let config = VMConfig(name: finalName, guest: guest, engine: engine, cpuCount: cpus,
                              memoryMB: memoryGB * 1024, disk: disk, installerISO: iso,
                              driversISO: guest == .windows ? driversISO : nil,
                              rosetta: guest == .linux && engine == .apple && rosetta,
                              macAddress: VMConfig.randomMAC())
        // A whole-disk VM keeps its small settings bundle in the default library folder.
        let target = storage == .file ? folder : VMLibrary.defaultFolder
        do {
            let vm = try library.create(config, in: target)
            onCreate(vm)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ISOField: View {
    let title: String
    @Binding var path: String?
    @State private var picking = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") { picking = true }
                if path != nil { Button("Remove") { path = nil } }
            }
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage, .data]) { result in
            if case .success(let url) = result { path = url.path }
        }
    }
}

private struct FileStorageFields: View {
    @Binding var folder: URL
    @Binding var diskGB: Int
    @State private var picking = false
    @State private var volumes: [StorageVolume] = []

    var body: some View {
        LabeledContent("Location") {
            HStack {
                Text(folder.path).lineLimit(1).truncationMode(.head)
                Button("Choose…") { picking = true }
            }
        }
        let externals = volumes.filter { !$0.isInternal }
        if !externals.isEmpty {
            LabeledContent("External drives") {
                HStack {
                    ForEach(externals) { v in
                        Button("\(v.name)") { folder = v.url.appendingPathComponent("Keelson VMs", isDirectory: true) }
                            .help("\(ByteCountFormatter.string(fromByteCount: v.freeBytes, countStyle: .file)) free · \(v.fileSystem)")
                    }
                }
            }
        }
        Stepper("Disk size: \(diskGB) GB", value: $diskGB, in: 8...4096, step: 8)
        let free = DiskScanner.freeSpace(at: existingAncestor(of: folder))
        Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free here. The disk file grows as the guest writes, up to \(diskGB) GB.")
            .font(.caption)
            .foregroundStyle(Int64(diskGB) * 1_073_741_824 > free ? .orange : .secondary)
        if let fs = volumes.first(where: { folder.path.hasPrefix($0.url.path) && $0.url.path != "/" })?.fileSystem,
           fs.localizedCaseInsensitiveContains("ExFAT") || fs.localizedCaseInsensitiveContains("FAT") {
            Text("This drive is \(fs). Disk files can't be sparse there, so they take their full size. Format the SSD as APFS for best results.")
                .font(.caption).foregroundStyle(.orange)
        }
        EmptyView()
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { folder = url }
            }
            .onAppear { volumes = DiskScanner.volumes() }
    }

    private func existingAncestor(of url: URL) -> URL {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path) && u.path != "/" { u = u.deletingLastPathComponent() }
        return u
    }
}

struct WholeDiskPicker: View {
    @Binding var selected: ExternalDisk?
    @Binding var confirmText: String
    var blockedPaths: [String]
    var requireConfirmation = true
    @State private var disks: [ExternalDisk] = []
    @State private var loading = false
    @State private var scanError: String?

    var body: some View {
        Text("The guest OS is installed directly onto the SSD and boots from it. Everything currently on that SSD will be erased by the installer.")
            .font(.callout).foregroundStyle(.secondary)
        if loading {
            ProgressView("Looking for external disks…")
        } else if disks.isEmpty {
            HStack {
                Text(scanError ?? "No external SSDs found. Connect one and press Refresh.").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { scan() }
            }
        } else {
            ForEach(disks) { disk in
                let conflict = conflictReason(disk)
                Button { if conflict == nil { selected = disk } } label: {
                    HStack {
                        Image(systemName: selected == disk ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == disk ? Color.accentColor : .secondary)
                        Image(systemName: "externaldrive.fill")
                        VStack(alignment: .leading) {
                            Text("\(disk.mediaName) — \(disk.sizeText)")
                            Text(conflict ?? "\(disk.bsdName) · \(disk.busProtocol)" +
                                 (disk.volumeNames.isEmpty ? "" : " · contains: \(disk.volumeNames.joined(separator: ", "))"))
                                .font(.caption).foregroundStyle(conflict == nil ? Color.secondary : Color.orange)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(conflict != nil)
            }
            Button("Refresh") { scan() }
        }
        if requireConfirmation, let disk = selected {
            VStack(alignment: .leading, spacing: 6) {
                Label("Type ERASE to confirm you want to give “\(disk.mediaName)” to this VM.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                TextField("ERASE", text: $confirmText).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
            }
        }
        EmptyView().onAppear { if disks.isEmpty { scan() } }
    }

    private func conflictReason(_ disk: ExternalDisk) -> String? {
        for mount in disk.mountPoints where mount != "/" {
            if blockedPaths.contains(where: { $0.hasPrefix(mount + "/") || $0 == mount }) {
                return "Holds Keelson VM files (\(mount)) — can't be used as a whole disk"
            }
        }
        return nil
    }

    private func scan() {
        loading = true
        scanError = nil
        Task.detached {
            let result = Result { try DiskScanner.externalDisks() }
            await MainActor.run {
                loading = false
                switch result {
                case .success(let d): disks = d
                case .failure(let e): scanError = e.localizedDescription
                }
            }
        }
    }
}
