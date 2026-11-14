#!/usr/bin/env bash
# Yone with an Arch-sized repository: N linked packages (default 6000),
# built, indexed, installed, listed, upgraded and removed, with times.
#
#   yone/tests/scale.sh [N]      needs a built yone (cargo build --release)
set -euo pipefail
N=${1:-6000}
HERE=$(cd "$(dirname "$0")" && pwd)
Y=${YONE:-$HERE/../target/release/yone}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
"$Y" keygen keys/k > /dev/null
python3 - "$N" << 'PY'
import os, random, sys
random.seed(1)
n = int(sys.argv[1])
for i in range(n):
    name = f"pkg{i:05d}"
    k = min(i, random.choice([0, 1, 2, 3, 5, 8]))
    deps = [f"pkg{j:05d}" for j in random.sample(range(max(0, i - 400), i), k)]
    os.makedirs(f"r/{name}")
    with open(f"r/{name}/YONEBUILD", "w") as f:
        f.write(f"name = {name}\nversion = 1.{i % 7}\ndesc = synthetic package {i}\n")
        if deps:
            f.write("depends = " + " ".join(deps) + "\n")
        f.write(f'@package\nmkdir -p "$PKGDIR/usr/share/scale/{name}"\necho {name} > "$PKGDIR/usr/share/scale/{name}/file"\n')
PY
t() { local s; s=$(date +%s%N); "$@" > last.out 2>&1 || { echo "FAILED: $label"; tail last.out; exit 1; }
      printf '%-36s %8.2f s\n' "$label" "$(( $(date +%s%N) - s ))e-9"; }
label="build $N packages (8 at a time)"; t sh -c "ls r | xargs -P 8 -I{} '$Y' build r/{} --out repo --compress zstd --color never"
label="repo-index"; t "$Y" repo-index repo --name core --sign keys/k.key --color never
R=$T/root; mkdir -p "$R/etc/yone/keys"; cp keys/k.pub.pem "$R/etc/yone/keys/"
printf '[options]\nsiglevel = required\n\n[core]\nserver = file://%s/repo\n' "$T" > "$R/etc/yone/yone.conf"
Yr=("$Y" --root "$R" --noconfirm --color never)
last=$(printf 'pkg%05d' $((N - 1)))
label="update"; t "${Yr[@]}" update
label="search"; t "${Yr[@]}" search "package 59"
label="install $last and its dependencies"; t "${Yr[@]}" install "$last"
echo "   $("${Yr[@]}" list | wc -l) packages installed"
mapfile -t all < <(ls r)
label="install the rest"; t "${Yr[@]}" install "${all[@]}"
label="list"; t "${Yr[@]}" list
label="verify"; t "${Yr[@]}" verify
label="upgrade (nothing to do)"; t "${Yr[@]}" upgrade
k=$(( N < 3000 ? N / 3 : 1000 ))
label="remove $k"; t "${Yr[@]}" remove "${all[@]: -k}"
echo "   $("${Yr[@]}" list | wc -l) packages installed"
