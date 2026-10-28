import AppKit
import Foundation

/// Every VM Keelson knows about. Bundles can live anywhere (internal disk, external SSDs);
/// the library just remembers their paths. Bundles on an unplugged SSD show as "offline".
@MainActor
final class VMLibrary: ObservableObject {
    static let shared = VMLibrary()

    @Published private(set) var machines: [VMInstance] = []
    @Published private(set) var offline: [URL] = []

    private let pathsKey = "KeelsonBundlePaths"
    static let defaultFolderKey = "KeelsonDefaultFolder"

    static var defaultFolder: URL {
        if let p = UserDefaults.standard.string(forKey: defaultFolderKey), !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Keelson VMs", isDirectory: true)
    }

    private var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: pathsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: pathsKey) }
    }

    init() {
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
        }
    }

    func reload() {
        var loaded: [VMInstance] = []
        var missing: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if let existing = machines.first(where: { $0.bundle.url == url }) {
                loaded.append(existing)          // keep running instances untouched
                continue
            }
            let bundle = VMBundle(url: url)
            if let config = try? bundle.load() {
                loaded.append(VMInstance(bundle: bundle, config: config))
            } else {
                missing.append(url)
            }
        }
        machines = loaded.sorted { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
        offline = missing
    }

    @discardableResult
    func create(_ config: VMConfig, in folder: URL) throws -> VMInstance {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = try VMBundle.create(config: config, in: folder)
        paths.append(bundle.url.path)
        reload()
        return machines.first { $0.bundle.url == bundle.url } ?? VMInstance(bundle: bundle, config: config)
    }

    func importBundle(_ url: URL) throws {
        let bundle = VMBundle(url: url)
        _ = try bundle.load()
        if !paths.contains(url.path) { paths.append(url.path) }
        reload()
    }

    func forget(_ url: URL) {
        paths.removeAll { $0 == url.path }
        reload()
    }

    func delete(_ vm: VMInstance) throws {
        guard !vm.isActive else { throw KeelsonError("Stop the VM before deleting it.") }
        try FileManager.default.trashItem(at: vm.bundle.url, resultingItemURL: nil)
        forget(vm.bundle.url)
    }

    /// Volumes that hold library bundles; used to stop someone handing a whole SSD
    /// to a VM while other VMs' files live on it.
    func bundlePaths() -> [String] { paths }
}
