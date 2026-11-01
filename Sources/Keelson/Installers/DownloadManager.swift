import CryptoKit
import Foundation

/// Downloads installer ISOs into `<library folder>/Installers` and checks them before use.
/// Downloads keep going when the sheet that started them closes.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    enum Phase: Equatable {
        case downloading(received: Int64, total: Int64)
        case verifying
        /// `check` says how the file was verified, e.g. "SHA-256 matches Ubuntu's SHA256SUMS".
        case done(check: String)
        case failed(String)
    }

    final class Job: ObservableObject, Identifiable {
        let item: InstallerItem
        let destination: URL
        @Published fileprivate(set) var phase: Phase
        fileprivate var task: URLSessionDownloadTask?
        fileprivate var resumeData: Data?
        fileprivate var lastUpdate = Date.distantPast
        var id: String { destination.path }

        init(item: InstallerItem, destination: URL) {
            self.item = item
            self.destination = destination
            self.phase = .downloading(received: 0, total: item.sizeBytes ?? 0)
        }

        var fraction: Double? {
            guard case .downloading(let r, let t) = phase, t > 0 else { return nil }
            return min(1, Double(r) / Double(t))
        }

        var isActive: Bool {
            switch phase {
            case .downloading, .verifying: return true
            default: return false
            }
        }

        var statusText: String {
            switch phase {
            case .downloading(let r, let t):
                let got = ByteCountFormatter.string(fromByteCount: r, countStyle: .file)
                guard t > 0 else { return "Downloading… \(got)" }
                return "Downloading… \(got) of \(ByteCountFormatter.string(fromByteCount: t, countStyle: .file)) (\(Int((fraction ?? 0) * 100))%)"
            case .verifying: return "Checking the download…"
            case .done(let check): return check
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var jobs: [String: Job] = [:]

    private var session: URLSession!
    /// URLSession task id -> destination path. Read on URLSession's queue, so guarded by a lock.
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var destinations: [Int: String] = [:]

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        config.httpAdditionalHeaders = ["User-Agent": "Keelson/\(AppInfo.version)"]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: Files

    static var folder: URL { VMLibrary.defaultFolder.appendingPathComponent("Installers", isDirectory: true) }

    func destination(for item: InstallerItem) -> URL {
        Self.folder.appendingPathComponent(item.fileName)
    }

    /// The finished download for this item, if it's on disk.
    func localFile(for item: InstallerItem) -> URL? {
        guard !item.fileName.isEmpty else {
            if item.guest == .windows, item.role == .installer { return localISOs().first { Self.looksLikeWindows($0) } }
            return nil
        }
        let url = destination(for: item)
        if let job = jobs[url.path], job.isActive { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// ISO files in the Installers folder, newest first.
    func localISOs() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "iso" && jobs[$0.path]?.isActive != true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    static func looksLikeWindows(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("win") && (name.contains("arm64") || name.contains("arm"))
    }

    static func looksLikeVirtio(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasPrefix("virtio-win")
    }

    /// Download progress for a path picked in a VM's settings, if it's still downloading.
    func activeJob(forPath path: String?) -> Job? {
        guard let path, let job = jobs[path], job.isActive else { return nil }
        return job
    }

    func delete(_ url: URL) throws {
        if let job = jobs[url.path] { cancel(job) }
        jobs[url.path] = nil
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        objectWillChange.send()
    }

    // MARK: Direct downloads

    /// Starts (or resumes) downloading the item and returns where the file will be.
    @discardableResult
    func start(_ item: InstallerItem) -> URL {
        let dest = destination(for: item)
        guard case .direct(let url) = item.source else { return dest }
        if let job = jobs[dest.path], job.isActive { return dest }

        let job = Job(item: item, destination: dest)
        if let old = jobs[dest.path], let data = old.resumeData {
            job.task = session.downloadTask(withResumeData: data)
        } else {
            job.task = session.downloadTask(with: url)
        }
        jobs[dest.path] = job
        lock.lock(); destinations[job.task!.taskIdentifier] = dest.path; lock.unlock()
        job.task?.resume()
        return dest
    }

    func cancel(_ job: Job) {
        guard let task = job.task else { return }
        task.cancel { data in
            Task { @MainActor in
                job.resumeData = data
                job.phase = .failed("Download stopped.")
            }
        }
    }

    // MARK: Downloads made elsewhere (Microsoft's page)

    /// Tracks a download the browser sheet is running, so the wizard can show its progress.
    func trackExternal(_ item: InstallerItem, destination: URL) -> Job {
        let job = Job(item: item, destination: destination)
        jobs[destination.path] = job
        return job
    }

    func update(_ job: Job, received: Int64, total: Int64) {
        job.phase = .downloading(received: received, total: total)
    }

    func finishExternal(_ job: Job, check: String) { job.phase = .done(check: check) }
    func failExternal(_ job: Job, _ message: String) { job.phase = .failed(message) }
    func markVerifying(_ job: Job) { job.phase = .verifying }

    // MARK: Verification

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func finish(_ job: Job, downloaded file: URL) {
        job.phase = .verifying
        let expected = job.item.sha256?.lowercased()
        let dest = job.destination
        let source = job.item.title
        Task.detached(priority: .userInitiated) {
            do {
                if let expected {
                    let actual = try Self.sha256(of: file)
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: file)
                        throw KeelsonError("The download is damaged (SHA-256 doesn't match), so it was deleted. Try again.")
                    }
                }
                let check = expected == nil
                    ? "Downloaded over HTTPS."
                    : "Verified: SHA-256 matches the published checksum."
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: file, to: dest)
                await MainActor.run {
                    job.phase = .done(check: check)
                    self.objectWillChange.send()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { job.phase = .failed("\(source): \(message)") }
            }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    private nonisolated func path(for task: URLSessionTask) -> String? {
        lock.lock(); defer { lock.unlock() }
        return destinations[task.taskIdentifier]
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(HTTPSRedirects.upgraded(request))
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let path = path(for: downloadTask) else { return }
        Task { @MainActor in
            guard let job = self.jobs[path], job.isActive else { return }
            let now = Date()
            guard now.timeIntervalSince(job.lastUpdate) > 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            job.lastUpdate = now
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (job.item.sizeBytes ?? 0)
            job.phase = .downloading(received: totalBytesWritten, total: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let path = path(for: downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            let code = http.statusCode
            Task { @MainActor in self.jobs[path]?.phase = .failed("The server returned HTTP \(code).") }
            return
        }
        // The system deletes `location` when this returns, so move it now.
        let partial = URL(fileURLWithPath: path + ".download")
        do {
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
            Task { @MainActor in
                if let job = self.jobs[path] { self.finish(job, downloaded: partial) }
            }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.jobs[path]?.phase = .failed("Couldn't save the download: \(message)") }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let path = path(for: task) else { return }
        lock.lock(); destinations[task.taskIdentifier] = nil; lock.unlock()
        guard let error else { return }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if nsError.code == NSURLErrorCancelled { return }   // cancel(_:) reports it
        Task { @MainActor in
            guard let job = self.jobs[path] else { return }
            job.resumeData = resume
            job.phase = .failed("Download failed: \(error.localizedDescription)")
        }
    }
}
