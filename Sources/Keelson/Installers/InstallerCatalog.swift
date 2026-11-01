import Foundation

/// Something Keelson can download for a guest: an OS installer or the Windows drivers ISO.
struct InstallerItem: Identifiable, Hashable {
    enum Source: Hashable {
        /// A direct HTTPS file download, verified with `sha256` when known.
        case direct(URL)
        /// Microsoft only hands out Windows ISO links to a person using its download page,
        /// so Keelson opens that page in a browser sheet and saves the file the user picks.
        case microsoftPage(URL)
    }

    enum Role: Hashable { case installer, windowsDrivers }

    var id: String
    var title: String
    var detail: String
    var guest: GuestOS
    var role: Role = .installer
    var source: Source
    /// Name of the saved file. Empty for Microsoft's page, where the server picks it.
    var fileName: String
    var sha256: String?
    var sizeBytes: Int64?

    var sizeText: String? {
        sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

enum InstallerCatalog {
    static let windowsPage = URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!
    static let ubuntuReleases = URL(string: "https://cdimage.ubuntu.com/releases/")!
    /// Always redirects to the newest stable virtio-win ISO.
    static let virtioWinLatest = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!

    static let windows11 = InstallerItem(
        id: "windows11-arm64",
        title: "Windows 11 (Arm64)",
        detail: "Multi-edition ISO from Microsoft. Choose the language on Microsoft's page, then Download.",
        guest: .windows,
        source: .microsoftPage(windowsPage),
        fileName: "")

    static let virtioWin = InstallerItem(
        id: "virtio-win",
        title: "virtio-win drivers",
        detail: "Network, memory balloon, input and display drivers for Windows on Arm (Fedora / Red Hat).",
        guest: .windows,
        role: .windowsDrivers,
        source: .direct(virtioWinLatest),
        fileName: "virtio-win.iso")

    /// Every item, with Ubuntu resolved live from cdimage.ubuntu.com.
    static func load() async throws -> [InstallerItem] {
        var items = try await ubuntu()
        items.append(windows11)
        items.append(virtioWin)
        // Sizes are nice to show but not essential; fetch them in parallel with a short timeout.
        await withTaskGroup(of: (Int, Int64?).self) { group in
            for (index, item) in items.enumerated() {
                guard case .direct(let url) = item.source else { continue }
                group.addTask { (index, await contentLength(of: url)) }
            }
            for await (index, size) in group { items[index].sizeBytes = size }
        }
        return items
    }

    // MARK: - Ubuntu

    /// The newest LTS and, if newer, the newest interim release: Desktop and Server for arm64.
    /// Checksums come from each release's SHA256SUMS file.
    static func ubuntu() async throws -> [InstallerItem] {
        let index = try await text(at: ubuntuReleases)
        let series = Set(matches(#"href="(\d{2}\.\d{2})/""#, in: index).compactMap { $0.first })
            .sorted { compareVersions($0, $1) == .orderedDescending }
        guard let newest = series.first else { throw KeelsonError("Couldn't read Ubuntu's release list.") }
        let lts = series.first(where: isLTS)
        var chosen = [newest]
        if let lts, lts != newest { chosen.append(lts) }

        var items: [InstallerItem] = []
        for s in chosen.sorted(by: { isLTS($0) && !isLTS($1) }) {
            let base = ubuntuReleases.appendingPathComponent("\(s)/release/", isDirectory: true)
            let sums = try await text(at: base.appendingPathComponent("SHA256SUMS"))
            items += ubuntuItems(series: s, sums: sums, base: base)
        }
        guard !items.isEmpty else { throw KeelsonError("No Ubuntu arm64 images were found.") }
        return items
    }

    static func isLTS(_ series: String) -> Bool {
        let parts = series.split(separator: ".").compactMap { Int($0) }
        return parts.count == 2 && parts[0] % 2 == 0 && parts[1] == 4
    }

    /// Parses a SHA256SUMS file and keeps the newest point release of each arm64 flavour.
    static func ubuntuItems(series: String, sums: String, base: URL) -> [InstallerItem] {
        var best: [String: (version: String, file: String, hash: String)] = [:]
        for m in matches(#"(?m)^([0-9a-f]{64}) \*?(ubuntu-([0-9.]+)-(desktop|live-server)-arm64\.iso)$"#, in: sums) {
            let (hash, file, version, flavour) = (m[0], m[1], m[2], m[3])
            if let current = best[flavour], compareVersions(current.version, version) != .orderedAscending { continue }
            best[flavour] = (version, file, hash)
        }
        let lts = isLTS(series)
        return ["desktop", "live-server"].compactMap { flavour in
            guard let b = best[flavour] else { return nil }
            let desktop = flavour == "desktop"
            return InstallerItem(
                id: "ubuntu-\(b.version)-\(desktop ? "desktop" : "server")",
                title: "Ubuntu \(b.version)\(lts ? " LTS" : "") \(desktop ? "Desktop" : "Server")",
                detail: desktop
                    ? (lts ? "Long-term support until \(Int(series.prefix(2))! + 2005). Full desktop." : "Latest release, supported for 9 months. Full desktop.")
                    : "Text-mode installer, no desktop. Smaller and faster to set up.",
                guest: .linux,
                source: .direct(base.appendingPathComponent(b.file)),
                fileName: b.file,
                sha256: b.hash)
        }
    }

    // MARK: - Helpers

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    private static func text(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Keelson/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KeelsonError("\(url.host ?? "Server") returned HTTP \(http.statusCode).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral, delegate: HTTPSRedirects.shared, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength > 0 else { return nil }
        return http.expectedContentLength
    }
}

/// Some mirrors (fedorapeople.org) redirect HTTPS requests to plain HTTP. Follow them over HTTPS instead.
final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = HTTPSRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.upgraded(request))
    }

    static func upgraded(_ request: URLRequest) -> URLRequest {
        guard let url = request.url, url.scheme == "http",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return request }
        parts.scheme = "https"
        var copy = request
        copy.url = parts.url
        return copy
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
