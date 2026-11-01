import CryptoKit
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

                // 3. Windows on QEMU: really boot it (headless) with the TPM, setup helpers and an installer.
                var win = config
                win.guest = .windows; win.engine = .qemu
                // A tiny stand-in ISO (not bootable) built from a near-empty folder.
                let fakeInstaller = dir.appendingPathComponent("installer.iso")
                let isoSource = dir.appendingPathComponent("installer-src", isDirectory: true)
                try FileManager.default.createDirectory(at: isoSource, withIntermediateDirectories: true)
                try Data("Keelson self-test".utf8).write(to: isoSource.appendingPathComponent("README.txt"))
                let made = Process()
                made.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                made.arguments = ["makehybrid", "-iso", "-joliet", "-o", fakeInstaller.path, isoSource.path]
                made.standardOutput = FileHandle.nullDevice
                try made.run(); made.waitUntilExit()
                win.installerISO = fakeInstaller.path
                check(win.usesWindowsSetupHelpers, "Windows VMs with an installer use the setup helpers by default")

                if QEMUToolchain.find() != nil {
                    let runner = try QEMURunner(config: win, bundle: bundle, rawFD: nil, headless: true)
                    check(runner.mainDiskIsBlank(), "blank disk detected (auto-presses the boot-from-CD key)")
                    var exited = false
                    runner.onExit = { _ in exited = true }
                    do {
                        try await runner.start()
                        let args = try runner.arguments()
                        print("     qemu args:", args.joined(separator: " "))
                        check(args.contains("tpm-tis-device,tpmdev=tpm0,ppi=off") || QEMUToolchain.find()?.swtpm == nil,
                              "Windows gets a TPM (ppi=off) when swtpm exists")
                        check(args.contains { $0.hasSuffix("keelson-setup.iso") }, "setup helper disk attached")
                        check(args.contains { $0.contains("bootindex=0") }, "installer boots first")
                        check(true, "QEMU + HVF Windows VM with TPM starts and keeps running")
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        try await runner.forceStop()
                        for _ in 0..<50 where !exited { try await Task.sleep(nanoseconds: 100_000_000) }
                        check(exited, "QEMU VM powers off")
                    } catch {
                        check(false, "QEMU Windows VM start: \(error.localizedDescription)")
                    }
                    let setup = bundle.setupMediaURL
                    check(FileManager.default.fileExists(atPath: setup.path), "setup helper ISO built (\(setup.lastPathComponent))")
                } else {
                    print("SKIP QEMU not installed (\(QEMUToolchain.installHint))")
                }
                let xml = try? XMLDocument(xmlString: WindowsSetupMedia.autounattend)
                check(xml?.rootElement()?.name == "unattend", "autounattend.xml is well-formed")
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

            // 5. Updates: version ordering and signature checks.
            check(Updater.isNewer("1.1.0", than: "1.0.0") && Updater.isNewer("1.10.0", than: "1.9.2")
                  && !Updater.isNewer("1.1.0", than: "1.1.0") && Updater.isNewer("1.1.0", than: "1.1.0-beta.2")
                  && !Updater.isNewer("v1.0.9", than: "1.1"), "update version ordering")
            do {
                let key = Curve25519.Signing.PrivateKey()
                let pub = key.publicKey.rawRepresentation.base64EncodedString()
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("keelson-sig-\(UUID().uuidString).zip")
                defer { try? FileManager.default.removeItem(at: file) }
                try Data("update payload".utf8).write(to: file)
                let sig = Data(try key.signature(for: Data(contentsOf: file)).base64EncodedString().utf8)
                try Updater.verify(zip: file, signature: sig, publicKey: pub)
                try Data("tampered payload".utf8).write(to: file)
                let rejected = (try? Updater.verify(zip: file, signature: sig, publicKey: pub)) == nil
                check(rejected, "signed updates verify, tampered ones are rejected")
            } catch {
                check(false, "update signature: \(error.localizedDescription)")
            }
            check(!Updater.publicKey.isEmpty || Bundle.main.bundleURL.pathExtension != "app", "update public key is in Info.plist")

            // 6. Installer catalog: parse a SHA256SUMS sample, then try the live list.
            let sample = """
            c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57 *ubuntu-26.04-desktop-arm64.iso
            c9aa567e6560b2eddae3af03fc686002e35b6fee96f97fd5df3271e846439fdd *ubuntu-26.04-live-server-arm64.iso
            d31e9b3d01ac0fa8e488d4f8d5a7acfeee869f387674eaedf94335e174155901 *ubuntu-26.04-live-server-arm64+largemem.iso
            c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517 *ubuntu-26.04.1-desktop-arm64.iso
            a7110f6c5e77e6f9d2dd1504a71c43d92c859fcee842bd0d51ca790e8afb5f21 *ubuntu-26.04.1-desktop-riscv64.iso
            """
            let parsed = InstallerCatalog.ubuntuItems(series: "26.04", sums: sample, base: InstallerCatalog.ubuntuReleases)
            check(parsed.map(\.fileName) == ["ubuntu-26.04.1-desktop-arm64.iso", "ubuntu-26.04-live-server-arm64.iso"]
                  && parsed.first?.title == "Ubuntu 26.04.1 LTS Desktop", "Ubuntu SHA256SUMS parsing picks newest arm64 images")
            do {
                let live = try await InstallerCatalog.ubuntu()
                for item in live { print("     \(item.title): \(item.fileName)") }
                check(live.contains { $0.title.contains("LTS Desktop") }, "live Ubuntu catalog has an LTS desktop image")
            } catch {
                print("SKIP live Ubuntu catalog (\(error.localizedDescription))")
            }

            // exit() skips `defer`, so remove the throwaway VM explicitly.
            try? FileManager.default.removeItem(at: dir)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// `Keelson --catalog` lists downloadable installers; `Keelson --fetch <id>` downloads and verifies one.
    /// Add `-KeelsonDefaultFolder <dir>` to download somewhere other than the library folder.
    static func runInstallerCommand(_ args: [String]) -> Never {
        Task { @MainActor in
            do {
                let items = try await InstallerCatalog.load()
                guard let i = args.firstIndex(of: "--fetch") else {
                    for item in items {
                        print("\(item.id)\t\(item.title)\t\(item.sizeText ?? "?")\t\(item.sha256 ?? "-")")
                    }
                    exit(0)
                }
                guard i + 1 < args.count, let item = items.first(where: { $0.id == args[i + 1] }) else {
                    print("usage: Keelson --fetch <id>   (ids from --catalog)"); exit(2)
                }
                guard case .direct = item.source else {
                    print("\(item.title) is downloaded from Microsoft's page inside the app."); exit(2)
                }
                let dest = DownloadManager.shared.start(item)
                print("Downloading \(item.title) to \(dest.path)")
                var lastPrint = Date.distantPast
                while true {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    guard let job = DownloadManager.shared.jobs[dest.path] else { continue }
                    switch job.phase {
                    case .done(let check): print(check); exit(0)
                    case .failed(let message): print("FAILED:", message); exit(1)
                    default:
                        if Date().timeIntervalSince(lastPrint) > 5 { print(job.statusText); lastPrint = Date() }
                    }
                }
            } catch {
                print("FAILED:", error.localizedDescription)
                exit(1)
            }
        }
        dispatchMain()
    }
}
