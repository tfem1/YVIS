#!/usr/bin/env bash
# Boots the live ISO in QEMU the way a PC would and checks the running
# system: from a disc and from a USB stick, with BIOS and with UEFI firmware.
#
#   iso/boot-test.sh <iso> [work directory]       needs qemu-system-x86, ovmf
#
# The ISO is booted as it is, through its own boot menu. The test is not on
# it: a systemd unit and its script are handed to the virtual machine as
# system credentials (SMBIOS strings, see systemd.system-credentials(7)),
# and the unit reports on the second serial port.
# The CPU is QEMU's plain x86-64 one, emulated.
set -euo pipefail
iso=${1:?ISO file}
work=${2:-$(mktemp -d)}
mkdir -p "$work"
command -v qemu-system-x86_64 > /dev/null || { echo "qemu-system-x86_64 is not installed" >&2; exit 1; }
ovmf=/usr/share/OVMF
[ -s "$ovmf/OVMF_CODE_4M.fd" ] || { echo "OVMF firmware not found in $ovmf (package ovmf)" >&2; exit 1; }
label=$(xorriso -indev "$iso" -pvd_info 2> /dev/null | sed -n 's/^Volume Id *: *//p')
[ -n "$label" ] || { echo "cannot read the volume label of $iso" >&2; exit 1; }

cat > "$work/test.sh" <<'TEST'
exec > /dev/ttyS1 2>&1
for _ in $(seq 1 150); do
  state=$(systemctl is-system-running)
  case $state in starting | initializing) sleep 2 ;; *) break ;; esac
done
echo   # UEFI firmware and GRUB write to this port too, without ending their last line
echo "YVIS-TEST state=$state"
echo "YVIS-TEST failed=$(systemctl --failed --no-legend --plain | awk '{ print $1 }' | tr '\n' ' ')"
echo "YVIS-TEST kernel=$(uname -r)"
echo "YVIS-TEST os=$(. /etc/os-release && echo "$ID")"
echo "YVIS-TEST firmware=$([ -d /sys/firmware/efi ] && echo uefi || echo bios)"
echo "YVIS-TEST cmdline=$(cat /proc/cmdline)"
echo "YVIS-TEST root=$(findmnt -no FSTYPE,SOURCE /)"
echo "YVIS-TEST medium=$(findmnt -no FSTYPE /run/yvis/medium)"
echo "YVIS-TEST system=$(findmnt -no FSTYPE /run/yvis/system)"
echo "YVIS-TEST writable=$(touch /root/written-by-the-test && echo yes || echo no)"
echo "YVIS-TEST medium-untouched=$(touch /run/yvis/medium/x 2> /dev/null && echo no || echo yes)"
# the automatic login: root's shell on the first console
for _ in $(seq 1 30); do pgrep -t tty1 -u root -x bash > /dev/null && break; sleep 1; done
echo "YVIS-TEST login=$(pgrep -t tty1 -u root -x bash > /dev/null && echo root@tty1)"
for _ in $(seq 1 45); do
  ip -4 -o addr show scope global | grep -q . && break
  sleep 1
done
echo "YVIS-TEST ipv4=$(ip -4 -o addr show scope global | awk '{ print $4 }' | tr '\n' ' ')"
echo "YVIS-TEST memory=$(awk '/MemTotal/ { t = $2 } /MemAvailable/ { a = $2 } END { printf "%d MiB used of %d", (t - a) / 1024, t / 1024 }' /proc/meminfo)"
dmesg -l emerg,alert,crit,err | sed 's/^/YVIS-TEST dmesg: /' | head -n 30
echo "YVIS-TEST-END"
systemctl poweroff
TEST
cat > "$work/unit" <<'UNIT'
[Unit]
Description=YVIS live boot test (injected by iso/boot-test.sh)
ConditionPathExists=!/etc/initrd-release

[Service]
Type=simple
LoadCredential=yvis.boot-test
ExecStart=/usr/bin/bash ${CREDENTIALS_DIRECTORY}/yvis.boot-test
UNIT
printf '[Unit]\nWants=t.service\n' > "$work/dropin"
cred() { echo "type=11,value=io.systemd.credential.binary:$1=$(base64 -w0 "$2")"; }
credentials=(
  -smbios "$(cred systemd.extra-unit.t.service "$work/unit")"
  -smbios "$(cred systemd.unit-dropin.multi-user.target "$work/dropin")"
  -smbios "$(cred yvis.boot-test "$work/test.sh")"
)

fail=0
boot() { # name: bios-disc | bios-usb | uefi-disc | uefi-usb
  local name=$1 fw=${1%-*} medium=${1#*-} report=$work/$1.report rc=0
  local machine=() drive=()
  if [ "$fw" = uefi ]; then
    cp "$ovmf/OVMF_VARS_4M.fd" "$work/$name.vars"
    machine=(-machine q35
      -drive "if=pflash,format=raw,readonly=on,file=$ovmf/OVMF_CODE_4M.fd"
      -drive "if=pflash,format=raw,file=$work/$name.vars")
  fi
  if [ "$medium" = usb ]; then
    drive=(-device qemu-xhci -drive "if=none,id=stick,file=$iso,format=raw,readonly=on"
      -device "usb-storage,drive=stick,bootindex=1")
  else
    drive=(-drive "file=$iso,media=cdrom,readonly=on")
  fi
  echo "==> $name"
  : > "$report"
  timeout "${YVIS_BOOT_TIMEOUT:-900}" qemu-system-x86_64 \
    -accel tcg,thread=multi -cpu qemu64 -smp 4 -m 3072 "${machine[@]}" "${drive[@]}" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    "${credentials[@]}" \
    -display none -serial "file:$work/$name.console" -serial "file:$report" -no-reboot \
    > /dev/null 2>&1 || rc=$?
  sed -i 's/\r$//' "$report"
  grep -a '^YVIS-TEST' "$report" | cut -c1-200 || true
  local bad=0
  check() { # description, pattern
    if grep -aqE "$2" "$report"; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi
  }
  check "the live system booted and the test ran to its end" '^YVIS-TEST-END$'
  check "systemd reached its target with every unit started" '^YVIS-TEST state=running$'
  check "no failed unit" '^YVIS-TEST failed=$'
  check "it is YVIS" '^YVIS-TEST os=yvis$'
  check "booted by $fw firmware" "^YVIS-TEST firmware=$fw\$"
  check "from the medium's own menu entry" "^YVIS-TEST cmdline=BOOT_IMAGE=/boot/vmlinuz yvis.live=$label\$"
  check "the root is the live overlay" '^YVIS-TEST root=overlay yvis-live$'
  check "over the read-only system image" '^YVIS-TEST system=squashfs$'
  check "on the ISO file system" '^YVIS-TEST medium=iso9660$'
  check "the session can write" '^YVIS-TEST writable=yes$'
  check "but not to the medium" '^YVIS-TEST medium-untouched=yes$'
  check "root is logged in on the first console" '^YVIS-TEST login=root@tty1$'
  check "the network got an address by DHCP" '^YVIS-TEST ipv4=10\.0\.2\.'
  [ "$rc" -eq 0 ] || { echo "  FAIL  QEMU ended with status $rc (124: time limit)"; bad=$((bad + 1)); }
  if [ "$bad" -ne 0 ]; then
    echo "  $name: $bad check(s) FAILED"
    fail=$((fail + 1))
  fi
}

for name in ${YVIS_BOOT_CASES:-bios-disc uefi-disc bios-usb uefi-usb}; do boot "$name"; done

if [ "$fail" -ne 0 ]; then
  # The menu gives the kernel no serial console, so the failed boots said
  # nothing: boot the medium's kernel directly with one, for its messages.
  echo "==> diagnosis: the same medium, kernel started directly with a serial console"
  mkdir -p "$work/files"
  xorriso -osirrox on -indev "$iso" -extract /boot/vmlinuz "$work/files/vmlinuz" \
    -extract /boot/initramfs.img "$work/files/initramfs.img" > /dev/null 2>&1 || true
  timeout 420 qemu-system-x86_64 -accel tcg,thread=multi -cpu qemu64 -smp 4 -m 3072 \
    -kernel "$work/files/vmlinuz" -initrd "$work/files/initramfs.img" \
    -append "yvis.live=$label console=ttyS0,115200 systemd.show_status=1" \
    -drive "file=$iso,media=cdrom,readonly=on" "${credentials[@]}" \
    -display none -serial "file:$work/diagnosis.console" -serial "file:$work/diagnosis.report" -no-reboot \
    > /dev/null 2>&1 || true
  sed 's/\r$//; s/\x1b\[[0-9;?]*[a-zA-Z]//g' "$work/diagnosis.console" | grep -av '^$' | tail -n 70 | cut -c1-200
  echo "---- its report"; cut -c1-200 "$work/diagnosis.report" || true
  echo "ISO boot test: $fail of the boots FAILED"
  exit 1
fi
echo "ISO boot test: all boots passed"
