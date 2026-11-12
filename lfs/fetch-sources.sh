#!/usr/bin/env bash
# Download every LFS source into DEST and verify it.
#
#   lfs/fetch-sources.sh DEST
#
# Each file is tried from its upstream URL, then from the LFS mirrors. It must
# match the book's MD5 (lfs/md5sums) and, once lfs/sources.sha256 exists, the
# pinned SHA-256 as well. Without that lock the script writes DEST/sources.sha256
# for review; committing it pins every byte of the build inputs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lfs/config
. "$HERE/config"
DEST=${1:?usage: fetch-sources.sh DEST}
mkdir -p "$DEST"

[ -s "$HERE/md5sums" ] || { echo "lfs/md5sums missing (run the lfs-book workflow)" >&2; exit 1; }
LOCK="$HERE/sources.sha256"

get() { # url dest
  curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$2.part" "$1" && mv "$2.part" "$2"
}

fail=0
while read -r url; do
  [ -n "$url" ] || continue
  f=$(basename "$url")
  out="$DEST/$f"
  want_md5=$(awk -v f="$f" '$2 == f { print $1 }' "$HERE/md5sums")
  if [ -z "$want_md5" ]; then
    echo "✗ $f: not listed in the book's md5sums" >&2; fail=1; continue
  fi
  if [ -s "$out" ] && [ "$(md5sum "$out" | cut -d' ' -f1)" = "$want_md5" ]; then
    continue
  fi
  ok=0
  for u in "$url" $(for m in $LFS_MIRRORS; do echo "$m/$f"; done); do
    if get "$u" "$out" && [ "$(md5sum "$out" | cut -d' ' -f1)" = "$want_md5" ]; then
      ok=1; echo "↓ $f"; break
    fi
    rm -f "$out" "$out.part"
  done
  [ $ok = 1 ] || { echo "✗ $f: no source with the right checksum" >&2; fail=1; }
done < "$HERE/wget-list"
[ $fail = 0 ] || exit 1

( cd "$DEST" && sha256sum $(xargs -n1 basename < "$HERE/wget-list") ) > "$DEST/sources.sha256"
if [ -s "$LOCK" ]; then
  if ! diff -u "$LOCK" "$DEST/sources.sha256"; then
    echo "✗ sources differ from the pinned lfs/sources.sha256" >&2
    exit 1
  fi
  echo "✓ $(wc -l < "$LOCK") sources match the pinned SHA-256"
else
  echo "! no lfs/sources.sha256 yet: review and commit $DEST/sources.sha256"
fi
