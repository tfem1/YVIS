#!/bin/bash
# Checks YVIS's own sections (lfs/yvis: system configuration and kernel)
# from inside the system; run by `lfs/build.sh verify` after lfs/verify.sh.
# What needs a running system (services, network, modules) is checked by
# kernel/boot-test.sh, which boots it.
set -uo pipefail

fail=0
ok() { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }
is() { # description, actual, expected
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"
    printf '        expected: %s\n        got:      %s\n' "$3" "$2"
  fi
}
works() { # description, command...
  local d=$1; shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

echo "== what the installer needs from the system"
works "mkfs.vfat (dosfstools: the EFI partition)" mkfs.vfat --help
works "sudo" sudo -V
is "sudo is setuid root" "$(stat -c '%U %a' /usr/bin/sudo 2>&1)" "root 4755"
works "the wheel group may use sudo" grep -qx '%wheel ALL=(ALL) ALL' /etc/sudoers.d/00-sudo
works "the installer's engine loads" python3 -c "import sys; sys.path.insert(0, '/usr/share/yvis/initramfs/live/usr/lib/yvis/installer'); import yvis_install"

echo "== identity"
is "os-release: ID" "$(. /etc/os-release && echo "$ID")" "yvis"
is "os-release: NAME" "$(. /etc/os-release && echo "$NAME")" "YVIS"
works "os-release: BUILD_ID is filled in" grep -Eq '^BUILD_ID=[0-9a-z.-]+$' /etc/os-release
is "/etc/os-release points to /usr/lib/os-release" "$(readlink -f /etc/os-release)" "/usr/lib/os-release"
is "/etc/hostname" "$(cat /etc/hostname)" "yvis"
is "/etc/lfs-release" "$(cat /etc/lfs-release)" "13.1-systemd"
is "/etc/machine-id is empty (one identifier per installed machine)" "$(wc -c < /etc/machine-id)" "0"
is "configuration files are root's, 644" \
  "$(stat -c '%U:%G %a' /etc/hostname /etc/profile /usr/lib/os-release | sort -u)" "root:root 644"

echo "== services"
is "systemd-networkd" "$(systemctl is-enabled systemd-networkd.service 2>&1)" "enabled"
is "systemd-resolved" "$(systemctl is-enabled systemd-resolved.service 2>&1)" "enabled"
is "systemd-timesyncd" "$(systemctl is-enabled systemd-timesyncd.service 2>&1)" "enabled"
is "no wait for the network at boot" "$(systemctl is-enabled systemd-networkd-wait-online.service 2>&1)" "disabled"
works "wired network configuration is installed" test -s /usr/lib/systemd/network/80-yvis-wired.network

echo "== locale, console, shell"
lang=$(. /etc/locale.conf && echo "$LANG")
is "/etc/locale.conf" "$lang" "en_US.UTF-8"
works "that locale is installed" sh -c "LC_ALL=$lang locale charmap | grep -qx UTF-8"
is "a login shell gets it from /etc/profile" "$(TERM=xterm bash -lc 'echo $LANG' 2>&1)" "$lang"
is "the Linux console gets C.UTF-8 (book 9.7)" "$(TERM=linux bash -lc 'echo $LANG' 2>&1)" "C.UTF-8"
font=$(. /etc/vconsole.conf && echo "$FONT")
works "console font $font exists" sh -c "ls /usr/share/consolefonts/$font.psf* "
for sh in $(grep '^/' /etc/shells); do works "/etc/shells: $sh is a shell" test -x "$sh"; done
works "/etc/inputrc" grep -q 'set bell-style none' /etc/inputrc

echo "== kernel"
kver=$(cat /.yvis/kernel-release 2>/dev/null)
m=/usr/lib/modules/$kver
works "kernel release $kver ends in -yvis" sh -c "case '$kver' in ?*-yvis) ;; *) false ;; esac"
works "/boot/vmlinuz-$kver is an x86 kernel image (bzImage)" \
  sh -c "file -b '/boot/vmlinuz-$kver' | grep 'Linux kernel x86 boot executable' | grep -q bzImage"
works "the image carries its release" sh -c "file -b '/boot/vmlinuz-$kver' | grep -q '$kver'"
works "same image in $m/vmlinuz" cmp -s "/boot/vmlinuz-$kver" "$m/vmlinuz"
works "/boot/System.map-$kver" test -s "/boot/System.map-$kver"
works "/boot/config-$kver has every required option" bash /.yvis/files/kernel/check-config.sh "/boot/config-$kver" /.yvis/files/kernel/required
works "module dependencies (depmod)" test -s "$m/modules.dep"
n=$(find "$m" -name '*.ko*' | wc -l)
if [ "$n" -ge 5000 ]; then ok "$n modules"; else bad "only $n modules (expected thousands)"; fi
is "modules are compressed with zstd" "$(find "$m" -name '*.ko*' | sed 's/.*\.ko//' | sort -u | tr '\n' ' ')" ".zst "
for mod in nvme ahci usb_storage xhci_hcd ext4 btrfs xfs vfat squashfs overlay loop isofs \
  i915 xe amdgpu nouveau snd_hda_intel e1000e r8169 iwlwifi bluetooth virtio_net; do
  works "driver $mod (module or built in)" modinfo -k "$kver" "$mod"
done
works "modules are signed" sh -c "modinfo -k '$kver' -F signer squashfs | grep -q ."
works "no link to the removed kernel sources" sh -c "! find '$m' -maxdepth 1 -type l | grep -q ."
works "what out-of-tree modules need is kept" test -s "$m/build/Module.symvers"

echo "== initramfs"
works "yvis-mkinitramfs is installed" test -x /usr/sbin/yvis-mkinitramfs
works "/boot/initramfs-$kver.img exists" test -s "/boot/initramfs-$kver.img"
works "it is a zstd archive" sh -c "file -b '/boot/initramfs-$kver.img' | grep -q 'Zstandard compressed data'"
is "it is readable by root only (it could hold keys one day)" "$(stat -c '%U %a' "/boot/initramfs-$kver.img")" "root 600"
listing=$(zstd -dc "/boot/initramfs-$kver.img" | python3 -c '
import sys
data = sys.stdin.buffer.read()
pos = 0
while pos < len(data):
    assert data[pos:pos + 6] == b"070701", "not a newc archive"
    f = [int(data[pos + 6 + i * 8:pos + 14 + i * 8], 16) for i in range(13)]
    name = data[pos + 110:pos + 110 + f[11] - 1].decode()
    if name == "TRAILER!!!":
        break
    print(name)
    pos = (pos + 110 + f[11] + 3) & ~3
    pos = (pos + f[6] + 3) & ~3
' 2>&1)
for f in init dev/console usr/bin/bash usr/bin/mount usr/sbin/switch_root usr/bin/udevadm \
  usr/lib/systemd/systemd-udevd usr/sbin/modprobe usr/lib/udev/rules.d/60-persistent-storage.rules \
  "usr/lib/modules/$kver/modules.dep" live/etc/motd; do
  works "holds /$f" grep -qx "$f" <<<"$listing"
done
works "holds Ventoy's record reader (vtoy-param)" grep -qx usr/lib/yvis/vtoy-param <<<"$listing"
works "the live session has the installer" grep -qx live/usr/lib/yvis/installer/yvis-installer <<<"$listing"
works "and its page" grep -qx live/usr/lib/yvis/installer/web/app.js <<<"$listing"
works "exFAT driver (Ventoy sticks keep the ISO there)" grep -Eq '/exfat\.ko' <<<"$listing"
works "NTFS driver (the other file system of Ventoy sticks)" grep -Eq '/ntfs3\.ko' <<<"$listing"
# udev opens libkmod at run time: without it, it loads no driver at all
works "holds libkmod, which udev needs to load drivers" grep -Eq '/libkmod\.so\.2$' <<<"$listing"
for mod in nvme ahci usb-storage xhci-pci sd_mod sr_mod squashfs overlay isofs loop btrfs xfs vfat virtio_blk; do
  # built into the kernel, or a module file in the image (- and _ are equivalent)
  pat=$(echo "$mod" | sed 's/[-_]/[-_]/g')
  if grep -Eq "/$pat\.ko" <<<"$listing" || grep -Eq "/$pat\.ko$" "$m/modules.builtin"; then
    ok "driver $mod is in the image or in the kernel"
  else
    bad "driver $mod is in the image or in the kernel"
  fi
done

echo
if [ "$fail" -eq 0 ]; then echo "verify-yvis: all checks passed"; else echo "verify-yvis: $fail check(s) FAILED"; fi
[ "$fail" -eq 0 ]
