**A preview: a console system, no desktop yet.**

YVIS 0.1 is the Linux From Scratch 13.1 base system built in CI, with its own
kernel (7.1.8) and initramfs, as a live ISO. It boots to a root shell; the
desktops (KDE Plasma, Hyprland), the installer and the NVIDIA driver come
later. Nothing is installed on your disk.

**What was tested** (QEMU, in CI): BIOS and UEFI, as a disc and as a USB
stick; network by DHCP. Booting from a Ventoy stick is being tested.
Secure Boot must be off.

**Write it to a USB stick** (this erases the stick; check the device name
with `lsblk`):

```
sha256sum -c yvis-0.1-x86_64.iso.sha256
sudo dd if=yvis-0.1-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

At the boot menu, choose YVIS. You are logged in as root on the first
console.
