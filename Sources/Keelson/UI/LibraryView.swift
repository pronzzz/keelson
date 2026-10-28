import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: VMLibrary
    @State private var selection: URL?
    @State private var showingNew = false
    @State private var importing = false
    @State private var alert: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Virtual Machines") {
                    ForEach(library.machines) { vm in
                        SidebarRow(vm: vm).tag(vm.bundle.url)
                    }
                }
                if !library.offline.isEmpty {
                    Section("Offline (drive not connected)") {
                        ForEach(library.offline, id: \.self) { url in
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "externaldrive.badge.xmark")
                                .foregroundStyle(.secondary)
                                .contextMenu {
                                    Button("Remove from Library") { library.forget(url) }
                                }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { showingNew = true } label: { Label("New VM", systemImage: "plus") }
                    Spacer()
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Add an existing .keelsonvm bundle")
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } detail: {
            if let url = selection, let vm = library.machines.first(where: { $0.bundle.url == url }) {
                VMDetailView(vm: vm, selection: $selection)
                    .id(url)
            } else {
                EmptyLibraryView(hasMachines: !library.machines.isEmpty) { showingNew = true }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewVMSheet { created in selection = created.bundle.url }
                .environmentObject(library)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .package]) { result in
            if case .success(let url) = result {
                do { try library.importBundle(url); selection = url } catch { alert = error.localizedDescription }
            }
        }
        .alert("Couldn't add VM", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") {}
        } message: { Text(alert ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .keelsonNewVM)) { _ in showingNew = true }
        .onAppear {
            if selection == nil { selection = library.machines.first?.bundle.url }
            // `open Keelson.app --args --new-vm` jumps straight into the wizard.
            if CommandLine.arguments.contains("--new-vm") { showingNew = true }
        }
    }
}

private struct SidebarRow: View {
    @ObservedObject var vm: VMInstance

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.config.guest.symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.config.name).lineLimit(1)
                Text(vm.state.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(vm.statusColor).frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }
}

extension VMInstance {
    var statusColor: Color {
        switch state {
        case .running: return .green
        case .paused: return .yellow
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .gray.opacity(0.4)
        }
    }
}

private struct EmptyLibraryView: View {
    let hasMachines: Bool
    let create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text(hasMachines ? "Select a virtual machine" : "No virtual machines yet")
                .font(.title2.weight(.semibold))
            Text("Run Linux or Windows 11 for ARM on this Mac. Keep VMs on any drive, or give a VM a whole external SSD.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if !hasMachines {
                Button("Create a Virtual Machine", action: create)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(40)
    }
}
