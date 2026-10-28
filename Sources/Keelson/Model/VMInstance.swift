import Foundation
import Virtualization

@MainActor
final class VMInstance: ObservableObject, Identifiable {
    enum State: Equatable {
        case stopped, starting, running, paused, stopping
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .paused: return "Paused"
            case .stopping: return "Shutting down…"
            case .failed: return "Error"
            }
        }
    }

    let bundle: VMBundle
    @Published var config: VMConfig
    @Published private(set) var state: State = .stopped
    @Published private(set) var appleVM: VZVirtualMachine?

    private var runner: VMRunner?
    private var blockedDisk: String?

    nonisolated var id: URL { bundle.url }

    init(bundle: VMBundle, config: VMConfig) {
        self.bundle = bundle
        self.config = config
    }

    var isActive: Bool {
        switch state {
        case .starting, .running, .paused, .stopping: return true
        default: return false
        }
    }

    var errorMessage: String? {
        if case .failed(let m) = state { return m }
        return nil
    }

    func save() throws { try bundle.save(config) }

    func start() async {
        guard !isActive else { return }
        state = .starting
        bundle.log("Start requested (\(config.engine.rawValue))")
        var rawFD: Int32?
        do {
            if case .physical(let ref) = config.disk {
                let disk = try DiskScanner.resolve(ref)
                if disk.bsdName != ref.bsdName {
                    config.disk = .physical(disk.ref)
                    try? save()
                }
                try DiskScanner.unmountAll(disk.bsdName)
                MountBlocker.shared.block(disk.bsdName)
                blockedDisk = disk.bsdName
                // VZ wants the block device; QEMU is faster on the raw character device.
                let path = config.engine == .apple ? "/dev/\(disk.bsdName)" : "/dev/r\(disk.bsdName)"
                rawFD = try await Task.detached { try RawDiskAccess.open(devicePath: path) }.value
            }

            let runner: VMRunner
            switch config.engine {
            case .apple:
                let handle = rawFD.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
                rawFD = nil
                let apple = try AppleRunner(config: config, bundle: bundle, rawDisk: handle)
                appleVM = apple.vm
                runner = apple
            case .qemu:
                runner = try QEMURunner(config: config, bundle: bundle, rawFD: rawFD)
            }
            runner.onExit = { [weak self] error in self?.didExit(error) }
            self.runner = runner
            try await runner.start()
            // QEMU now holds its own copy of the disk descriptor.
            if let fd = rawFD { close(fd); rawFD = nil }
            state = .running
            bundle.log("Running")
        } catch {
            if let fd = rawFD { close(fd) }
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard let runner, state == .running || state == .paused else { return }
        state = .stopping
        do { try await runner.requestStop() } catch {
            state = .running
            bundle.log("Graceful stop failed: \(error.localizedDescription)")
        }
    }

    func forceStop() async {
        guard let runner else { return }
        do {
            try await runner.forceStop()
            if config.engine == .apple { didExit(nil) }
        } catch { fail(error.localizedDescription) }
    }

    func togglePause() async {
        guard let runner else { return }
        do {
            if state == .paused { try await runner.resume(); state = .running }
            else if state == .running { try await runner.pause(); state = .paused }
        } catch { bundle.log("Pause/resume failed: \(error.localizedDescription)") }
    }

    func clearError() { if case .failed = state { state = .stopped } }

    private func didExit(_ error: String?) {
        guard runner != nil else { return }
        releaseResources()
        if let error { fail(error) } else { state = .stopped; bundle.log("Stopped") }
    }

    private func fail(_ message: String) {
        releaseResources()
        state = .failed(message)
        bundle.log("Error: \(message)")
    }

    private func releaseResources() {
        runner = nil
        appleVM = nil
        if let disk = blockedDisk { MountBlocker.shared.unblock(disk); blockedDisk = nil }
    }
}
