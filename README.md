<p align="center"><img src="docs/icon.png" width="128" alt="Keelson icon"></p>

<h1 align="center">Keelson</h1>

<p align="center">Linux and Windows 11 virtual machines for Apple silicon Macs, on any drive, including whole external SSDs.</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-M1–M4-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.10%2B-orange">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
</p>

<p align="center"><a href="../../releases/latest"><b>⬇ Download Keelson for Mac (.dmg)</b></a></p>

| Library | New VM |
| --- | --- |
| ![Library](docs/library.png) | ![New VM](docs/new-vm.png) |

## What it does

- **Linux (ARM64)** on Apple's built-in Virtualization framework, with nothing extra to install. It boots any
  ARM64 installer ISO and supports automatic display resizing, clipboard sharing, shared folders and
  **Rosetta** for x86-64 Linux programs.
- **Windows 11 (ARM64)** through QEMU on Apple's Hypervisor framework (near-native CPU speed), with
  the TPM 2.0 chip Windows 11 requires.
- **External SSDs.** Keep VM files on any drive, or give a VM an **entire SSD** so the guest OS installs
  directly onto it and boots from it.
- Library window, new-VM wizard, per-VM settings, pause/resume, shutdown and force power off.

Built and tested on an M4 Mac mini. Keelson is an original app. Parallels Desktop was examined only
to understand how a VM app is put together on Apple silicon (see [How it was designed](#how-it-was-designed)).

## Install

**Requires** macOS 14 or later on an Apple silicon Mac (M1–M4).

1. Download **`Keelson-<version>.dmg`** from the [latest release](../../releases/latest).
2. Open it and drag **Keelson** into **Applications**.

   <img src="docs/dmg.png" width="520" alt="Keelson installer window">

3. Eject the *Keelson* disk image.
4. **First launch:** Keelson is signed locally rather than notarized by Apple, so macOS blocks a
   normal double-click the first time. Right-click Keelson in Applications and choose **Open**, then
   **Open** again. After that it opens normally. Alternatively, run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Keelson.app
   ```

5. **Windows guests only:** install QEMU and the TPM emulator with [Homebrew](https://brew.sh):

   ```bash
   brew install qemu swtpm
   ```

   Keelson finds them automatically. You can set a custom QEMU path in **Keelson ▸ Settings**.

`Keelson.zip` on the release page contains the same app if you'd rather not use the disk image.

To check that virtualization works on your Mac, run the built-in self-test. It boots a throwaway VM
and deletes it afterwards:

```bash
/Applications/Keelson.app/Contents/MacOS/Keelson --selftest
```

## Create your first VM

1. Click **New VM** (or press ⌘N).
2. Pick **Linux** or **Windows 11**. Keelson chooses the right engine and suggests CPU, memory and disk sizes.
3. Choose the installer ISO.
4. Under **Storage**, pick where the VM lives (see below), then click **Create**.
5. Select the VM and click **Start**, then install the OS as you would on a real PC.

## Using external SSDs

**Option 1: VM file on the SSD (recommended).** In *New VM ▸ Storage ▸ Virtual disk file*, click
the SSD's name under *External drives* (or *Choose…*). The VM folder (`Name.keelsonvm`) lives on the
SSD. Format the SSD as **APFS** so disk files stay sparse, meaning they only use the space the guest has
actually written. If the SSD is unplugged, the VM shows under *Offline* and comes back when you
reconnect it.

**Option 2: Entire SSD.** Choose *Entire external SSD*, pick the disk, and type `ERASE`. The guest
installer partitions the SSD and the OS boots from it. When you start the VM:

1. Keelson finds the SSD by model and size, because its `diskN` number can change between plug-ins.
2. It unmounts the SSD's volumes and stops macOS from re-mounting them while the VM runs.
3. macOS asks for your administrator password (`authopen`) to grant raw access to that one disk.
   Keelson itself never runs as root.

The boot disk and any drive that holds Keelson VM files are never offered for Option 2.

## Installing Linux

Use an **ARM64 / aarch64** ISO (Ubuntu Desktop arm64, Fedora Workstation aarch64, Debian arm64…).
Create the VM, pick the ISO, Start, and install as normal. Afterwards, remove the ISO in *Settings*.

- Clipboard sharing: install `spice-vdagent` in the guest.
- Shared folders: add them in *Settings*, then `sudo mount -t virtiofs keelson /mnt/keelson`.
- Rosetta (run x86-64 Linux programs): `sudo mount -t virtiofs rosetta /media/rosetta`, then register it
  with `binfmt_misc` as described in Apple's *Running Intel binaries in Linux VMs with Rosetta*.

## Installing Windows 11

Needs `brew install qemu swtpm` (see [Install](#install)).

1. Get the **Windows 11 Arm64** ISO from Microsoft's download page.
2. New VM ▸ Windows 11 ▸ engine *QEMU + Hypervisor* ▸ pick the ISO. Give it at least 4 CPU cores, 8 GB memory and a 64 GB disk.
3. Start. A QEMU window opens. When it says *Press any key to boot from CD or DVD*, click in the window and press a key.
4. Networking during setup: Windows has no built-in driver for the virtual network card. Either
   - attach the [virtio-win](https://github.com/virtio-win/virtio-win-pkg-scripts) ISO as the *Drivers ISO* and load the `NetKVM\w11\ARM64` driver, or
   - at the network screen press **Shift+F10** and run `OOBE\BYPASSNRO`, finish setup offline, then install the drivers from the ISO.
5. If Setup says *This PC can't run Windows 11*, `swtpm` isn't installed. Install it, or press Shift+F10 and run:
   ```
   reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1
   reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1
   ```

Windows uses a basic framebuffer display. It's fine for desktop use but has no 3D acceleration.

## Known limits

| Feature | Status |
| --- | --- |
| Bridged networking, USB device passthrough | Not available. Both need entitlements Apple grants only to approved vendors. VMs use NAT networking. |
| Windows 3D graphics, shared folders, clipboard | Not available (no Windows guest tools yet). |
| Snapshots, disk resizing | Not implemented yet. |
| x86-64 Windows/Linux guests | Not supported. ARM64 guests only; x86 *apps* run inside them through Windows' built-in emulation or Rosetta for Linux. |
| macOS guests | Not implemented (the Apple engine supports them; it's a natural next feature). |
| Notarization | Not notarized, so the first launch needs right-click ▸ Open (see [Install](#install)). |

## Building from source

Requires Xcode (Swift 5.10+) and macOS 14 or later.

```bash
./scripts/build-app.sh
```

This builds `build/Keelson.app` and signs it locally. To sign with a Developer ID instead, set
`SIGN_IDENTITY="Developer ID Application: …"`.

To package the drag-to-install disk image `build/Keelson-<version>.dmg`:

```bash
./scripts/build-dmg.sh
```

Add `--build` to build the app first. The styled installer window needs
[`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`); without it the
script makes a plain disk image with `hdiutil`. The window background is drawn by
`scripts/dmg-background.swift`.

### Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, and add a `CHANGELOG.md` entry.
2. `./scripts/build-dmg.sh --build`, then `build/Keelson.app/Contents/MacOS/Keelson --selftest`.
3. `ditto -c -k --keepParent build/Keelson.app build/Keelson.zip`.
4. Create a GitHub release with the tag `v<version>` and attach the DMG and zip, with their SHA-256 sums in the notes.

The GitHub Actions workflow (`.github/workflows/build.yml`) can also build the app, but it only runs when started manually.

## How it was designed

Parallels Desktop 1.26.4 (App Store edition) was inspected with REA, looking only at bundle
layout, linked system frameworks, entitlements and imported API names. No code was decompiled or copied.

| Observation (Parallels) | Keelson's approach |
| --- | --- |
| `Parallels VM.app` (Windows/Linux) links **Hypervisor.framework** + **vmnet** and has its own device emulation. Entitlements: `hypervisor`, `vm.networking`, `vm.device-access`. | Windows: QEMU, the open-source equivalent of a Hypervisor.framework VMM with full device emulation. Linux: Apple's Virtualization framework. The two `vm.*` entitlements are Apple-restricted, so no bridged networking or USB passthrough. |
| `Parallels Mac VM.app` uses **Virtualization.framework** (`VZVirtualMachine`, `VZEFI…`, virtio devices, `VZNetworkBlockDeviceStorageDeviceAttachment`). | Linux guests use the same framework: EFI boot, virtio block/net/GPU/sound, virtiofs shares, SPICE clipboard, Rosetta. |
| Imports **DiskArbitration** (`DADiskUnmount`, `DARegisterDiskEjectApprovalCallback`, approval sessions) to manage physical disks. | Whole-SSD mode unmounts via `diskutil`, refuses mounts with a DiskArbitration approval callback while the VM runs, and gets raw access through `authopen`. |
| Separate processes per VM (`prl_vm_app`, `prl_macvm_app`) under a control service. | QEMU VMs run as separate child processes controlled over QMP. Apple-engine VMs run in Keelson's own process, which is how Virtualization.framework is designed to be used. |

## Project layout

```
Sources/Keelson/
  KeelsonApp.swift          app entry, windows, quit handling
  SelfTest.swift            --selftest
  Model/                    VMConfig + bundle format, VMInstance (lifecycle), VMLibrary
  Engine/                   AppleRunner (Virtualization.framework), QEMURunner + QMP, Spawner
  Disk/                     DiskScanner (diskutil), RawDiskAccess (authopen), MountBlocker
  UI/                       library, VM detail, new-VM wizard, settings, VM display window
Resources/                  Info.plist, entitlements, app icon
scripts/
  build-app.sh              build and sign Keelson.app
  build-dmg.sh              package the drag-to-install DMG
  dmg-background.swift      draws the DMG window background
docs/                       README images
```

## License

[MIT](LICENSE) © 2026 Pranav Dwivedi
