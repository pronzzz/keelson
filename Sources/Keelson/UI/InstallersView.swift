import SwiftUI

/// Lists installers Keelson can download (Ubuntu, Windows 11, virtio-win) and the ISOs already downloaded.
/// From the new-VM wizard, `onPick` receives the chosen file (possibly still downloading).
struct InstallersView: View {
    var guest: GuestOS?
    var role: InstallerItem.Role?
    var onPick: ((URL) -> Void)?

    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [InstallerItem] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var showingMicrosoft = false
    @State private var actionError: String?

    private var visible: [InstallerItem] {
        items.filter { (guest == nil || $0.guest == guest) && (role == nil || $0.role == role) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(onPick == nil ? "Installers" : "Download an Installer").font(.title2.weight(.semibold))
                    Text("Official ARM64 images, checked before use.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Finding the latest releases…").foregroundStyle(.secondary) }
                } else if let loadError {
                    HStack {
                        Text(loadError).foregroundStyle(.secondary)
                        Spacer()
                        Button("Try Again") { Task { await load() } }
                    }
                }
                ForEach([GuestOS.linux, .windows].filter { g in visible.contains { $0.guest == g } }) { g in
                    Section(g == .linux ? "Linux" : "Windows 11") {
                        ForEach(visible.filter { $0.guest == g }) { item in
                            InstallerRow(item: item, onPick: onPick.map { pick in { url in pick(url); dismiss() } },
                                         openMicrosoft: { showingMicrosoft = true })
                        }
                    }
                }
                let local = downloads.localISOs().filter { url in
                    guest == nil || (guest == .windows) == (DownloadManager.looksLikeWindows(url) || DownloadManager.looksLikeVirtio(url))
                }
                if !local.isEmpty {
                    Section("Downloaded") {
                        ForEach(local, id: \.self) { url in
                            HStack {
                                Image(systemName: "opticaldisc").foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(fileSize(url)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let onPick {
                                    Button("Use") { onPick(url); dismiss() }
                                }
                                Menu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("Move to Trash", role: .destructive) {
                                        do { try downloads.delete(url) } catch { actionError = error.localizedDescription }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Saved in \(DownloadManager.folder.path)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Button {
                    try? FileManager.default.createDirectory(at: DownloadManager.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(DownloadManager.folder)
                } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Open the Installers folder")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 560)
        .task {
            if CommandLine.arguments.contains("--microsoft-download") { showingMicrosoft = true }
            await load()
        }
        .sheet(isPresented: $showingMicrosoft) {
            MicrosoftDownloadSheet { url in
                if let onPick { onPick(url); dismiss() }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: { Text(actionError ?? "") }
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            items = try await InstallerCatalog.load()
        } catch {
            // Offline: Windows and virtio-win still work (their pages/links are fixed).
            items = [InstallerCatalog.windows11, InstallerCatalog.virtioWin]
            loadError = "Couldn't reach cdimage.ubuntu.com: \(error.localizedDescription)"
        }
        loading = false
    }

    private func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct InstallerRow: View {
    let item: InstallerItem
    var onPick: ((URL) -> Void)?
    var openMicrosoft: () -> Void
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        let dest = downloads.destination(for: item)
        let job = item.fileName.isEmpty ? nil : downloads.jobs[dest.path]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline)
                    Text(item.detail + (item.sizeText.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions(job: job, dest: dest)
            }
            if let job { JobProgress(job: job) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actions(job: DownloadManager.Job?, dest: URL) -> some View {
        if case .microsoftPage = item.source {
            if let local = downloads.localFile(for: item), let onPick {
                Button("Use \(local.lastPathComponent)") { onPick(local) }.lineLimit(1)
            }
            Button("Open Microsoft's Page…", action: openMicrosoft)
        } else if let job, job.isActive {
            if let onPick { Button("Use When Done") { onPick(dest) } }
            Button("Stop") { downloads.cancel(job) }
        } else if let local = downloads.localFile(for: item) {
            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            if let onPick { Button("Use") { onPick(local) }.buttonStyle(.borderedProminent) }
        } else {
            Button(job == nil ? "Download" : "Retry") {
                let url = downloads.start(item)
                onPick?(url)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct JobProgress: View {
    @ObservedObject var job: DownloadManager.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch job.phase {
            case .downloading:
                if let f = job.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
            case .verifying:
                ProgressView().progressViewStyle(.linear)
            default:
                EmptyView()
            }
            Text(job.statusText)
                .font(.caption)
                .foregroundStyle(failed ? Color.red : Color.secondary)
                .textSelection(.enabled)
        }
    }

    private var failed: Bool {
        if case .failed = job.phase { return true }
        return false
    }
}
