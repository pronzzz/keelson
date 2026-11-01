import AppKit
import CryptoKit
import SwiftUI

/// A release published on GitHub.
struct ReleaseInfo: Equatable {
    var version: String
    var name: String
    var notes: String
    var pageURL: URL
    var zipURL: URL?
    var signatureURL: URL?
    var dmgURL: URL?
    var publishedAt: Date?
}

/// Keeps Keelson current from GitHub Releases.
///
/// Each release carries `Keelson-<version>.zip` and `Keelson-<version>.zip.sig`, an Ed25519 signature made by
/// `scripts/release.sh` (locally or in the Release workflow) with a key that never leaves the maintainer's Mac
/// or the repository's secrets. Keelson only installs an update whose signature matches the public key in its
/// Info.plist (`KSUpdatePublicKey`).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double)
        case installing(ReleaseInfo)
        case failed(String)
    }

    static let autoCheckKey = "KeelsonAutoCheckUpdates"
    private let lastCheckKey = "KeelsonLastUpdateCheck"
    private let skippedKey = "KeelsonSkippedVersion"

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "KeelsonLastUpdateCheck") as? Date

    let repository = Bundle.main.object(forInfoDictionaryKey: "KSUpdateRepository") as? String ?? "pronzzz/keelson"
    nonisolated static var publicKey: String { Bundle.main.object(forInfoDictionaryKey: "KSUpdatePublicKey") as? String ?? "" }
    private var timer: Timer?
    private var downloadTask: Task<Void, Never>?

    var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey); objectWillChange.send() }
    }

    // MARK: Checking

    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.automaticCheck() }
        }
    }

    private func automaticCheck() {
        guard autoCheck else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 20 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        switch state {
        case .downloading, .installing, .checking: return
        default: break
        }
        state = .checking
        do {
            let release = try await fetchLatest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: lastCheckKey)
            if let release, Self.isNewer(release.version, than: AppInfo.version) {
                if !userInitiated && release.version == UserDefaults.standard.string(forKey: skippedKey) {
                    state = .idle
                    return
                }
                state = .available(release)
                UpdateWindowController.shared.show()
            } else {
                state = .upToDate
                if userInitiated { UpdateWindowController.shared.show() }
            }
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            if userInitiated { UpdateWindowController.shared.show() }
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let published_at: Date?
        let assets: [Asset]
    }

    private func fetchLatest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Keelson/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KeelsonError("GitHub returned HTTP \(http.statusCode).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Self.releaseInfo(from: try decoder.decode(GitHubRelease.self, from: data))
    }

    private static func releaseInfo(from release: GitHubRelease) -> ReleaseInfo {
        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let zip = release.assets.first { $0.name.hasSuffix(".zip") && $0.name.hasPrefix("Keelson-") }
        let sig = zip.flatMap { z in release.assets.first { $0.name == z.name + ".sig" } }
        let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }
        return ReleaseInfo(version: version, name: release.name ?? "Keelson \(version)", notes: release.body ?? "",
                           pageURL: release.html_url, zipURL: zip?.browser_download_url,
                           signatureURL: sig?.browser_download_url, dmgURL: dmg?.browser_download_url,
                           publishedAt: release.published_at)
    }

    // MARK: Versions

    /// Semantic version comparison; pre-releases (1.2.0-beta.1) sort before their release.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ v: String) -> ([Int], String?) {
            let trimmed = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let parts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
            let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, parts.count > 1 ? parts[1] : nil)
        }
        let (na, pa) = split(a), (nb, pb) = split(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0, y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (pa, pb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x.compare(y, options: .numeric)
        }
    }

    // MARK: Installing

    var canInstallInPlace: Bool {
        let path = Bundle.main.bundlePath
        return !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
            && FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version, forKey: skippedKey)
        state = .idle
    }

    func cancelDownload(_ release: ReleaseInfo) {
        downloadTask?.cancel()
        state = .available(release)
    }

    func downloadAndInstall(_ release: ReleaseInfo) {
        let running = VMLibrary.shared.machines.filter(\.isActive)
        guard running.isEmpty else {
            state = .failed("Shut down \(running.map(\.config.name).joined(separator: ", ")) first. Updating restarts Keelson, which would power running VMs off.")
            return
        }
        guard let zipURL = release.zipURL, let sigURL = release.signatureURL, canInstallInPlace else {
            NSWorkspace.shared.open(release.dmgURL ?? release.pageURL)
            return
        }
        state = .downloading(release, 0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (app, work) = try await self.prepare(release, zipURL: zipURL, sigURL: sigURL)
                try self.relaunch(into: app, work: work)
            } catch is CancellationError {
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads the zip and signature, verifies them and unpacks the new app into a work folder.
    private func prepare(_ release: ReleaseInfo, zipURL: URL, sigURL: URL) async throws -> (app: URL, work: URL) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("KeelsonUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let progress = UpdateDownloadProgress { fraction in
            Task { @MainActor in
                if case .downloading = Updater.shared.state { Updater.shared.state = .downloading(release, fraction) }
            }
        }
        let (tmp, response) = try await URLSession.shared.download(from: zipURL, delegate: progress)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KeelsonError("Downloading the update failed (HTTP \(http.statusCode)).")
        }
        let zip = work.appendingPathComponent(zipURL.lastPathComponent)
        try FileManager.default.moveItem(at: tmp, to: zip)
        let (sigData, _) = try await URLSession.shared.data(from: sigURL)
        try Task.checkCancellation()
        state = .installing(release)
        try Self.verify(zip: zip, signature: sigData, publicKey: Self.publicKey)
        let app = try await extract(zip: zip, into: work, expecting: release.version)
        return (app, work)
    }

    /// `Keelson --check-update`: everything an update does except replacing the app. For testing releases.
    func dryRun() async -> Int32 {
        do {
            guard let release = try await fetchLatest() else { print("No releases published."); return 1 }
            print("Installed: \(AppInfo.version)  Latest: \(release.version)  Newer: \(Self.isNewer(release.version, than: AppInfo.version))")
            guard let zipURL = release.zipURL, let sigURL = release.signatureURL else {
                print("The latest release has no signed update zip."); return 1
            }
            let (app, work) = try await prepare(release, zipURL: zipURL, sigURL: sigURL)
            defer { try? FileManager.default.removeItem(at: work) }
            print("PASS downloaded \(zipURL.lastPathComponent), signature verified, \(app.lastPathComponent) \(release.version) unpacked and code signature valid")
            return 0
        } catch {
            print("FAIL", error.localizedDescription)
            return 1
        }
    }

    nonisolated static func verify(zip: URL, signature: Data, publicKey: String) throws {
        let encoded = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: encoded) else {
            throw KeelsonError("The update's signature is missing or malformed. It was not installed.")
        }
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard key.isValidSignature(sig, for: data) else {
            throw KeelsonError("The update's signature doesn't match. It was not installed.")
        }
    }

    private func extract(zip: URL, into work: URL, expecting version: String) async throws -> URL {
        let out = work.appendingPathComponent("extracted", isDirectory: true)
        try await Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        let items = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }), let bundle = Bundle(url: app) else {
            throw KeelsonError("The update archive doesn't contain Keelson.app.")
        }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw KeelsonError("The update is for a different app.")
        }
        let newVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard newVersion == version else {
            throw KeelsonError("The update reports version \(newVersion), expected \(version).")
        }
        try await Self.runTool("/usr/bin/codesign", ["--verify", "--strict", app.path])
        return app
    }

    /// Hands off to a tiny shell script that waits for Keelson to quit, swaps the bundle and relaunches.
    private func relaunch(into newApp: URL, work: URL) throws {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let target = Bundle.main.bundleURL.path
        let script = """
        #!/bin/sh
        PID=\(ProcessInfo.processInfo.processIdentifier)
        TARGET=\(quote(target))
        NEW=\(quote(newApp.path))
        BACKUP="$TARGET.previous"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP"; then
          if /usr/bin/ditto "$NEW" "$TARGET"; then rm -rf "$BACKUP"; else rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        /usr/bin/open "$TARGET"
        rm -rf \(quote(work.path))
        """
        let scriptURL = work.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func runTool(_ path: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: KeelsonError("\((path as NSString).lastPathComponent) failed (\(p.terminationStatus)).")) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Reports download progress from URLSession's queue.
final class UpdateDownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }
}

// MARK: - Window

@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: UpdateView())
            let w = NSWindow(contentViewController: host)
            w.title = "Software Update"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 420))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct UpdateView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.title3.weight(.semibold))
                    Text(subheadline).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(20)
        .frame(width: 520, height: 420, alignment: .topLeading)
    }

    private var headline: String {
        switch updater.state {
        case .available(let r), .downloading(let r, _), .installing(let r): return "Keelson \(r.version) is available"
        case .upToDate: return "Keelson is up to date"
        case .checking: return "Checking for updates…"
        case .failed: return "Update problem"
        case .idle: return "Software Update"
        }
    }

    private var subheadline: String {
        switch updater.state {
        case .available, .downloading, .installing: return "You have \(AppInfo.version)."
        default: return "Version \(AppInfo.version)"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .available(let release):
            notes(release)
            HStack {
                Button("Skip This Version") { updater.skip(release); NSApp.keyWindow?.close() }
                Button("Release Page") { NSWorkspace.shared.open(release.pageURL) }
                Spacer()
                Button(updater.canInstallInPlace && release.zipURL != nil ? "Install and Relaunch" : "Download") {
                    updater.downloadAndInstall(release)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            if !updater.canInstallInPlace {
                Text("Move Keelson to the Applications folder to update in place.").font(.caption).foregroundStyle(.secondary)
            }
        case .downloading(let release, let fraction):
            notes(release)
            ProgressView(value: fraction) { Text("Downloading…") }
            HStack { Spacer(); Button("Cancel") { updater.cancelDownload(release) } }
        case .installing(let release):
            notes(release)
            ProgressView { Text("Verifying the signature and installing…") }
        case .failed(let message):
            Text(message).textSelection(.enabled)
            Spacer()
            HStack {
                Button("Release Page") { NSWorkspace.shared.open(updater.releasesPage) }
                Spacer()
                Button("Try Again") { Task { await updater.check(userInitiated: true) } }.keyboardShortcut(.defaultAction)
            }
        case .checking:
            ProgressView().frame(maxWidth: .infinity)
            Spacer()
        case .upToDate, .idle:
            Text("Keelson checks GitHub for new releases once a day. Updates are signed, and Keelson verifies the signature before installing.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Toggle("Check automatically", isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                Spacer()
                Button("Check Now") { Task { await updater.check(userInitiated: true) } }
            }
        }
    }

    private func notes(_ release: ReleaseInfo) -> some View {
        ScrollView {
            Text(Self.markdown(release.notes))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    /// GitHub release notes are Markdown; render inline styles and keep line structure.
    static func markdown(_ text: String) -> AttributedString {
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            if l.hasPrefix("### ") { l = "**" + l.dropFirst(4) + "**" }
            else if l.hasPrefix("## ") { l = "**" + l.dropFirst(3) + "**" }
            else if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            return l
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
