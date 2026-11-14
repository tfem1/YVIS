#!/usr/bin/env bash
# Build the base packages inside the chapter 8 system, then install them
# into an empty root.
#
#   sudo packages/build-all.sh <reference> <recipes> <sources> <work> [package ...]
#
#   reference  the built system ($LFS of an `lfs`/`graveyard-base` run): its
#              toolchain builds the packages; it is never modified
#   recipes    output of packages/gen-base.py
#   sources    the source tarballs (lfs/fetch-sources.sh)
#   work       where everything goes: the overlay, the repository, logs
#
# The reference is mounted read-only under an overlay: a recipe that writes
# anywhere but $PKGDIR is caught (the overlay's upper layer shows every
# change) and reported as a stray write, and the reference stays the clean
# baseline packages/compare.py compares the installed result with.
# Named packages: build only those, nothing is installed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
ref=$(realpath "${1:?reference}") recipes=$(realpath "${2:?recipes}")
sources=$(realpath "${3:?sources}") work=${4:?work directory}
shift 4
only=("$@")
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
yone=${YONE:-$(command -v yone || true)}
[ -x "$yone" ] || { echo "a static yone binary is needed (YONE=...)" >&2; exit 1; }
log() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }

mkdir -p "$work"
work=$(realpath "$work")
upper=$work/upper lower_work=$work/overlay-work root=$work/root
mkdir -p "$upper" "$lower_work" "$root" "$work/logs"

log "overlay over the reference system"
mountpoint -q "$root" || mount -t overlay overlay -o "lowerdir=$ref,upperdir=$upper,workdir=$lower_work" "$root"
LFS=$root bash "$REPO/lfs/build.sh" mount > /dev/null
cleanup() {
  LFS=$root bash "$REPO/lfs/build.sh" umount > /dev/null 2>&1 || true
  umount "$root" 2> /dev/null || umount -l "$root" 2> /dev/null || true
}
trap cleanup EXIT

install -m 755 "$yone" "$root/usr/local/bin/yone"
rm -rf "$root/packages"
mkdir -p "$root/packages/repo" "$root/packages/logs"
cp -R "$recipes" "$root/packages/recipes"
[ -s "$root/packages/key.key" ] || chroot "$root" /usr/local/bin/yone keygen /packages/key > /dev/null 2>&1

mapfile -t order < <(if [ ${#only[@]} -gt 0 ]; then printf '%s\n' "${only[@]}"; else cat "$recipes/order"; fi)

# every source a recipe names, where yone looks for it first (no download)
for name in "${order[@]}"; do
  d=$root/packages/recipes/$name
  for f in $(sed -n 's|^source = .*/||p' "$d/YONEBUILD" 2> /dev/null); do
    mkdir -p "$d/.yone-sources"
    cp "$sources/$f" "$d/.yone-sources/$f"
  done
done
# What the build machine may change: the build area, temporary files, and
# the shared library cache (the install rules of zlib and e2fsprogs run
# ldconfig; the cache is rebuilt on the installed system by a hook).
allowed='^(packages|tmp|var/tmp|root|dev|run|proc|sys|var/cache/ldconfig)(/|$)|^etc/ld\.so\.cache$'
failed=() stray=()
for name in "${order[@]}"; do
  [ -f "$recipes/$name/YONEBUILD" ] || { echo "no recipe $name" >&2; exit 1; }
  start=$SECONDS
  : > "$work/marker"
  sleep 1
  printf '   %-24s ' "$name"
  rc=0
  setsid --wait timeout --kill-after=1m "${GRAVEYARD_PACKAGE_TIMEOUT:-120m}" \
    chroot "$root" /usr/bin/env -i HOME=/root TERM=xterm LC_ALL=C \
    PATH=/usr/bin:/usr/sbin:/usr/local/bin MAKEFLAGS="-j$(nproc)" SOURCE_DATE_EPOCH=0 \
    /usr/local/bin/yone build "/packages/recipes/$name" --out /packages/repo \
    --sign /packages/key.key --compress zstd --color never \
    < /dev/null > "$work/logs/$name.log" 2>&1 || rc=$?
  # what changed in the reference during this build, outside the build area
  writes=$(cd "$upper" && find . -cnewer "$work/marker" ! -type d 2> /dev/null \
    | sed 's|^\./||' | grep -Ev "$allowed" | sort || true)
  if [ -n "$writes" ]; then
    stray+=("$name")
    { echo "---- written outside \$PKGDIR:"; echo "$writes"; } >> "$work/logs/$name.log"
  fi
  if [ "$rc" -eq 0 ]; then
    size=$(sed -n 's/.*✓ .*\.yon (\([^,]*\),.*/\1/p' "$work/logs/$name.log" | tail -n 1)
    printf 'ok   %4ds  %s%s\n' $((SECONDS - start)) "$size" "${writes:+  STRAY WRITES: $(wc -l <<< "$writes")}"
  else
    failed+=("$name")
    printf 'FAIL %4ds  (exit %d)%s\n' $((SECONDS - start)) "$rc" "${writes:+  STRAY WRITES: $(wc -l <<< "$writes")}"
    tail -n 25 "$work/logs/$name.log" | sed 's/^/      | /'
  fi
  [ -z "$writes" ] || head -n 10 <<< "$writes" | sed 's|^|      written outside $PKGDIR: /|'
done

chroot "$root" /usr/local/bin/yone repo-index /packages/repo --name base \
  --sign /packages/key.key --color never > /dev/null
cp "$root/packages/key.pub.pem" "$root/packages/repo/graveyard-base.pub.pem"
rm -rf "$work/repo"
cp -R "$root/packages/repo" "$work/repo"

echo
echo "built: $(( ${#order[@]} - ${#failed[@]} )) of ${#order[@]}"
[ ${#failed[@]} -eq 0 ] || echo "FAILED: ${failed[*]}"
[ ${#stray[@]} -eq 0 ] || echo "WROTE OUTSIDE \$PKGDIR: ${stray[*]} (see their logs)"

if [ ${#only[@]} -gt 0 ]; then
  [ ${#failed[@]} -eq 0 ] && [ ${#stray[@]} -eq 0 ]
  exit
fi

log "installation into an empty root"
target=$root/target
rm -rf "$target"
mkdir -p "$target/etc/yone/keys"
cp "$root/packages/key.pub.pem" "$target/etc/yone/keys/graveyard-base.pub.pem"
cat > "$target/etc/yone/yone.conf" << 'EOF'
[options]
siglevel = required

[base]
server = file:///packages/repo
EOF
targets=(base)
if [ ${#failed[@]} -gt 0 ]; then
  # what could be built, for a partial comparison
  mapfile -t targets < <(cd "$work/repo" && ls ./*.yon | sed 's|^\./||; s/-[^-]*-[^-]*-x86_64\.yon$//' | grep -vx base)
fi
rc=0
chroot "$root" /usr/local/bin/yone --root /target --noconfirm --color never refresh > "$work/logs/install.log" 2>&1 \
  && chroot "$root" /usr/local/bin/yone --root /target --noconfirm --color never install "${targets[@]}" \
    >> "$work/logs/install.log" 2>&1 || rc=$?
tail -n 15 "$work/logs/install.log"
[ "$rc" -eq 0 ] || { echo "installation failed (exit $rc)"; exit 1; }

log "assembly (packages/assemble.sh)"
bash "$HERE/assemble.sh" "$target" 2>&1 | tee "$work/logs/assemble.log"
chroot "$root" /usr/local/bin/yone --root /target --color never verify > "$work/logs/verify.log" 2>&1 \
  && echo "   yone verify: $(tail -n 1 "$work/logs/verify.log")" \
  || { echo "   yone verify found problems:"; tail -n 20 "$work/logs/verify.log"; exit 1; }

[ ${#failed[@]} -eq 0 ] && [ ${#stray[@]} -eq 0 ]
