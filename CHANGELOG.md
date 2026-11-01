# Changelog

## Unreleased

## 1.1.0 — 2026-11-01

### Added
- **Download installers inside Keelson.** *File ▸ Download Installers…* (⇧⌘D), the disc button in the
  sidebar, or *Download…* next to any ISO field in the new-VM wizard and VM settings.
  - **Ubuntu**: the newest LTS and newest release, Desktop and Server for arm64, found live on
    cdimage.ubuntu.com. Every download is checked against Ubuntu's published SHA-256 before use.
  - **Windows 11 (Arm64)**: Microsoft's official download page opens in a Keelson window. Pick the language
    and click Download; Keelson saves the ISO and checks it against the SHA-256 list Microsoft shows on that page.
  - **virtio-win drivers** for Windows on Arm (network, memory balloon, input, display).
  - Downloads keep going in the background, show progress in the wizard, and can be stopped and resumed.
    Files go to `Installers` inside your Keelson VMs folder. A VM won't start until its ISO has finished.
- **Automatic updates from GitHub.** Keelson checks for a new release once a day (*Keelson ▸ Check for
  Updates…* any time), shows the release notes, and installs and relaunches in one click. Updates are signed
  with Ed25519 and Keelson refuses any download whose signature doesn't match. Turn it off in Settings.
- **Windows setup helpers** (on by default, per-VM toggle). While a Windows installer is attached Keelson
  adds a small answer-file disk that skips Windows 11's TPM/Secure Boot/CPU checks, installs the ARM64
  virtio drivers during setup so networking works, and allows a local account without internet.
- Release pipeline: `scripts/bump-version.sh`, `scripts/release.sh` and GitHub Actions workflows that build,
  sign and publish a release from a tag, or from one click on *Actions ▸ Bump version*.

### Fixed
- **Windows VMs wouldn't start with current QEMU.** With QEMU 10+ on Apple's Hypervisor, the TPM
  device's 1 KB "physical presence" memory region can't be mapped (Hypervisor needs 16 KB alignment), so
  QEMU quit immediately with `HV_BAD_ARGUMENT`. Keelson now attaches the TPM with `ppi=off`.
- **Windows Setup dropped into the UEFI shell** if you missed "Press any key to boot from CD or DVD".
  On a blank disk Keelson now presses the key for you, and the installer always boots before the disk.
- **Stuck at "Let's connect you to a network"**: the virtio network driver is now installed during setup
  (with the virtio-win ISO attached, which the wizard offers to download).
- A failed Windows start left the TPM emulator running, which blocked every later start until you logged out.
  Keelson now stops it, and cleans up a stale one before starting.
- QEMU control sockets fall back to `/tmp` when the temp folder path is too long for a Unix socket.
- `--selftest` left its throwaway VM folder in the temp directory after every run. It now cleans up.

### Changed
- The wizard picks an already-downloaded virtio-win ISO automatically for new Windows VMs.
- `--selftest` now boots a real headless Windows-style QEMU VM with the TPM, the setup helper disk and an
  installer attached, and checks update signatures and the Ubuntu catalog. New `--catalog`, `--fetch <id>`
  and `--check-update` commands for testing downloads and releases from Terminal.

## 1.0.0 — 2026-10-28

First release.

### Added
- Linux (ARM64) virtual machines on Apple's Virtualization framework: UEFI boot from any installer ISO,
  virtio disk/network/graphics/sound, automatic display resizing, clipboard sharing (SPICE agent),
  virtiofs shared folders and Rosetta for x86-64 Linux programs.
- Windows 11 (ARM64) virtual machines through QEMU on Apple's Hypervisor framework: TPM 2.0 (swtpm),
  NVMe boot disk, UEFI framebuffer, USB keyboard/tablet/audio, optional drivers ISO.
- Store VMs on any drive, including external SSDs. VMs on an unplugged drive show as offline and
  return when it's reconnected.
- Whole-SSD mode: install a guest OS directly onto an external SSD. Keelson unmounts the disk, blocks
  macOS from re-mounting it while the VM runs, and gets raw access through the system admin prompt.
  The boot disk and drives holding VM files are never offered.
- Library window, new-VM wizard, per-VM settings, pause/resume, graceful shutdown and force power off.
- `--selftest` command that boots a throwaway VM to confirm virtualization works on the Mac.
- Drag-to-install DMG (`Keelson-1.0.0.dmg`) alongside the zip, built by `scripts/build-dmg.sh`.
