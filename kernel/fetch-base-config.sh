#!/usr/bin/env bash
# Fetch the kernel configuration YVIS starts from: Arch Linux's, for the
# kernel series the book builds. It enables about every driver as a module,
# which is what a system installed on unknown hardware needs; the book's own
# method (defconfig, then a menu) builds a kernel for one machine.
#
#   kernel/fetch-base-config.sh 7.1.8     writes kernel/base.config and
#                                         kernel/base.config.source
#
# The file is committed: builds never download it. Run by the kernel-config
# workflow, which pushes the result to a review branch.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
want=${1:?kernel version, e.g. 7.1.8}
series=${want%.*}; patch=${want##*.}
api=https://gitlab.archlinux.org/api/v4/projects/archlinux%2Fpackaging%2Fpackages%2Flinux/repository
raw=https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/raw

# Tags look like 7.1.8.arch1-1 (7.1.arch1-1 for the .0 release).
tags=$(for page in 1 2 3 4 5; do
  curl -fsSL "$api/tags?per_page=100&page=$page&search=^$series" | python3 -c '
import json, sys
for t in json.load(sys.stdin):
    print(t["name"])'
done | grep -E "^${series//./\\.}(\.[0-9]+)?\.arch[0-9]+-[0-9]+$" | sort -Vu || true)
[ -n "$tags" ] || { echo "no Arch tag for the $series series" >&2; exit 1; }

# The newest packaging of the exact version, else of the closest earlier
# patch level, else of the closest later one.
pick=$(python3 - "$patch" <<PY
import re, sys
want = int(sys.argv[1])
tags = """$tags""".split()
def key(t):
    m = re.match(r"^\d+\.\d+(?:\.(\d+))?\.arch(\d+)-(\d+)$", t)
    return (int(m.group(1) or 0), int(m.group(2)), int(m.group(3)))
exact = [t for t in tags if key(t)[0] == want]
older = [t for t in tags if key(t)[0] < want]
newer = [t for t in tags if key(t)[0] > want]
best = max(exact, key=key) if exact else max(older, key=key) if older else min(newer, key=lambda t: (key(t)[0], -key(t)[1], -key(t)[2]))
print(best)
PY
)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for name in config.x86_64 config; do
  if curl -fsSL "$raw/$pick/$name" -o "$tmp"; then file=$name; break; fi
done
[ -n "${file:-}" ] || { echo "no config file at tag $pick" >&2; exit 1; }
grep -q '^CONFIG_X86_64=y$' "$tmp" || { echo "$pick/$file is not an x86-64 kernel configuration" >&2; exit 1; }
grep -q '^CONFIG_MODULES=y$' "$tmp" || { echo "$pick/$file has no module support" >&2; exit 1; }

cp "$tmp" "$HERE/base.config"
cat > "$HERE/base.config.source" <<SRC
# Where kernel/base.config comes from (written by kernel/fetch-base-config.sh).
project = Arch Linux, packaging of the linux package
tag     = $pick
url     = $raw/$pick/$file
wanted  = $want
header  = $(sed -n '3p' "$tmp" | sed 's/^# //')
options = $(grep -c '^CONFIG_' "$tmp") set, $(grep -c '=m$' "$tmp") as modules
sha256  = $(sha256sum "$tmp" | cut -d' ' -f1)
SRC
cat "$HERE/base.config.source"
