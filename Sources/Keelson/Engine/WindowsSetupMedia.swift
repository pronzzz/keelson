import Foundation

/// A small ISO Keelson attaches next to the Windows installer. Windows Setup reads `autounattend.xml`
/// from the root of any attached drive, so this works without changing Microsoft's ISO.
///
/// The answer file only fills in things that break on a VM; every normal setup page still appears:
/// - skips the TPM / Secure Boot / CPU / RAM checks (useful when swtpm isn't installed),
/// - installs the ARM64 virtio drivers from the drivers ISO (network, balloon, input, GPU, serial…),
///   so the network works during setup instead of stopping at "Let's connect you to a network",
/// - allows finishing setup offline with a local account.
enum WindowsSetupMedia {
    /// Bump when the files below change so existing VMs get the new disk.
    static let revision = "2"

    /// Returns the setup ISO for this VM, building it if it's missing or out of date.
    static func ensure(in bundle: VMBundle) throws -> URL {
        let fm = FileManager.default
        let iso = bundle.setupMediaURL
        let stamp = bundle.url.appendingPathComponent(".keelson-setup-revision")
        if fm.fileExists(atPath: iso.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == revision {
            return iso
        }

        let work = fm.temporaryDirectory.appendingPathComponent("keelson-setup-\(UUID().uuidString)", isDirectory: true)
        let src = work.appendingPathComponent("src", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: src.appendingPathComponent("keelson"), withIntermediateDirectories: true)
        try crlf(autounattend).write(to: src.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        try crlf(specializeScript).write(to: src.appendingPathComponent("keelson/specialize.cmd"), atomically: true, encoding: .utf8)
        try crlf(readme).write(to: src.appendingPathComponent("keelson/README.txt"), atomically: true, encoding: .utf8)

        let out = work.appendingPathComponent("setup.iso")
        let (status, output) = runTool("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet",
                                                            "-default-volume-name", "KEELSON",
                                                            "-o", out.path, src.path])
        guard status == 0, fm.fileExists(atPath: out.path) else {
            throw KeelsonError("Couldn't build the Windows setup helper disk: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try? fm.removeItem(at: iso)
        try fm.moveItem(at: out, to: iso)
        try revision.write(to: stamp, atomically: true, encoding: .utf8)
        return iso
    }

    private static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func runTool(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Files on the disk

    private static func labConfig(_ order: Int, _ name: String) -> String {
        """
                <RunSynchronousCommand wcm:action="add">
                  <Order>\(order)</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(name) /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
        """
    }

    static var autounattend: String {
        let checks = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassCPUCheck", "BypassRAMCheck", "BypassStorageCheck"]
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Added by Keelson. Fills in only what a virtual machine needs; every other setup page still appears. -->
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
        \(checks.enumerated().map { labConfig($0.offset + 1, $0.element) }.joined(separator: "\n"))
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Description>Keelson: install virtio drivers and allow offline setup</Description>
                  <Path>cmd.exe /c "for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\\keelson\\specialize.cmd call %d:\\keelson\\specialize.cmd"</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        </unattend>
        """
    }

    static let specializeScript = #"""
    @echo off
    rem Keelson: runs once while Windows is being set up (the "specialize" pass).
    set LOG=%SystemRoot%\Temp\keelson-setup.log
    echo Keelson setup helpers %DATE% %TIME% >> "%LOG%"

    rem Install every Windows 11 ARM64 driver from the virtio-win drivers ISO, if it's attached.
    for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
      if exist "%%d:\NetKVM\w11\ARM64" (
        echo virtio-win found on %%d: >> "%LOG%"
        for /d %%s in ("%%d:\*") do (
          if exist "%%s\w11\ARM64\*.inf" pnputil /add-driver "%%s\w11\ARM64\*.inf" /install >> "%LOG%" 2>&1
        )
      )
    )

    rem Offer "I don't have internet" during the out-of-box setup, for a local account.
    reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
    exit /b 0
    """#

    static let readme = """
    Keelson setup helpers

    Keelson attaches this disk while a Windows VM boots its installer.
    autounattend.xml skips Windows 11's TPM/Secure Boot/CPU checks, and keelson\\specialize.cmd
    installs the ARM64 virtio drivers from the drivers ISO and allows offline setup.
    A log is written to C:\\Windows\\Temp\\keelson-setup.log.

    Turn it off in the VM's Settings (Installer media > Setup helpers).
    """
}
