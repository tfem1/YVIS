#!/usr/bin/env bash
# Make a disk image of a USB stick prepared with Ventoy, holding the ISO, set
# to boot it by itself: the way most people will try GraveyardOS.
#
#   sudo iso/ventoy-stick.sh <iso> <image> [ventoy version, default: latest]
#
# The ISO goes into a sub-directory with a space in its name, as on real
# sticks. ventoy.json makes Ventoy select it after a second, without its
# second menu, so that a test can boot it unattended.
set -euo pipefail
iso=$(realpath "${1:?ISO}") img=${2:?image} version=${3:-}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
work=$(mktemp -d)
loop=''
cleanup() {
  umount "$work/mnt" 2> /dev/null || true
  [ -z "$loop" ] || losetup -d "$loop" 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

if [ -z "$version" ]; then
  # The release page redirects to the latest tag. (Not the REST API: without
  # a token it allows 60 requests an hour per address, and CI runners share
  # addresses, so it answers 403.)
  version=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/ventoy/Ventoy/releases/latest \
    | sed -n 's|.*/tag/v\{0,1\}\([0-9][0-9.]*\)$|\1|p' || true)
fi
if [ -z "$version" ] && [ -n "${GH_TOKEN:-}" ]; then
  version=$(curl -fsSL -H "Authorization: Bearer $GH_TOKEN" \
    https://api.github.com/repos/ventoy/Ventoy/releases/latest \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' || true)
fi
[ -n "$version" ] || { echo "cannot find Ventoy's latest version" >&2; exit 1; }
echo "==> Ventoy $version"
curl -fsSL -o "$work/ventoy.tar.gz" \
  "https://github.com/ventoy/Ventoy/releases/download/v$version/ventoy-$version-linux.tar.gz"
tar -C "$work" -xzf "$work/ventoy.tar.gz"

rm -f "$img"
truncate -s "$(($(stat -c %s "$iso") / 1048576 + 512))M" "$img"
loop=$(losetup -fP --show "$img")
# Ventoy2Disk asks twice whether to wipe the disk
(cd "$work/ventoy-$version" && printf 'y\ny\n' | sh Ventoy2Disk.sh -I "$loop") > "$work/install.log" 2>&1 \
  || { cat "$work/install.log"; exit 1; }
partprobe "$loop" 2> /dev/null || true
udevadm settle 2> /dev/null || true
mkdir -p "$work/mnt"
mount "${loop}p1" "$work/mnt"
echo "   partition 1: $(findmnt -no FSTYPE "$work/mnt"), label $(blkid -s LABEL -o value "${loop}p1")"
dir="ISO/Linux distros"
mkdir -p "$work/mnt/$dir" "$work/mnt/ventoy"
cp "$iso" "$work/mnt/$dir/graveyard 0.1.iso"
cat > "$work/mnt/ventoy/ventoy.json" << JSON
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "1" },
    { "VTOY_DEFAULT_IMAGE": "/$dir/graveyard 0.1.iso" },
    { "VTOY_SECONDARY_BOOT_MENU": "0" }
  ]
}
JSON
sync
echo "   /$dir/graveyard 0.1.iso, booted by itself (ventoy/ventoy.json)"
echo "$version" > "$img.ventoy-version"
