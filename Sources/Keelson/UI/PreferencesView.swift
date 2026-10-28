import SwiftUI

struct PreferencesView: View {
    @AppStorage(VMLibrary.defaultFolderKey) private var defaultFolder = ""
    @AppStorage(QEMUToolchain.overrideKey) private var qemuPath = ""
    @State private var picking = false

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("New VMs go to") {
                    HStack {
                        Text(VMLibrary.defaultFolder.path).lineLimit(1).truncationMode(.head)
                        Button("Choose…") { picking = true }
                    }
                }
            }
            Section("QEMU (for Windows)") {
                TextField("qemu-system-aarch64 path", text: $qemuPath, prompt: Text("Auto-detect (Homebrew)"))
                if let tools = QEMUToolchain.find() {
                    LabeledContent("QEMU", value: tools.qemu)
                    LabeledContent("TPM emulator", value: tools.swtpm ?? "Not installed — run: brew install swtpm")
                } else {
                    QEMUMissingBanner()
                }
            }
            Section("Rosetta for Linux") {
                switch VZLinuxRosettaAvailabilityText.current {
                case .installed: Text("Installed").foregroundStyle(.secondary)
                case .notInstalled:
                    Text("Not installed. Run in Terminal: softwareupdate --install-rosetta").textSelection(.enabled)
                case .unsupported: Text("Not supported on this Mac").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 380)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { defaultFolder = url.path }
        }
    }
}

import Virtualization

enum VZLinuxRosettaAvailabilityText {
    case installed, notInstalled, unsupported
    static var current: Self {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed: return .installed
        case .notInstalled: return .notInstalled
        default: return .unsupported
        }
    }
}
