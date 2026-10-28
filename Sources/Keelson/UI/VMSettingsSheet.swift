import SwiftUI

struct VMSettingsSheet: View {
    @ObservedObject var vm: VMInstance
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VMConfig
    @State private var addingFolder = false
    @State private var repickDisk = false
    @State private var newDisk: ExternalDisk?
    @State private var confirm = ""
    @State private var error: String?

    private let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let hostMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    init(vm: VMInstance) {
        self.vm = vm
        _draft = State(initialValue: vm.config)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $draft.name)
                    Picker("Engine", selection: $draft.engine) {
                        ForEach(EngineKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    if draft.engine == .qemu && QEMUToolchain.find() == nil { QEMUMissingBanner() }
                }
                Section("Resources") {
                    Stepper("CPU cores: \(draft.cpuCount)", value: $draft.cpuCount, in: 1...hostCPUs)
                    Stepper("Memory: \(draft.memoryMB / 1024) GB", value: Binding(
                        get: { draft.memoryMB / 1024 }, set: { draft.memoryMB = $0 * 1024 }),
                            in: 2...max(2, hostMemoryGB - 2))
                    if draft.engine == .apple {
                        Picker("Display", selection: Binding(
                            get: { "\(draft.displayWidth)x\(draft.displayHeight)" },
                            set: { v in
                                let p = v.split(separator: "x").compactMap { Int($0) }
                                if p.count == 2 { draft.displayWidth = p[0]; draft.displayHeight = p[1] }
                            })) {
                            ForEach(["1280x800", "1920x1080", "1920x1200", "2560x1440", "2560x1600", "3840x2160"], id: \.self) {
                                Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0)
                            }
                        }
                    }
                    if draft.guest == .linux && draft.engine == .apple {
                        Toggle("Rosetta for x86-64 Linux apps", isOn: $draft.rosetta)
                    }
                }
                Section("Installer media") {
                    ISOField(title: "Installer ISO", path: $draft.installerISO)
                    if draft.guest == .windows { ISOField(title: "Drivers ISO", path: $draft.driversISO) }
                    Text("Remove the installer once the OS is installed so the VM boots straight from its disk.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Shared folders") {
                    ForEach($draft.sharedFolders) { $folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Toggle("Read-only", isOn: $folder.readOnly).toggleStyle(.checkbox)
                            Button { draft.sharedFolders.removeAll { $0.id == folder.id } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add Folder…") { addingFolder = true }
                    if draft.guest == .windows {
                        Text("Shared folders currently work with Linux guests only.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Storage") {
                    LabeledContent("Disk", value: draft.diskSummary)
                    if case .physical = draft.disk {
                        Button("Pick a Different SSD…") { repickDisk.toggle() }
                        if repickDisk {
                            WholeDiskPicker(selected: $newDisk, confirmText: $confirm,
                                            blockedPaths: VMLibrary.shared.bundlePaths())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { draft.sharedFolders.append(SharedFolder(path: url.path)) }
            }
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(repickDisk && newDisk != nil && confirm != "ERASE")
            }
            .padding()
        }
        .frame(width: 560, height: 640)
    }

    private func save() {
        if repickDisk, let disk = newDisk, confirm == "ERASE" { draft.disk = .physical(disk.ref) }
        if draft.engine != .apple { draft.rosetta = false }
        vm.config = draft
        do { try vm.save(); dismiss() } catch { self.error = error.localizedDescription }
    }
}
