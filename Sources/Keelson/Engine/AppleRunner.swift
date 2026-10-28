import Foundation
import Virtualization

@MainActor
protocol VMRunner: AnyObject {
    var onExit: ((String?) -> Void)? { get set }
    func start() async throws
    func requestStop() async throws
    func forceStop() async throws
    func pause() async throws
    func resume() async throws
}

/// Runs a VM in-process with Apple's Virtualization.framework.
/// Best choice for Linux: virtio devices, virtiofs shared folders, clipboard sharing and Rosetta.
@MainActor
final class AppleRunner: NSObject, VMRunner, VZVirtualMachineDelegate {
    let vm: VZVirtualMachine
    var onExit: ((String?) -> Void)?

    init(config: VMConfig, bundle: VMBundle, rawDisk: FileHandle?) throws {
        let configuration = try AppleConfigBuilder.build(config: config, bundle: bundle, rawDisk: rawDisk)
        vm = VZVirtualMachine(configuration: configuration)
        super.init()
        vm.delegate = self
    }

    func start() async throws { try await vm.start() }
    func requestStop() async throws { try vm.requestStop() }
    func forceStop() async throws { try await vm.stop() }
    func pause() async throws { try await vm.pause() }
    func resume() async throws { try await vm.resume() }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.onExit?(nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.onExit?(message) }
    }
}

enum AppleConfigBuilder {
    static func build(config: VMConfig, bundle: VMBundle, rawDisk: FileHandle?) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        c.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                         VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = UInt64(config.memoryMB) * 1024 * 1024
        c.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                           VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // Platform + a stable machine identity so the guest sees the same "hardware" every boot.
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: bundle.machineIDURL),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = id
        } else {
            let id = VZGenericMachineIdentifier()
            try id.dataRepresentation.write(to: bundle.machineIDURL)
            platform.machineIdentifier = id
        }
        c.platform = platform

        // UEFI firmware, so standard installer ISOs boot exactly like on a PC.
        let boot = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: bundle.appleEFIVarsURL.path) {
            boot.variableStore = VZEFIVariableStore(url: bundle.appleEFIVarsURL)
        } else {
            boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: bundle.appleEFIVarsURL)
        }
        c.bootLoader = boot

        // Storage
        var storage: [VZStorageDeviceConfiguration] = []
        let mainAttachment: VZStorageDeviceAttachment
        if let rawDisk {
            mainAttachment = try VZDiskBlockDeviceStorageDeviceAttachment(
                fileHandle: rawDisk, readOnly: false, synchronizationMode: .full)
        } else if let url = bundle.diskURL(for: config) {
            mainAttachment = try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
        } else {
            throw KeelsonError("This VM has no disk configured.")
        }
        if config.guest == .windows {
            // Windows ships an NVMe driver in the box; it has no virtio-blk driver.
            storage.append(VZNVMExpressControllerDeviceConfiguration(attachment: mainAttachment))
        } else {
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: mainAttachment))
        }
        for iso in [config.installerISO, config.driversISO].compactMap({ $0 }) {
            let url = URL(fileURLWithPath: iso)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw KeelsonError("Installer image not found: \(iso)")
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        c.storageDevices = storage

        // Network: NAT. (Bridged networking needs an Apple-granted entitlement.)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: config.macAddress) { net.macAddress = mac }
        c.networkDevices = [net]

        // Display + input
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: config.displayWidth,
                                                             heightInPixels: config.displayHeight)]
        c.graphicsDevices = [gpu]
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Sound output
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        c.audioDevices = [sound]

        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Clipboard sharing via the SPICE agent (spice-vdagent in the guest).
        let console = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = true
        port.attachment = spice
        console.ports[0] = port
        c.consoleDevices = [console]

        // Shared folders (Linux: mount -t virtiofs keelson /mnt/keelson) and Rosetta.
        var fileSystems: [VZDirectorySharingDeviceConfiguration] = []
        if !config.sharedFolders.isEmpty {
            var dirs: [String: VZSharedDirectory] = [:]
            for folder in config.sharedFolders {
                var key = folder.name
                var i = 2
                while dirs[key] != nil { key = "\(folder.name)-\(i)"; i += 1 }
                dirs[key] = VZSharedDirectory(url: URL(fileURLWithPath: folder.path), readOnly: folder.readOnly)
            }
            let share = VZVirtioFileSystemDeviceConfiguration(tag: "keelson")
            share.share = VZMultipleDirectoryShare(directories: dirs)
            fileSystems.append(share)
        }
        if config.rosetta && config.guest == .linux && VZLinuxRosettaDirectoryShare.availability == .installed {
            let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            rosetta.share = try VZLinuxRosettaDirectoryShare()
            fileSystems.append(rosetta)
        }
        c.directorySharingDevices = fileSystems

        try c.validate()
        return c
    }
}
