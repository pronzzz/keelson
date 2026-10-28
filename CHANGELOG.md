# Changelog

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
