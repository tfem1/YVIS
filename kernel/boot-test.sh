#!/usr/bin/env bash
# Boots the built system in QEMU and checks what only a running system can
# show: the kernel starts, systemd reaches its target with no failed unit,
# modules load (compressed, signed), the wired network gets its address.
# The report is read back from the disk image after the machine powers off.
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
img=$work/graveyard-test.img mnt=$work/mnt out=$work/serial.log
kver=$(cat "$LFS/.graveyard/kernel-release")
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
command -v qemu-system-x86_64 > /dev/null || { echo "qemu-system-x86_64 is not installed" >&2; exit 1; }

echo "==> disk image of the system ($kver)"
mkdir -p "$mnt"
need=$(du -sxm --exclude=sources --exclude=.graveyard "$LFS" | cut -f1)
truncate -s "$((need + 1024))M" "$img"
mkfs.ext4 -q -F -L graveyard-test "$img"
mount -o loop "$img" "$mnt"
trap 'umount "$mnt" 2>/dev/null || true' EXIT
tar -C "$LFS" --one-file-system --numeric-owner --xattrs --xattrs-include='*' --acls \
  --exclude=./sources --exclude=./.graveyard -cpf - . |
  tar -C "$mnt" --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -

# The test: only in the image. Type=simple so that it does not hold the
# boot back; it waits for the boot to finish, writes its report to a file
# of the image and powers the machine off. (Not to the serial line: the
# login service started there resets it, and what follows is lost.)
cat > "$mnt/usr/local/sbin/graveyard-boot-test" <<'TEST'
#!/bin/bash
exec > /var/log/graveyard-boot-test 2>&1
for _ in $(seq 1 150); do
  state=$(systemctl is-system-running)
  case $state in starting | initializing) sleep 2 ;; *) break ;; esac
done
echo "GRAVEYARD-TEST state=$state"
echo "GRAVEYARD-TEST kernel=$(uname -r)"
echo "GRAVEYARD-TEST os=$(. /etc/os-release && echo "$ID")"
echo "GRAVEYARD-TEST hostname=$(hostname)"
echo "GRAVEYARD-TEST failed=$(systemctl --failed --no-legend --plain | awk '{ print $1 }' | tr '\n' ' ')"
echo "GRAVEYARD-TEST machine-id=$(wc -c < /etc/machine-id)"
for m in squashfs overlay loop isofs vfat nvme usb_storage btrfs; do
  if modprobe "$m"; then echo "GRAVEYARD-TEST module $m=ok"; else echo "GRAVEYARD-TEST module $m=FAILED"; fi
done
for _ in $(seq 1 45); do
  ip -4 -o addr show scope global | grep -q . && break
  sleep 1
done
echo "GRAVEYARD-TEST ipv4=$(ip -4 -o addr show scope global | awk '{ print $2 ":" $4 }' | tr '\n' ' ')"
echo "GRAVEYARD-TEST dns=$(resolvectl dns 2> /dev/null | grep -cE '([0-9]+\.){3}[0-9]+')"
echo "GRAVEYARD-TEST cpu=$(sed -n 's/^model name\s*: //p' /proc/cpuinfo | head -n 1)"
dmesg -l emerg,alert,crit,err | sed 's/^/GRAVEYARD-TEST dmesg: /' | head -n 40
echo "GRAVEYARD-TEST-END"
sync
systemctl poweroff
TEST
chmod 755 "$mnt/usr/local/sbin/graveyard-boot-test"
cat > "$mnt/etc/systemd/system/graveyard-boot-test.service" <<'UNIT'
[Unit]
Description=GraveyardOS boot test (test image only)

[Service]
Type=simple
ExecStart=/usr/local/sbin/graveyard-boot-test

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$mnt/etc/systemd/system/multi-user.target.wants"
ln -s ../graveyard-boot-test.service "$mnt/etc/systemd/system/multi-user.target.wants/graveyard-boot-test.service"
umount "$mnt"
trap - EXIT

echo "==> booting (emulated plain x86-64 CPU; a few minutes)"
rc=0
timeout "${GRAVEYARD_BOOT_TIMEOUT:-1500}" qemu-system-x86_64 \
  -accel tcg,thread=multi -cpu qemu64 -smp 4 -m 3072 \
  -kernel "$LFS/boot/vmlinuz-$kver" \
  -append "root=/dev/vda rw console=ttyS0,115200 panic=-1 systemd.show_status=1" \
  -drive "file=$img,if=virtio,format=raw" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:$out" -no-reboot > /dev/null 2>&1 || rc=$?
tr -d '\r' < "$out" > "$out.txt"
report=$work/report.txt
: > "$report"
mount -o loop,ro "$img" "$mnt"
cp "$mnt/var/log/graveyard-boot-test" "$report" 2>/dev/null || true
umount "$mnt"

echo "==> result"
cat "$report"
echo "---- units systemd reported as failed on the console: $(grep -ac '^\[FAILED\]' "$out.txt")"
grep -a '^\[FAILED\]' "$out.txt" | cut -c1-160 || true
fail=0
check() { # description, pattern
  if grep -aqE "$2" "$report"; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}
check "the system booted and the test ran to its end" '^GRAVEYARD-TEST-END$'
check "kernel $kver" "^GRAVEYARD-TEST kernel=$kver\$"
check "systemd reached its target with every unit started" '^GRAVEYARD-TEST state=running$'
check "no failed unit" '^GRAVEYARD-TEST failed=$'
check "it is GraveyardOS, named graveyard" '^GRAVEYARD-TEST os=graveyard$'
check "the machine got its own identifier at first boot" '^GRAVEYARD-TEST machine-id=33$'
check "modules load (squashfs, overlay, loop, isofs, vfat, nvme, usb_storage, btrfs)" '^GRAVEYARD-TEST module btrfs=ok$'
if grep -aq 'module .*=FAILED' "$report"; then echo "  FAIL  a module did not load"; fail=$((fail + 1)); fi
check "the wired network got an IPv4 address by DHCP" '^GRAVEYARD-TEST ipv4=[a-z0-9]+:10\.0\.2\.'
check "a DNS server was received" '^GRAVEYARD-TEST dns=[1-9]'
if grep -aq 'reboot: Power down' "$out.txt"; then echo "  ok    the system powered itself off"; else
  echo "  FAIL  the system powered itself off"; fail=$((fail + 1)); fi
[ "$rc" -eq 0 ] || { echo "  FAIL  QEMU ended with status $rc (124: time limit)"; fail=$((fail + 1)); }
if [ "$fail" -ne 0 ]; then
  echo "---- last 80 lines of the serial console"
  tail -n 80 "$out.txt" | cut -c1-200
  echo "boot test: $fail check(s) FAILED"
  exit 1
fi
echo "boot test: all checks passed"
