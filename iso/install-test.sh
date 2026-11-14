#!/usr/bin/env bash
# Installs YVIS from the live ISO onto an empty virtual disk with the
# installer, then starts the installed system from that disk and checks it.
#
#   iso/install-test.sh <iso> [work directory] [uefi|bios ...]
#
# Like iso/boot-test.sh, nothing is added to the ISO: the test units reach
# the virtual machine as systemd credentials (SMBIOS strings) and report on
# the second serial port. Phase 1 boots the ISO with the empty disk and runs
# `yvis-installer --auto` (the same engine as the page); phase 2 boots the
# disk alone, through the boot loader the installer put there.
set -euo pipefail
iso=$(realpath "${1:?ISO file}")
work=${2:-$(mktemp -d)}
shift $(( $# >= 2 ? 2 : 1 ))
firmwares=("${@:-uefi}")
mkdir -p "$work"
work=$(realpath "$work")
ovmf=/usr/share/OVMF
limit=${YVIS_INSTALL_TIMEOUT:-2400}

# What a person would choose on the page, and the password they would type.
cat > "$work/choices.json" << 'EOF'
{"locale": "en_US.UTF-8", "keymap": "us", "timezone": "Europe/Paris",
 "hostname": "yvis-test", "disk": {"mode": "auto", "device": "/dev/vda"},
 "desktops": [], "profile": "minimal", "nvidia": false,
 "user": {"name": "tester", "fullname": "Install Test"}, "encrypt": false}
EOF

cat > "$work/install.sh" << 'EOF'
exec > /dev/ttyS1 2>&1
for _ in $(seq 1 150); do
  case $(systemctl is-system-running) in starting | initializing) sleep 2 ;; *) break ;; esac
done
echo
echo "YVIS-INSTALL start $(date -u +%T)"
YVIS_PASSWORD=yvis-test-password yvis-installer --auto "$CREDENTIALS_DIRECTORY/yvis.choices" --yes
echo "YVIS-INSTALL status=$?"
echo "YVIS-INSTALL end $(date -u +%T)"
systemctl poweroff
EOF

cat > "$work/check.sh" << 'EOF'
exec > /dev/ttyS1 2>&1
for _ in $(seq 1 150); do
  state=$(systemctl is-system-running)
  case $state in starting | initializing) sleep 2 ;; *) break ;; esac
done
echo
echo "YVIS-CHECK state=$state"
echo "YVIS-CHECK failed=$(systemctl --failed --no-legend --plain | awk '{ print $1 }' | tr '\n' ' ')"
echo "YVIS-CHECK os=$(. /etc/os-release && echo "$ID")"
echo "YVIS-CHECK firmware=$([ -d /sys/firmware/efi ] && echo uefi || echo bios)"
echo "YVIS-CHECK root=$(findmnt -no FSTYPE,SOURCE /)"
echo "YVIS-CHECK root-rw=$(findmnt -no OPTIONS / | grep -qw rw && echo yes)"
echo "YVIS-CHECK efi=$(findmnt -no FSTYPE /boot/efi 2> /dev/null)"
echo "YVIS-CHECK live=$([ -e /run/yvis/medium ] && echo yes || echo no)"
echo "YVIS-CHECK hostname=$(hostname)"
echo "YVIS-CHECK lang=$(. /etc/locale.conf && echo "$LANG")"
echo "YVIS-CHECK timezone=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
echo "YVIS-CHECK machine-id=$(grep -Eq '^[0-9a-f]{32}$' /etc/machine-id && echo new)"
echo "YVIS-CHECK user=$(id -nG tester 2> /dev/null | tr ' ' ',')"
echo "YVIS-CHECK home=$(stat -c %U /home/tester 2> /dev/null)"
echo "YVIS-CHECK sudo=$(sudo -l -U tester 2> /dev/null | grep -q '(ALL) ALL' && echo wheel)"
echo "YVIS-CHECK root-locked=$(passwd -S root 2> /dev/null | awk '{ print $2 }')"
echo "YVIS-CHECK no-autologin=$([ -e /etc/systemd/system/getty@tty1.service.d/autologin.conf ] && echo no || echo yes)"
echo "YVIS-CHECK installer-absent=$(command -v yvis-installer > /dev/null && echo no || echo yes)"
echo "YVIS-CHECK choices=$(tr -d ' \n' < /etc/yvis/install.json)"
dmesg -l emerg,alert,crit,err | sed 's/^/YVIS-CHECK dmesg: /' | head -n 20
echo "YVIS-CHECK-END"
systemctl poweroff
EOF

unit() { # credential name of the script
  printf '[Unit]\nDescription=YVIS install test\nConditionPathExists=!/etc/initrd-release\n\n'
  printf '[Service]\nType=simple\nLoadCredential=%s\nLoadCredential=yvis.choices\n' "$1"
  printf 'ExecStart=/usr/bin/bash ${CREDENTIALS_DIRECTORY}/%s\n' "$1"
}
cred() { echo "type=11,value=io.systemd.credential.binary:$1=$(base64 -w0 "$2")"; }
unit yvis.install > "$work/install.unit"
unit yvis.check > "$work/check.unit"
printf '[Unit]\nWants=t.service\n' > "$work/dropin"

machine() { # firmware name -> QEMU options
  if [ "$1" = uefi ]; then
    echo -machine q35
    echo -drive "if=pflash,format=raw,readonly=on,file=$ovmf/OVMF_CODE_4M.fd"
    echo -drive "if=pflash,format=raw,file=$work/$1.vars"
  fi
}

run() { # firmware phase report qemu-options...
  local fw=$1 phase=$2 report=$3 rc=0
  shift 3
  : > "$report"
  mapfile -t m < <(machine "$fw")
  timeout "$limit" qemu-system-x86_64 -accel tcg,thread=multi -cpu qemu64 -smp 4 -m 3072 "${m[@]}" "$@" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -display none -serial "file:$work/$fw-$phase.console" -serial "file:$report" -no-reboot \
    > "$work/$fw-$phase.qemu" 2>&1 || rc=$?
  sed -i 's/\r$//' "$report"
  return $rc
}

fail=0
for fw in "${firmwares[@]}"; do
  echo "==> $fw: install onto an empty disk"
  [ "$fw" = bios ] || cp "$ovmf/OVMF_VARS_4M.fd" "$work/$fw.vars"
  disk=$work/$fw-disk.qcow2
  rm -f "$disk"
  qemu-img create -q -f qcow2 "$disk" 24G
  rc=0
  run "$fw" install "$work/$fw-install.report" \
    -drive "file=$iso,media=cdrom,readonly=on" -boot d \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -smbios "$(cred systemd.extra-unit.t.service "$work/install.unit")" \
    -smbios "$(cred systemd.unit-dropin.multi-user.target "$work/dropin")" \
    -smbios "$(cred yvis.install "$work/install.sh")" \
    -smbios "$(cred yvis.choices "$work/choices.json")" || rc=$?
  grep -a -E '^(YVIS-INSTALL|!!|   [A-Z]|==>|yvis-installer)' "$work/$fw-install.report" | cut -c1-160 || true
  if ! grep -aqx 'YVIS-INSTALL status=0' "$work/$fw-install.report"; then
    echo "  FAIL  the installer did not finish (QEMU status $rc)"
    tail -n 30 "$work/$fw-install.report" | sed 's/^/  | /'
    tail -n 20 "$work/$fw-install.console" 2> /dev/null | tr -d '\r' | sed 's/^/  | console: /'
    sed 's/^/  | qemu: /' "$work/$fw-install.qemu" | head -n 10
    fail=$((fail + 1))
    continue
  fi
  echo "  ok    installed"

  echo "==> $fw: start the installed system from its disk"
  rc=0
  run "$fw" boot "$work/$fw-boot.report" \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -smbios "$(cred systemd.extra-unit.t.service "$work/check.unit")" \
    -smbios "$(cred systemd.unit-dropin.multi-user.target "$work/dropin")" \
    -smbios "$(cred yvis.check "$work/check.sh")" \
    -smbios "$(cred yvis.choices "$work/choices.json")" || rc=$?
  r=$work/$fw-boot.report
  grep -a '^YVIS-CHECK' "$r" | cut -c1-200 || true
  bad=0
  check() { if grep -aqE "$2" "$r"; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }
  check "the installed system started and the test ran to its end" '^YVIS-CHECK-END$'
  check "every unit started" '^YVIS-CHECK state=running$'
  check "no failed unit" '^YVIS-CHECK failed=$'
  check "it is YVIS" '^YVIS-CHECK os=yvis$'
  check "started by $fw firmware" "^YVIS-CHECK firmware=$fw\$"
  check "from the disk, ext4" '^YVIS-CHECK root=ext4 /dev/vda[0-9]+$'
  check "the root is writable" '^YVIS-CHECK root-rw=yes$'
  [ "$fw" = bios ] || check "the EFI partition is mounted" '^YVIS-CHECK efi=vfat$'
  check "not the live system" '^YVIS-CHECK live=no$'
  check "the chosen computer name" '^YVIS-CHECK hostname=yvis-test$'
  check "the chosen language" '^YVIS-CHECK lang=en_US.UTF-8$'
  check "the chosen time zone" '^YVIS-CHECK timezone=Europe/Paris$'
  check "its own machine id, created at the first start" '^YVIS-CHECK machine-id=new$'
  check "the user, in the wheel group" '^YVIS-CHECK user=tester,.*wheel'
  check "with a home of their own" '^YVIS-CHECK home=tester$'
  check "who may administer with sudo" '^YVIS-CHECK sudo=wheel$'
  check "root cannot log in with a password" '^YVIS-CHECK root-locked=L$'
  check "no automatic login (that was the live session's)" '^YVIS-CHECK no-autologin=yes$'
  check "no installer on the installed system" '^YVIS-CHECK installer-absent=yes$'
  check "the choices are recorded" '^YVIS-CHECK choices=.*"profile":"minimal"'
  [ "$rc" -eq 0 ] || { echo "  FAIL  QEMU ended with status $rc (124: time limit)"; bad=$((bad + 1)); }
  if [ "$bad" -ne 0 ]; then
    tail -n 40 "$work/$fw-boot.console" 2> /dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/^/  | /'
    echo "  $fw: $bad check(s) FAILED"
    fail=$((fail + 1))
  fi
done
echo
if [ "$fail" -eq 0 ]; then echo "install test: every installation passed"; else echo "install test: $fail FAILED"; fi
[ "$fail" -eq 0 ]
