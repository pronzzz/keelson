import SwiftUI

@main
enum KeelsonMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else {
            KeelsonApp.main()
        }
    }
}

struct KeelsonApp: App {
    @StateObject private var library = VMLibrary.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Keelson", id: "library") {
            LibraryView()
                .environmentObject(library)
                .frame(minWidth: 860, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") {
                    NotificationCenter.default.post(name: .keelsonNewVM, object: nil)
                }.keyboardShortcut("n")
            }
        }

        WindowGroup("Machine", id: "display", for: URL.self) { $url in
            VMDisplayWindow(bundleURL: url)
                .environmentObject(library)
        }

        Settings {
            PreferencesView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { VMLibrary.shared.machines.filter(\.isActive) }
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(running.count) virtual machine\(running.count == 1 ? " is" : "s are") still running"
        alert.informativeText = "Quitting will power them off immediately, like pulling the plug. Shut them down from inside the guest first to avoid losing data."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Power Off and Quit")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            for vm in running { await vm.forceStop() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension Notification.Name {
    static let keelsonNewVM = Notification.Name("KeelsonNewVM")
}
