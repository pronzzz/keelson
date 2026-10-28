import SwiftUI
import Virtualization

/// The guest's screen for VMs on the Apple engine. (QEMU VMs open their own window.)
struct VMDisplayWindow: View {
    let bundleURL: URL?
    @EnvironmentObject var library: VMLibrary

    var body: some View {
        if let url = bundleURL, let vm = library.machines.first(where: { $0.bundle.url == url }) {
            VMDisplayContent(vm: vm)
        } else {
            Text("This virtual machine is no longer in the library.").padding(40)
        }
    }
}

private struct VMDisplayContent: View {
    @ObservedObject var vm: VMInstance

    var body: some View {
        Group {
            if let machine = vm.appleVM {
                VMScreen(machine: machine)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "power").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text(vm.state == .starting ? "Starting…" : "\(vm.config.name) is not running")
                        .font(.title3)
                    if let error = vm.errorMessage { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
                    if !vm.isActive {
                        Button("Start") { Task { await vm.start() } }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: CGFloat(vm.config.displayWidth) / 2,
               minHeight: 400, idealHeight: CGFloat(vm.config.displayHeight) / 2)
        .navigationTitle(vm.config.name)
        .toolbar {
            ToolbarItemGroup {
                if vm.state == .running || vm.state == .paused {
                    Button { Task { await vm.togglePause() } } label: {
                        Image(systemName: vm.state == .paused ? "play.fill" : "pause.fill")
                    }.help(vm.state == .paused ? "Resume" : "Pause")
                    Button { Task { await vm.stop() } } label: { Image(systemName: "power") }
                        .help("Shut down (sends the power button to the guest)")
                }
            }
        }
    }
}

private struct VMScreen: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
    }
}
