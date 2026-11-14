#!/usr/bin/env bash
# Download the sources of the GraveyardOS sections (lfs/graveyard/sources) into DEST.
#
#   lfs/graveyard/fetch-sources.sh DEST
#
# Each file must match the BLFS book's MD5 and, once pinned, GraveyardOS's SHA-256.
# A source not pinned yet is accepted on its MD5 and its SHA-256 printed, to
# be written into lfs/graveyard/sources after review.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEST=${1:?usage: fetch-sources.sh DEST}
mkdir -p "$DEST"
fail=0
while read -r url md5 sha; do
  case $url in ''|'#'*) continue ;; esac
  f=$(basename "$url") out="$DEST/$(basename "$url")"
  if ! [ -s "$out" ] || [ "$(md5sum "$out" | cut -d' ' -f1)" != "$md5" ]; then
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$out.part" "$url" && mv "$out.part" "$out" || true
  fi
  if ! [ -s "$out" ] || [ "$(md5sum "$out" | cut -d' ' -f1)" != "$md5" ]; then
    echo "✗ $f: download failed or wrong MD5" >&2; fail=1; continue
  fi
  got=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$sha" = - ]; then
    echo "! $f is not pinned yet: sha256 $got (put it in lfs/graveyard/sources)"
  elif [ "$got" != "$sha" ]; then
    echo "✗ $f: SHA-256 $got, pinned $sha" >&2; fail=1
  else
    echo "✓ $f"
  fi
done < "$HERE/sources"
exit $fail
