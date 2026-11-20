import AppKit
import Foundation
import Virtualization

/// `Keelson --run BUNDLE [--window] [--nvme] [--disk PATH[:ro][:usb|:nvme]]... [--seconds N]`
///
/// Boots an Apple-engine VM without a window, for operating-system development:
/// the guest's serial console (a virtio console port) is this process's stdin and
/// stdout. Exits with the guest (status 0 when it powers off cleanly), or after
/// N seconds when `--seconds` is given. `--window` also shows the guest's display
/// (and takes its keyboard and pointer) in a window, as the app does.
enum HeadlessRun {
    static func run(_ args: [String]) -> Never {
        var bundlePath: String?
        var extras = AppleBuildExtras(serial: (FileHandle.standardInput, FileHandle.standardOutput))
        var seconds: Double?
        var window = false
        var i = args.firstIndex(of: "--run")! + 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--nvme": extras.nvme = true
            case "--window": window = true
            case "--seconds":
                i += 1
                seconds = i < args.count ? Double(args[i]) : nil
            case "--disk":
                i += 1
                guard i < args.count else { fail("--disk needs a path") }
                var parts = args[i].split(separator: ":").map(String.init)
                let ro = parts.contains("ro")
                let bus: AppleBuildExtras.Bus = parts.contains("usb") ? .usb : parts.contains("nvme") ? .nvme : .virtio
                parts.removeAll { $0 == "usb" || $0 == "ro" || $0 == "nvme" }
                extras.disks.append((URL(fileURLWithPath: parts.joined(separator: ":")), ro, bus))
            default:
                if a.hasPrefix("-") { fail("unknown option \(a)") }
                bundlePath = a
            }
            i += 1
        }
        guard let bundlePath else { fail("usage: Keelson --run BUNDLE [--window] [--nvme] [--disk PATH[:ro][:usb|:nvme]]... [--seconds N]") }

        let bundle = VMBundle(url: URL(fileURLWithPath: bundlePath))
        let config: VMConfig
        do { config = try bundle.load() } catch { fail("cannot read \(bundlePath): \(error.localizedDescription)") }
        guard config.engine == .apple else { fail("--run supports Apple-engine VMs only") }

        let vm: VZVirtualMachine
        do {
            let c = try AppleConfigBuilder.build(config: config, bundle: bundle, rawDisk: nil, extras: extras)
            vm = VZVirtualMachine(configuration: c)
        } catch {
            fail("cannot configure the VM: \(error.localizedDescription)")
        }
        let watcher = Watcher()
        vm.delegate = watcher
        vm.start { result in
            if case .failure(let error) = result { fail("cannot start the VM: \(error.localizedDescription)") }
        }
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                FileHandle.standardError.write(Data("\n[keelson] stopping after \(seconds) s\n".utf8))
                vm.stop { _ in exit(0) }
            }
        }
        if window {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let view = VZVirtualMachineView()
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "Keelson – \(bundle.url.deletingPathExtension().lastPathComponent)"
            win.contentView = view
            win.center()
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
            app.activate(ignoringOtherApps: true)
            withExtendedLifetime((vm, watcher, win)) { app.run() }
        }
        withExtendedLifetime((vm, watcher)) { dispatchMain() }
    }

    private final class Watcher: NSObject, VZVirtualMachineDelegate {
        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            FileHandle.standardError.write(Data("\n[keelson] guest powered off\n".utf8))
            exit(0)
        }
        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            fail("VM stopped with an error: \(error.localizedDescription)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("keelson: \(message)\n".utf8))
        exit(1)
    }
}
