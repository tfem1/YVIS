#!/usr/bin/env bash
# End-to-end test of Yone against a throw-away root.
# Builds real signed packages, publishes a signed repository over file://,
# then exercises install / upgrade / conflicts / rollback / removal /
# verification / tampering / path-escape defences.
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
YONE=${YONE:-$(cd "$(dirname "$0")/.." && pwd)/target/debug/yone}
COMP=${YONE_TEST_COMPRESSION:-xz}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"

n=0
ok()   { n=$((n+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }
fails(){ if "$@" >"$T/last.log" 2>&1; then cat "$T/last.log"; die "expected failure: $*"; fi; }
sha()  { sha256sum "$1" | cut -d' ' -f1; }

ROOT=$T/root
KEY=$T/keys/test.key
Y=("$YONE" --root "$ROOT" --noconfirm --color never)

echo "== keys and repository"
mkdir -p keys repo "$ROOT/etc/yone/keys"
"$YONE" keygen keys/test >/dev/null
cp keys/test.pub.pem "$ROOT/etc/yone/keys/"
"$YONE" keygen keys/rogue >/dev/null   # an untrusted key

recipe() { # dir, then YONEBUILD on stdin
  mkdir -p "$1"; cat > "$1/YONEBUILD"
}
build() { "$YONE" build "$1" --out "$T/repo" --sign "$KEY" --compress "$COMP" --color never >/dev/null; }
publish() { "$YONE" repo-index "$T/repo" --name core --sign "$KEY" --color never >/dev/null; }

echo "lib v1" > libfoo.txt
recipe r/libfoo <<EOF
name = libfoo
version = 1.0
desc = Test library
license = MIT
provides = libfoo.so=1
source = libfoo.txt::$T/libfoo.txt
sha256 = $(sha libfoo.txt)
@package
install -Dm644 libfoo.txt "\$PKGDIR/usr/lib/libfoo.so.1"
ln -s libfoo.so.1 "\$PKGDIR/usr/lib/libfoo.so"
EOF

foo_recipe() { # version, conf content, extra file
recipe r/foo <<EOF
name = foo
version = $1
desc = The foo tool
depends = libfoo>=1.0 libfoo.so=1
backup = etc/foo.conf
@package
mkdir -p "\$PKGDIR/usr/bin" "\$PKGDIR/etc" "\$PKGDIR/usr/share/foo/$(printf 'deep%.0s/' {1..30})"
printf '#!/bin/sh\necho foo $1\n' > "\$PKGDIR/usr/bin/foo"
chmod 755 "\$PKGDIR/usr/bin/foo"
printf '$2' > "\$PKGDIR/etc/foo.conf"
echo $1 > "\$PKGDIR/usr/share/foo/$(printf 'deep%.0s/' {1..30})version"
${3:-true}
EOF
}
foo_recipe 1.0 'setting=1\n' 'echo legacy > "$PKGDIR/usr/share/foo/legacy.txt"'

recipe r/bar <<'EOF'
name = bar
version = 2.0
conflicts = foo
@package
install -Dm755 /dev/null "$PKGDIR/usr/bin/bar"
EOF
recipe r/clash <<'EOF'
name = clash
version = 1.0
@package
install -Dm755 /dev/null "$PKGDIR/usr/bin/foo"
EOF
recipe r/stray <<'EOF'
name = stray
version = 1.0
@package
install -Dm644 /dev/null "$PKGDIR/usr/share/stray"
EOF
recipe r/multi <<'EOF'
name = multi
version = 1.0
@package
for i in $(seq 1 40); do install -Dm644 /dev/null "$PKGDIR/usr/share/multi/f$i"; done
EOF

for p in libfoo foo bar clash stray multi; do build r/$p; done
publish
ok "built and signed $(ls repo/*.yon | wc -l) packages, signed index"

a=$(sha repo/libfoo-1.0-1-x86_64.yon)
build r/libfoo
[ "$a" = "$(sha repo/libfoo-1.0-1-x86_64.yon)" ] && ok "builds are bit-for-bit reproducible" || die "non reproducible build"

cat > "$ROOT/etc/yone/yone.conf" <<EOF
[options]
parallel = 4
siglevel = required
compression = $COMP

[core]
server = file://$T/repo
EOF

echo "== sync, search, install"
"${Y[@]}" update >/dev/null && ok "update verifies the signed index"
"${Y[@]}" search foo | grep -q "core/foo" && ok "search"
"${Y[@]}" install foo >/dev/null
[ "$("$ROOT/usr/bin/foo")" = "foo 1.0" ] && ok "install foo (runs)"
[ "$(readlink "$ROOT/usr/lib/libfoo.so")" = libfoo.so.1 ] && ok "dependency libfoo pulled in, symlinks preserved"
"${Y[@]}" list --deps | grep -q libfoo && ok "libfoo recorded as dependency"
"${Y[@]}" list --explicit | grep -q '^foo' && ok "foo recorded as explicit"
grep -q "$(sha "$ROOT/usr/bin/foo")" "$ROOT/var/lib/yone/local/foo/files" && ok "recorded SHA-256 matches coreutils sha256sum"
"${Y[@]}" verify >/dev/null && ok "verify: clean system"
"${Y[@]}" info foo | grep -q "explicitly installed" && ok "info"
[ ! -e "$ROOT/var/lib/yone/journal" ] && ok "no journal left behind"

echo "== integrity and conflicts"
echo tampered >> "$ROOT/usr/lib/libfoo.so.1"
fails "${Y[@]}" verify; grep -q "checksum mismatch" last.log && ok "verify detects a modified file"
"${Y[@]}" install --reinstall libfoo >/dev/null && "${Y[@]}" verify >/dev/null && ok "reinstall repairs it"
"${Y[@]}" list --deps | grep -q libfoo && ok "reinstall keeps the install reason (still a dependency)"
fails "${Y[@]}" install bar; grep -q "conflicts with" last.log && ok "declared package conflict refused"
fails "${Y[@]}" install clash; grep -q "owned by foo" last.log && ok "file conflict with another package refused"
mkdir -p "$ROOT/usr/share" && echo mine > "$ROOT/usr/share/stray"
fails "${Y[@]}" install stray; grep -q "exists in filesystem" last.log && ok "unowned file is protected"
"${Y[@]}" install --overwrite stray >/dev/null && ok "--overwrite replaces it"
fails "${Y[@]}" install nosuchpkg && ok "unknown package refused"

echo "== transactional rollback"
before=$(find "$ROOT" -path "$ROOT/var" -prune -o -print | sort | sha256sum)
fails env YONE_TEST_FAIL_AFTER=25 "${Y[@]}" install multi
grep -q "rolling back" last.log || die "no rollback message"
after=$(find "$ROOT" -path "$ROOT/var" -prune -o -print | sort | sha256sum)
[ "$before" = "$after" ] && ok "failed install leaves the filesystem exactly as before"
[ ! -e "$ROOT/var/lib/yone/local/multi" ] && [ ! -e "$ROOT/var/lib/yone/journal" ] && ok "database untouched, journal cleared"

echo "== upgrade with configuration preservation"
echo "setting=2  # admin" > "$ROOT/etc/foo.conf"
foo_recipe 1.1 'setting=1\nnew=1\n'
build r/foo; rm repo/foo-1.0-1-x86_64.yon*; publish
idx=$(sha "$ROOT/var/lib/yone/sync/core.index")
[ "$("${Y[@]}" check-updates 2>/dev/null)" = "foo 1.0-1 -> 1.1-1" ] && ok "check-updates lists foo 1.0-1 -> 1.1-1"
[ "$idx" = "$(sha "$ROOT/var/lib/yone/sync/core.index")" ] && ok "  ...without touching the system's indexes"
[ "$("${Y[@]}" check-updates --offline 2>/dev/null || true)" = "" ] && ok "check-updates --offline only reads the cached indexes"
"${Y[@]}" update >/dev/null
fails env YONE_TEST_FAIL_AFTER=3 "${Y[@]}" upgrade
[ "$("$ROOT/usr/bin/foo")" = "foo 1.0" ] && [ -e "$ROOT/usr/share/foo/legacy.txt" ] && ok "failed upgrade rolled back to foo 1.0"
"${Y[@]}" upgrade >/dev/null 2>"$T/up.log"
[ "$("$ROOT/usr/bin/foo")" = "foo 1.1" ] && ok "upgrade foo 1.0 → 1.1"
grep -q "admin" "$ROOT/etc/foo.conf" && grep -q "new=1" "$ROOT/etc/foo.conf.yonenew" && ok "modified config kept, new one saved as .yonenew"
[ ! -e "$ROOT/usr/share/foo/legacy.txt" ] && ok "files dropped by the new version are removed"
"${Y[@]}" verify >/dev/null && ok "verify after upgrade"
"${Y[@]}" upgrade 2>&1 | grep -q "up to date" && ok "second upgrade is a no-op"
rc=0; "${Y[@]}" check-updates >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "check-updates exits 2 when nothing is to update"
rm "$ROOT/etc/foo.conf.yonenew"
foo_recipe 1.2 'setting=1\nnew=2\n'
build r/foo; rm repo/foo-1.1-1-x86_64.yon*; publish
"${Y[@]}" update >/dev/null && "${Y[@]}" upgrade >/dev/null 2>&1
grep -q "admin" "$ROOT/etc/foo.conf" && grep -q "new=2" "$ROOT/etc/foo.conf.yonenew" \
  && ok "admin changes survive a second upgrade" || die "second upgrade overwrote the modified config"

echo "== removal"
fails "${Y[@]}" remove libfoo; grep -q "foo requires" last.log && ok "removing a needed dependency is refused"
"${Y[@]}" remove foo >/dev/null
[ ! -e "$ROOT/usr/bin/foo" ] && [ ! -d "$ROOT/usr/share/foo" ] && ok "remove foo (files and empty dirs gone)"
[ -e "$ROOT/etc/foo.conf.yonesave" ] && ok "modified config saved as .yonesave"
"${Y[@]}" autoremove >/dev/null
[ -z "$("${Y[@]}" list | grep libfoo || true)" ] && [ ! -e "$ROOT/usr/lib/libfoo.so.1" ] && ok "autoremove drops the orphaned libfoo"

echo "== supply-chain defences"
cp repo/core.index repo/core.index.bak
sed -i 's/desc = The foo tool/desc = Evil/' repo/core.index
fails "${Y[@]}" update; grep -q "invalid signature" last.log && ok "tampered index rejected"
grep -q "The foo tool" "$ROOT/var/lib/yone/sync/core.index" && ok "previous trusted index kept"
cp repo/core.index.bak repo/core.index
"$YONE" repo-index "$T/repo" --name core --sign keys/rogue.key --color never >/dev/null
fails "${Y[@]}" update && ok "index signed by an untrusted key rejected"
SOURCE_DATE_EPOCH=1 publish; cp repo/core.index old.index; cp repo/core.index.sig old.index.sig
publish; "${Y[@]}" update >/dev/null
cp old.index repo/core.index; cp old.index.sig repo/core.index.sig
fails "${Y[@]}" update; grep -q "older than the one already" last.log && ok "replayed older signed index refused"
publish; "${Y[@]}" update >/dev/null

"${Y[@]}" clean --all >/dev/null
cp repo/multi-1.0-1-x86_64.yon multi.bak
printf 'X' | dd of=repo/multi-1.0-1-x86_64.yon bs=1 seek=200 conv=notrunc 2>/dev/null
fails "${Y[@]}" install multi; grep -q "checksum mismatch" last.log && ok "corrupted package rejected (SHA-256 from signed index)"
cp multi.bak repo/multi-1.0-1-x86_64.yon

cp repo/libfoo-1.0-1-x86_64.yon local.yon
fails "${Y[@]}" install "$T/local.yon"; grep -q "missing signature" last.log && ok "unsigned local package refused"
"${Y[@]}" install --allow-unsigned "$T/local.yon" >/dev/null && ok "--allow-unsigned installs it"

# hand-crafted malicious packages
mkdir -p "$T/outside"
python3 - "$T" "$COMP" <<'PY'
import io, sys, tarfile, subprocess
T, comp = sys.argv[1], sys.argv[2]
def pkg(name, members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as t:
        info = f"name = {name}\nversion = 1-1\narch = x86_64\n".encode()
        ti = tarfile.TarInfo(".YONEINFO"); ti.size = len(info); t.addfile(ti, io.BytesIO(info))
        for m in members:
            ti = tarfile.TarInfo(m[0])
            if m[1] == "sym":
                ti.type = tarfile.SYMTYPE; ti.linkname = m[2]; t.addfile(ti)
            else:
                ti.size = len(m[2]); t.addfile(ti, io.BytesIO(m[2]))
    out = f"{T}/evil/{name}-1-1-x86_64.yon"
    cmd = ["xz", "-c"] if comp == "xz" else ["zstd", "-q", "-c"]
    open(out, "wb").write(subprocess.run(cmd, input=buf.getvalue(), capture_output=True, check=True).stdout)
import os; os.makedirs(f"{T}/evil", exist_ok=True)
pkg("traversal", [("../../escaped", "file", b"pwned")])
pkg("symescape", [("usr/escape", "sym", f"{T}/outside"), ("usr/escape/pwned", "file", b"pwned")])
PY
for f in evil/*.yon; do cp "$f" repo/; done
publish; "${Y[@]}" update >/dev/null
fails "${Y[@]}" install traversal; grep -q "unsafe path" last.log && ok "path traversal (../) refused"
fails "${Y[@]}" install symescape; grep -q "outside the installation root" last.log && ok "symlink escape refused and rolled back"
[ -z "$(ls -A "$T/outside")" ] && [ ! -e "$ROOT/usr/escape" ] && [ ! -e "$T/escaped" ] && ok "nothing written outside the root"

echo "== offline and cache"
"${Y[@]}" install multi >/dev/null
"${Y[@]}" remove multi >/dev/null
mv repo repo.offline
"${Y[@]}" install --offline multi >/dev/null && ok "offline install from the package cache"
"${Y[@]}" remove multi >/dev/null
"${Y[@]}" clean --all >/dev/null
fails "${Y[@]}" install --offline multi; grep -q "not in the cache" last.log && ok "offline mode never touches the network"
mv repo.offline repo

echo "== crash recovery (power cut simulated with an abrupt exit)"
leftovers() { find "$ROOT" -name '*.yone-old' -o -name '*.yone-new' | grep -q .; }
fails env YONE_TEST_CRASH=staged "${Y[@]}" install multi
fails "${Y[@]}" install --reinstall stray; grep -q "yone recover" last.log && ok "a crashed transaction blocks new ones until recovered"
"${Y[@]}" recover 2>&1 | grep -q "rolled back" && ok "crash before the commit point: recover rolls back"
[ -z "$("${Y[@]}" list | grep '^multi' || true)" ] && [ ! -e "$ROOT/usr/share/multi" ] && ! leftovers \
  && "${Y[@]}" verify >/dev/null && ok "  ...nothing of multi left, database and files agree"
fails env YONE_TEST_CRASH=committed "${Y[@]}" install multi
"${Y[@]}" recover 2>&1 | grep -q "completed" && ok "crash after the commit point: recover rolls forward"
"${Y[@]}" list | grep -q '^multi' && [ -e "$ROOT/usr/share/multi/f40" ] && ! leftovers \
  && "${Y[@]}" verify >/dev/null && ok "  ...multi fully installed, database and files agree"
fails env YONE_TEST_CRASH=committed "${Y[@]}" remove multi
"${Y[@]}" recover >/dev/null
[ -z "$("${Y[@]}" list | grep '^multi' || true)" ] && [ ! -e "$ROOT/usr/share/multi" ] && ! leftovers \
  && ok "crash after committing a removal: recover completes it"
"${Y[@]}" recover 2>&1 | grep -q "no interrupted" && ok "recover on a clean system is a no-op"

echo "== locking"
exec 9>"$ROOT/var/lib/yone/db.lck"; flock -n 9
fails "${Y[@]}" install multi; grep -q "locked" last.log && ok "concurrent transactions blocked by the lock"
exec 9>&-
"${Y[@]}" install multi >/dev/null && ok "a leftover lock file (crashed yone) does not block"
"${Y[@]}" remove multi >/dev/null

"${Y[@]}" verify >/dev/null && ok "final verify"
# "cond && ok msg" silently skips a failed check under set -e: make sure
# every check written in this file actually ran and passed.
want=$(grep -c ' ok "' "$SELF")
[ "$n" -eq "$want" ] || die "only $n of $want checks passed (a check failed silently)"
echo
echo "all $n checks passed ($COMP)"
