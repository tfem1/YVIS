#!/bin/sh
# Tests for tools/graveyard-gpu-detect against fake sysfs trees.
set -eu
D=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
n=0
ok() { n=$((n + 1)); echo "  ✓ $*"; }
die() { echo "  ✗ $*"; exit 1; }

card() { # root slot class vendor device [driver]
  p=$1/bus/pci/devices/$2; mkdir -p "$p"
  echo "$3" > "$p/class"; echo "0x$4" > "$p/vendor"; echo "0x$5" > "$p/device"
  if [ -n "${6:-}" ]; then mkdir -p "$1/bus/pci/drivers/$6"; ln -s "../../drivers/$6" "$p/driver"; fi
}
run() { "$D/graveyard-gpu-detect" --sysfs "$1" --ids "${2:-/nonexistent}"; }

card "$T/rtx4070" 0000:01:00.0 0x030000 10de 2786 nouveau
card "$T/rtx4070" 0000:01:00.1 0x040300 10de 22bc            # its HDMI audio: ignored
out=$(run "$T/rtx4070") || die "RTX 4070 should exit 0"
echo "$out" | grep -qx nvidia=open && echo "$out" | grep -qx hybrid=no && ok "desktop RTX 4070: open modules"
echo "$out" | grep -qx gpu=10de:2786:nouveau && [ "$(echo "$out" | grep -c ^gpu=)" = 1 ] && ok "only display controllers listed, driver in use shown"

card "$T/laptop" 0000:00:02.0 0x030000 8086 a7a0 i915
card "$T/laptop" 0000:01:00.0 0x030200 10de 2520             # 3D controller class
out=$(run "$T/laptop") || die "laptop should exit 0"
echo "$out" | grep -qx hybrid=yes && ok "Intel + RTX 3060 laptop: hybrid (PRIME)"

card "$T/gtx1080" 0000:01:00.0 0x030000 10de 1b80
if out=$(run "$T/gtx1080"); then die "GTX 1080 must not exit 0"; fi
echo "$out" | grep -qx nvidia=unsupported && ok "GTX 1080 (Pascal): unsupported, stays on nouveau"

card "$T/v100" 0000:01:00.0 0x030200 10de 1db4
run "$T/v100" | grep -qx nvidia=unsupported && ok "Tesla V100 (Volta): unsupported"

card "$T/gtx1650" 0000:01:00.0 0x030000 10de 1f82
run "$T/gtx1650" | grep -qx nvidia=open && ok "GTX 1650 (Turing): open modules"

card "$T/amd" 0000:03:00.0 0x030000 1002 744c amdgpu
if out=$(run "$T/amd"); then die "AMD only must not exit 0"; fi
echo "$out" | grep -qx nvidia=none && echo "$out" | grep -qx hybrid=no && ok "AMD only: no NVIDIA"

printf '2786\n' > "$T/ids"
run "$T/rtx4070" "$T/ids" | grep -qx nvidia=open && ok "id list from the driver is used when present"
if run "$T/gtx1650" "$T/ids" >/dev/null; then die "id list must override the heuristic"; fi
ok "a GPU missing from the driver's list is not selected"

mkdir -p "$T/empty"
run "$T/empty" | grep -qx nvidia=none && ok "no PCI devices at all (VM without GPU)"

want=$(grep -cE '(^|[;&|] *)ok "' "$0")
[ "$n" -eq "$want" ] || die "only $n of $want checks passed"
echo "all $n checks passed"
