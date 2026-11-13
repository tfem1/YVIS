#!/usr/bin/env bash
# Boots the built system in QEMU and checks what only a running system can
# show: the kernel starts, systemd reaches its target with no failed unit,
# modules load (compressed, signed), the wired network gets its address.
#
#   sudo kernel/boot-test.sh [work directory]      needs $LFS, qemu-system-x86
#
# The system is copied to a disk image; the test service is added to the
# copy only. No initramfs: the kernel has ext4 and virtio-blk built in.
# The virtual CPU is QEMU's plain x86-64 one, emulated, so an instruction
# that older processors lack makes the test fail instead of going unnoticed.
set -euo pipefail
LFS=${LFS:-/mnt/lfs}
work=${1:-$(mktemp -d)}
img=$work/yvis-test.img mnt=$work/mnt out=$work/serial.log
kver=$(cat "$LFS/.yvis/kernel-release")
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
command -v qemu-system-x86_64 > /dev/null || { echo "qemu-system-x86_64 is not installed" >&2; exit 1; }

echo "==> disk image of the system ($kver)"
mkdir -p "$mnt"
need=$(du -sxm --exclude=sources --exclude=.yvis "$LFS" | cut -f1)
truncate -s "$((need + 1024))M" "$img"
mkfs.ext4 -q -F -L yvis-test "$img"
mount -o loop "$img" "$mnt"
trap 'umount "$mnt" 2>/dev/null || true' EXIT
tar -C "$LFS" --one-file-system --numeric-owner --xattrs --xattrs-include='*' --acls \
  --exclude=./sources --exclude=./.yvis -cpf - . |
  tar -C "$mnt" --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -

# The test: only in the image. Type=simple so that it does not hold the
# boot back; it waits for the boot to finish, reports on the serial line
# and powers the machine off.
cat > "$mnt/usr/local/sbin/yvis-boot-test" <<'TEST'
#!/bin/bash
exec > /dev/ttyS0 2>&1
for _ in $(seq 1 150); do
  state=$(systemctl is-system-running)
  case $state in starting | initializing) sleep 2 ;; *) break ;; esac
done
echo "YVIS-TEST state=$state"
echo "YVIS-TEST kernel=$(uname -r)"
echo "YVIS-TEST os=$(. /etc/os-release && echo "$ID")"
echo "YVIS-TEST hostname=$(hostname)"
echo "YVIS-TEST failed=$(systemctl --failed --no-legend --plain | awk '{ print $1 }' | tr '\n' ' ')"
echo "YVIS-TEST machine-id=$(wc -c < /etc/machine-id)"
for m in squashfs overlay loop isofs vfat nvme usb_storage btrfs; do
  if modprobe "$m"; then echo "YVIS-TEST module $m=ok"; else echo "YVIS-TEST module $m=FAILED"; fi
done
for _ in $(seq 1 45); do
  ip -4 -o addr show scope global | grep -q . && break
  sleep 1
done
echo "YVIS-TEST ipv4=$(ip -4 -o addr show scope global | awk '{ print $2 ":" $4 }' | tr '\n' ' ')"
echo "YVIS-TEST dns=$(resolvectl dns 2> /dev/null | grep -cE '([0-9]+\.){3}[0-9]+')"
echo "YVIS-TEST cpu=$(sed -n 's/^model name\s*: //p' /proc/cpuinfo | head -n 1)"
dmesg -l emerg,alert,crit,err | sed 's/^/YVIS-TEST dmesg: /' | head -n 40
echo "YVIS-TEST-END"
systemctl poweroff
TEST
chmod 755 "$mnt/usr/local/sbin/yvis-boot-test"
cat > "$mnt/etc/systemd/system/yvis-boot-test.service" <<'UNIT'
[Unit]
Description=YVIS boot test (test image only)

[Service]
Type=simple
ExecStart=/usr/local/sbin/yvis-boot-test

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$mnt/etc/systemd/system/multi-user.target.wants"
ln -s ../yvis-boot-test.service "$mnt/etc/systemd/system/multi-user.target.wants/yvis-boot-test.service"
umount "$mnt"
trap - EXIT

echo "==> booting (emulated plain x86-64 CPU; a few minutes)"
rc=0
timeout "${YVIS_BOOT_TIMEOUT:-1500}" qemu-system-x86_64 \
  -accel tcg,thread=multi -cpu qemu64 -smp 4 -m 3072 \
  -kernel "$LFS/boot/vmlinuz-$kver" \
  -append "root=/dev/vda rw console=ttyS0,115200 panic=-1 systemd.show_status=1" \
  -drive "file=$img,if=virtio,format=raw" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:$out" -no-reboot > /dev/null 2>&1 || rc=$?
tr -d '\r' < "$out" > "$out.txt"

echo "==> result"
grep -a '^YVIS-TEST' "$out.txt" || true
fail=0
check() { # description, pattern
  if grep -aqE "$2" "$out.txt"; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}
check "the system booted and the test ran to its end" '^YVIS-TEST-END$'
check "kernel $kver" "^YVIS-TEST kernel=$kver\$"
check "systemd reached its target with every unit started" '^YVIS-TEST state=running$'
check "no failed unit" '^YVIS-TEST failed=$'
check "it is YVIS, named yvis" '^YVIS-TEST os=yvis$'
check "the machine got its own identifier at first boot" '^YVIS-TEST machine-id=33$'
check "modules load (squashfs, overlay, loop, isofs, vfat, nvme, usb_storage, btrfs)" '^YVIS-TEST module btrfs=ok$'
if grep -aq 'module .*=FAILED' "$out.txt"; then echo "  FAIL  a module did not load"; fail=$((fail + 1)); fi
check "the wired network got an IPv4 address by DHCP" '^YVIS-TEST ipv4=[a-z0-9]+:10\.0\.2\.'
check "a DNS server was received" '^YVIS-TEST dns=[1-9]'
check "QEMU powered off by itself" '^YVIS-TEST-END$'
[ "$rc" -eq 0 ] || { echo "  FAIL  QEMU ended with status $rc (124: time limit)"; fail=$((fail + 1)); }
if [ "$fail" -ne 0 ]; then
  echo "---- last 80 lines of the serial console"
  tail -n 80 "$out.txt" | cut -c1-200
  echo "boot test: $fail check(s) FAILED"
  exit 1
fi
echo "boot test: all checks passed"
