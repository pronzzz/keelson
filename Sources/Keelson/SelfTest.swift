import Foundation
import Virtualization

/// `Keelson.app/Contents/MacOS/Keelson --selftest`
/// Boots a throwaway Linux-style VM (UEFI, no OS) on the Apple engine for a few seconds,
/// prints the QEMU command a Windows VM would use, and lists external disks.
enum SelfTest {
    static func run() -> Never {
        Task { @MainActor in
            var failures = 0
            func check(_ ok: Bool, _ what: String) {
                print(ok ? "PASS" : "FAIL", what)
                if !ok { failures += 1 }
            }

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keelson-selftest-\(UUID().uuidString.prefix(6))")
            defer { try? FileManager.default.removeItem(at: dir) }

            // 1. Bundle creation with a sparse disk.
            let config = VMConfig(name: "SelfTest", guest: .linux, engine: .apple, cpuCount: 2, memoryMB: 2048,
                                  disk: .image(fileName: "disk.img", sizeGB: 8), macAddress: VMConfig.randomMAC())
            do {
                let bundle = try VMBundle.create(config: config, in: dir)
                let loaded = try bundle.load()
                check(loaded.id == config.id && loaded.disk == config.disk && loaded.macAddress == config.macAddress, "bundle round-trips config.json")
                let attrs = try FileManager.default.attributesOfItem(atPath: bundle.diskURL(for: config)!.path)
                check((attrs[.size] as? Int64) == 8 * 1_073_741_824, "disk image is 8 GB (sparse)")

                // 2. Apple engine: build, validate, boot firmware, power off.
                let vm = VMInstance(bundle: bundle, config: loaded)
                await vm.start()
                check(vm.state == .running, "Apple Virtualization VM boots (state: \(vm.state.label))")
                // With an empty disk and no installer, UEFI finds nothing to boot and powers the guest off.
                // That exercises the firmware and the guest-initiated shutdown path.
                for _ in 0..<100 where vm.state == .running { try await Task.sleep(nanoseconds: 100_000_000) }
                check(vm.state == .stopped, "UEFI ran and the guest powered itself off cleanly (state: \(vm.state.label))")

                // Force power-off path: start again and pull the plug immediately.
                await vm.start()
                await vm.forceStop()
                check(vm.state == .stopped, "Force power off works")
                check(FileManager.default.fileExists(atPath: bundle.appleEFIVarsURL.path), "UEFI variable store persisted")

                // 3. Windows-on-QEMU command line (only if QEMU is installed).
                var win = config
                win.guest = .windows; win.engine = .qemu
                if QEMUToolchain.find() != nil {
                    let args = try QEMURunner(config: win, bundle: bundle, rawFD: nil).arguments()
                    print("     qemu args:", args.joined(separator: " "))
                    check(args.contains("tpm-tis-device,tpmdev=tpm0") || QEMUToolchain.find()?.swtpm == nil, "Windows gets a TPM when swtpm exists")
                } else {
                    print("SKIP QEMU not installed (\(QEMUToolchain.installHint))")
                }
            } catch {
                check(false, "unexpected error: \(error.localizedDescription)")
            }

            // 4. External disk discovery.
            do {
                let disks = try DiskScanner.externalDisks()
                print("     boot disks excluded:", DiskScanner.bootWholeDisks().sorted())
                print("     external disks:", disks.isEmpty ? "none connected" : disks.map { "\($0.bsdName) \($0.mediaName) \($0.sizeText)" }.joined(separator: ", "))
                check(!disks.contains { DiskScanner.bootWholeDisks().contains($0.bsdName) }, "boot disk never offered")
            } catch {
                check(false, "disk scan: \(error.localizedDescription)")
            }

            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
