import SwiftUI
import WebKit

/// Microsoft's Windows 11 Arm64 download page in a browser sheet. Microsoft only creates ISO links for
/// a person using that page, so the user picks the edition and language and clicks Download as usual;
/// Keelson saves the file to its Installers folder, then checks it against the SHA-256 list Microsoft
/// shows on the same page.
struct MicrosoftDownloadSheet: View {
    var onStart: (URL) -> Void
    @ObservedObject private var browser = MicrosoftDownloader.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download Windows 11 for Arm from Microsoft").font(.headline)
                    Text("Select **Windows 11 (multi-edition ISO for Arm64)** ▸ Download Now, choose your language ▸ Confirm, then click **Download**. Keelson saves and checks the file for you.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            Divider()
            WebViewHost(webView: browser.webView)
                .overlay(alignment: .top) {
                    if browser.pageLoading { ProgressView().progressViewStyle(.linear) }
                }
            Divider()
            HStack(alignment: .center, spacing: 10) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.webView.canGoBack)
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                if let job = browser.job {
                    JobProgress(job: job).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Downloads go to \(DownloadManager.folder.lastPathComponent) in your Keelson VMs folder.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Open in Safari") { NSWorkspace.shared.open(browser.webView.url ?? InstallerCatalog.windowsPage) }
                if let job = browser.job {
                    CloseButton(job: job) { dismiss() }
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 900, height: 700)
        .onAppear {
            browser.onStart = { url in onStart(url) }
            browser.loadIfNeeded()
        }
        .onDisappear { browser.onStart = nil }
    }
}

/// "Hide" while a download runs (it keeps going), "Done" afterwards.
private struct CloseButton: View {
    @ObservedObject var job: DownloadManager.Job
    let action: () -> Void
    var body: some View {
        Button(job.isActive ? "Hide" : "Done", action: action).keyboardShortcut(.defaultAction)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Owns the web view so a download keeps going after the sheet closes.
@MainActor
final class MicrosoftDownloader: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let shared = MicrosoftDownloader()

    let webView: WKWebView
    @Published private(set) var job: DownloadManager.Job?
    @Published private(set) var pageLoading = false
    var onStart: ((URL) -> Void)?

    private var progressObservation: NSKeyValueObservation?
    private var partials: [ObjectIdentifier: URL] = [:]
    private var finals: [ObjectIdentifier: URL] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        // WKWebView is Safari's engine; identify like Safari so Microsoft serves its normal page.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func loadIfNeeded() {
        guard webView.url == nil else { return }
        // Debug: `-KeelsonMicrosoftPageOverride <url>` loads another page (e.g. a direct .iso link) to test downloads.
        let page = UserDefaults.standard.string(forKey: "KeelsonMicrosoftPageOverride").flatMap(URL.init(string:))
        webView.load(URLRequest(url: page ?? InstallerCatalog.windowsPage))
    }

    private static func isISO(_ url: URL?) -> Bool {
        url?.pathExtension.lowercased() == "iso"
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.shouldPerformDownload || Self.isISO(navigationAction.request.url) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let iso = Self.isISO(navigationResponse.response.url)
        decisionHandler(iso || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Links that open a new window load in this one instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { pageLoading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoading = false; objectWillChange.send() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageLoading = false }

    // MARK: Download

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = DownloadManager.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let name = (suggestedFilename as NSString).lastPathComponent
        let final = folder.appendingPathComponent(name.isEmpty ? "Windows11_Arm64.iso" : name)
        let partial = URL(fileURLWithPath: final.path + ".download")
        try? FileManager.default.removeItem(at: partial)

        let item = InstallerCatalog.windows11
        let job = DownloadManager.shared.trackExternal(item, destination: final)
        self.job = job
        let key = ObjectIdentifier(download)
        partials[key] = partial
        finals[key] = final
        let expected = response.expectedContentLength
        progressObservation = download.progress.observe(\.completedUnitCount) { progress, _ in
            let done = progress.completedUnitCount
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : expected
            Task { @MainActor in
                guard job.isActive, case .downloading = job.phase else { return }
                DownloadManager.shared.update(job, received: done, total: max(total, 0))
            }
        }
        onStart?(final)
        completionHandler(partial)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let partial = partials.removeValue(forKey: key), let final = finals.removeValue(forKey: key),
              let job else { return }
        progressObservation = nil
        DownloadManager.shared.markVerifying(job)
        Task {
            do {
                let hash = try await Task.detached(priority: .userInitiated) { try DownloadManager.sha256(of: partial) }.value
                let page = (try? await webView.evaluateJavaScript("document.documentElement.textContent") as? String) ?? ""
                let published = page.uppercased().contains(hash.uppercased())
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: partial, to: final)
                DownloadManager.shared.finishExternal(job, check: published
                    ? "Verified: SHA-256 matches the hash Microsoft lists on its download page."
                    : "Downloaded from Microsoft over HTTPS. SHA-256: \(hash)")
            } catch {
                DownloadManager.shared.failExternal(job, "Couldn't save the download: \(error.localizedDescription)")
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        if let partial = partials.removeValue(forKey: key) { try? FileManager.default.removeItem(at: partial) }
        finals[key] = nil
        progressObservation = nil
        if let job { DownloadManager.shared.failExternal(job, "Download failed: \(error.localizedDescription)") }
    }
}
