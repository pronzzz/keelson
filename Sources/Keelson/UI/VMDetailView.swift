import SwiftUI

struct VMDetailView: View {
    @ObservedObject var vm: VMInstance
    @Binding var selection: URL?
    @EnvironmentObject var library: VMLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let message = vm.errorMessage {
                    Banner(icon: "exclamationmark.triangle.fill", tint: .red, text: message) { vm.clearError() }
                }
                if vm.config.engine == .qemu && QEMUToolchain.find() == nil {
                    QEMUMissingBanner()
                }
                controls
                details
                GuestTips(config: vm.config)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(vm.config.name)
        .sheet(isPresented: $editing) { VMSettingsSheet(vm: vm) }
        .confirmationDialog("Move “\(vm.config.name)” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                do { try library.delete(vm); selection = nil } catch { actionError = error.localizedDescription }
            }
        } message: {
            if case .physical = vm.config.disk {
                Text("Only the VM's settings are removed. The operating system installed on the external SSD is left untouched.")
            } else {
                Text("This deletes the VM and its virtual disk.")
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: { Text(actionError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.tint.opacity(0.15))
                Image(systemName: vm.config.guest.symbol).font(.system(size: 28)).foregroundStyle(.tint)
            }
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.config.name).font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(vm.statusColor).frame(width: 8, height: 8)
                    Text(vm.state.label)
                    Text("·").foregroundStyle(.tertiary)
                    Text(vm.config.guest.displayName)
                    Text("·").foregroundStyle(.tertiary)
                    Text(vm.config.engine.displayName)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            switch vm.state {
            case .stopped, .failed:
                Button {
                    Task {
                        await vm.start()
                        if vm.config.engine == .apple && vm.appleVM != nil {
                            openWindow(id: "display", value: vm.bundle.url)
                        }
                    }
                } label: { Label("Start", systemImage: "play.fill").frame(minWidth: 70) }
                    .buttonStyle(.borderedProminent)
                Button { editing = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            case .starting, .stopping:
                ProgressView().controlSize(.small)
                Text(vm.state.label).foregroundStyle(.secondary)
                Spacer()
                Button("Force Power Off") { Task { await vm.forceStop() } }
            case .running, .paused:
                if vm.config.engine == .apple {
                    Button { openWindow(id: "display", value: vm.bundle.url) } label: {
                        Label("Show Window", systemImage: "macwindow")
                    }.buttonStyle(.borderedProminent)
                }
                Button { Task { await vm.stop() } } label: { Label("Shut Down", systemImage: "power") }
                Button { Task { await vm.togglePause() } } label: {
                    Label(vm.state == .paused ? "Resume" : "Pause",
                          systemImage: vm.state == .paused ? "play.fill" : "pause.fill")
                }
                Spacer()
                Button(role: .destructive) { Task { await vm.forceStop() } } label: {
                    Label("Force Power Off", systemImage: "bolt.slash")
                }
            }
        }
        .controlSize(.large)
    }

    private var details: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                row("CPU", "\(vm.config.cpuCount) cores")
                row("Memory", "\(vm.config.memoryMB / 1024) GB")
                row("Disk", vm.config.diskSummary)
                row("Installer", vm.config.installerISO.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                if let drivers = vm.config.driversISO { row("Drivers", URL(fileURLWithPath: drivers).lastPathComponent) }
                if !vm.config.sharedFolders.isEmpty {
                    row("Shared", vm.config.sharedFolders.map(\.name).joined(separator: ", "))
                }
                if vm.config.guest == .linux && vm.config.engine == .apple {
                    row("Rosetta", vm.config.rosetta ? "On (run x86-64 Linux apps)" : "Off")
                }
                row("Location", vm.bundle.url.deletingLastPathComponent().path)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct QEMUMissingBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Windows VMs need QEMU").font(.headline)
                Text("Install it once with Homebrew, then come back. swtpm adds the TPM 2.0 chip Windows 11 asks for.")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(QEMUToolchain.installHint).font(.body.monospaced()).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(QEMUToolchain.installHint, forType: .string)
                    }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct GuestTips: View {
    let config: VMConfig

    var body: some View {
        DisclosureGroup("Setup tips") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                        Text(tip).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tips: [String] {
        var t: [String] = []
        switch (config.guest, config.engine) {
        case (.linux, .apple):
            t += ["Use an ARM64 (aarch64) installer ISO, e.g. Ubuntu Desktop arm64, Fedora aarch64 or Debian arm64.",
                  "After installing, remove the installer in Settings so the VM boots from its disk.",
                  "Clipboard sharing: install spice-vdagent in the guest.",
                  "Shared folders: sudo mount -t virtiofs keelson /mnt/keelson"]
            if config.rosetta {
                t.append("Rosetta: sudo mount -t virtiofs rosetta /media/rosetta, then register it with binfmt (see Apple's “Running Intel binaries in Linux VMs” guide).")
            }
        case (.windows, .qemu):
            t += ["Use Windows 11 for ARM64 media (from Microsoft's “Download Windows 11 Arm64” page).",
                  "When the window says “Press any key to boot from CD”, click into it and press a key.",
                  "No network during setup? Press Shift+F10 and run OOBE\\BYPASSNRO, or attach virtio-win drivers as the Drivers ISO and load the NetKVM driver.",
                  "Without swtpm installed, Windows Setup reports the PC can't run Windows 11. Install swtpm, or use the LabConfig bypass (see README).",
                  "The display is a basic UEFI framebuffer: fine for desktop use, no 3D acceleration."]
        case (.windows, .apple):
            t += ["Experimental: Apple's framework has no TPM and no Windows display driver. If Setup won't start, switch the engine to QEMU in Settings."]
        case (.linux, .qemu):
            t += ["Shared folders use 9p: sudo mount -t 9p -o trans=virtio keelson0 /mnt/share"]
        }
        if case .physical = config.disk {
            t.append("This VM uses a whole external SSD. Keep it connected while the VM runs; macOS is blocked from mounting it until the VM stops.")
        }
        return t
    }
}
