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
grep -q "up to date" <<<"$("${Y[@]}" upgrade 2>&1)" && ok "second upgrade is a no-op"
rc=0; "${Y[@]}" check-updates >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "check-updates exits 2 when nothing is to update"
rm "$ROOT/etc/foo.conf.yonenew"
foo_recipe 1.2 'setting=1\nnew=2\n'
build r/foo; rm repo/foo-1.1-1-x86_64.yon*; publish
"${Y[@]}" update >/dev/null && "${Y[@]}" upgrade >/dev/null 2>&1
grep -q "admin" "$ROOT/etc/foo.conf" && grep -q "new=2" "$ROOT/etc/foo.conf.yonenew" \
  && ok "admin changes survive a second upgrade" || die "second upgrade overwrote the modified config"
sed -i 's/^\[options\]$/[options]\nhold = foo/' "$ROOT/etc/yone/yone.conf"
foo_recipe 1.3 'setting=1\nnew=3\n'
build r/foo; publish; "${Y[@]}" update >/dev/null
grep -q "foo: held (1.2-1 -> 1.3-1 available" <<<"$("${Y[@]}" upgrade 2>&1)" && [ "$("$ROOT/usr/bin/foo")" = "foo 1.2" ] \
  && ok "a held package is not upgraded"
rc=0; "${Y[@]}" check-updates >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] && ok "  ...nor listed by check-updates"
sed -i '/^hold = foo$/d' "$ROOT/etc/yone/yone.conf"; rm -f repo/foo-1.3-1-*; publish; "${Y[@]}" update >/dev/null

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
fails "${Y[@]}" install symescape; grep -q "would be redirected" last.log && grep -q "rolling back" last.log \
  && ok "a package redirecting its own files through a symlink is refused and rolled back"
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

echo "== file capabilities"
if [ "$(id -u)" = 0 ] && command -v setcap >/dev/null && setcap cap_net_raw+ep "$(cp /bin/true "$T/captest" && echo "$T/captest")" 2>/dev/null; then
recipe r/capped <<'EOF'
name = capped
version = 1.0
@package
install -Dm755 /bin/true "$PKGDIR/usr/bin/capped"
setcap cap_net_raw+ep "$PKGDIR/usr/bin/capped"
EOF
build r/capped; publish; "${Y[@]}" update >/dev/null; "${Y[@]}" install capped >/dev/null
getcap "$ROOT/usr/bin/capped" | grep -q cap_net_raw && ok "setcap capabilities survive build and install"
"${Y[@]}" remove capped >/dev/null
else
  echo "  - skipped (needs root and setcap)"; n=$((n + 1))
fi

echo "== merged /usr (lib -> usr/lib, as on LFS)"
ln -s usr/lib "${ROOT:?}/lib"
recipe r/aliasa <<'EOF'
name = aliasa
version = 1.0
@package
echo A > x; install -Dm644 x "$PKGDIR/usr/lib/libalias.so"
EOF
recipe r/aliasb <<'EOF'
name = aliasb
version = 1.0
@package
mkdir -p "$PKGDIR/lib"; echo B > "$PKGDIR/lib/libalias.so"; echo B > "$PKGDIR/lib/libonly-b.so"
EOF
build r/aliasa; build r/aliasb; publish; "${Y[@]}" update >/dev/null
"${Y[@]}" install aliasa >/dev/null
fails "${Y[@]}" install --overwrite aliasb
grep -q "usr/lib/libalias.so: exists in filesystem (owned by aliasa)" last.log \
  && ok "a file reached through /lib is recognised as another package's, even with --overwrite"
"${Y[@]}" remove aliasa >/dev/null && "${Y[@]}" install aliasb >/dev/null
grep -q "	usr/lib/libonly-b.so$" "$ROOT/var/lib/yone/local/aliasb/files" && [ "$(cat "$ROOT/usr/lib/libonly-b.so")" = B ] \
  && ok "paths through a symlinked directory are recorded under their real location"
"${Y[@]}" remove aliasb >/dev/null && [ ! -e "$ROOT/usr/lib/libalias.so" ] && [ -L "$ROOT/lib" ] \
  && ok "removal deletes the real file and keeps the /lib symlink"
unlink "${ROOT:?}/lib"

echo "== crash recovery (power cut simulated with an abrupt exit)"
leftovers() { find "$ROOT" -name '*.yone-old' -o -name '*.yone-new' | grep -q .; }
fails env YONE_TEST_CRASH=staged "${Y[@]}" install multi
fails "${Y[@]}" install --reinstall stray; grep -q "yone recover" last.log && ok "a crashed transaction blocks new ones until recovered"
grep -q "rolled back" <<<"$("${Y[@]}" recover 2>&1)" && ok "crash before the commit point: recover rolls back"
[ -z "$("${Y[@]}" list | grep '^multi' || true)" ] && [ ! -e "$ROOT/usr/share/multi" ] && ! leftovers \
  && "${Y[@]}" verify >/dev/null && ok "  ...nothing of multi left, database and files agree"
fails env YONE_TEST_CRASH=committed "${Y[@]}" install multi
grep -q "completed" <<<"$("${Y[@]}" recover 2>&1)" && ok "crash after the commit point: recover rolls forward"
"${Y[@]}" list | grep -q '^multi' && [ -e "$ROOT/usr/share/multi/f40" ] && ! leftovers \
  && "${Y[@]}" verify >/dev/null && ok "  ...multi fully installed, database and files agree"
fails env YONE_TEST_CRASH=committed "${Y[@]}" remove multi
"${Y[@]}" recover >/dev/null
[ -z "$("${Y[@]}" list | grep '^multi' || true)" ] && [ ! -e "$ROOT/usr/share/multi" ] && ! leftovers \
  && ok "crash after committing a removal: recover completes it"
grep -q "no interrupted" <<<"$("${Y[@]}" recover 2>&1)" && ok "recover on a clean system is a no-op"

echo "== meta packages, queries, log"
recipe r/meta <<'EOF'
name = meta
version = 1.0
desc = A profile: only dependencies
depends = multi
@package
true
EOF
out=$("$YONE" build r/meta --out "$T/repo" --sign "$KEY" --compress "$COMP" --color never 2>&1)
grep -q "meta package" <<<"$out" && ok "an empty package builds as a meta package"
publish; "${Y[@]}" update >/dev/null
"${Y[@]}" install meta >/dev/null && "${Y[@]}" list | grep -q '^multi' && [ ! -s "$ROOT/var/lib/yone/local/meta/files" ] \
  && ok "installing it pulls its dependencies, it owns no file"
[ "$("${Y[@]}" owns /usr/share/multi/f7 2>/dev/null)" = "/usr/share/multi/f7 is owned by multi 1.0-1" ] && ok "owns: file"
"${Y[@]}" owns usr/share/multi 2>/dev/null | grep -q "owned by multi" && ok "owns: directory"
rc=0; "${Y[@]}" owns /etc/nothing >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] && ok "owns: exit 1 for an unowned path"
[ "$("${Y[@]}" files multi | grep -c '^multi /usr/share/multi/f')" = 40 ] && ok "files lists a package's files"
"${Y[@]}" remove meta >/dev/null && "${Y[@]}" autoremove >/dev/null && [ -z "$("${Y[@]}" list | grep '^multi' || true)" ] \
  && ok "removing the meta package lets autoremove take its dependencies"
grep -q "\] installed meta (1.0-1)" "$ROOT/var/log/yone.log" && grep -q "\] removed multi (1.0-1)" "$ROOT/var/log/yone.log" \
  && grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9:]{8}\] ' "$ROOT/var/log/yone.log" && ok "transactions are logged in /var/log/yone.log"

echo "== Ctrl-C"
fails env YONE_TEST_SIGINT_AFTER=10 "${Y[@]}" install multi
grep -q "interrupted" last.log && grep -q "rolling back" last.log && [ ! -e "$ROOT/var/lib/yone/journal" ] \
  && [ ! -e "$ROOT/usr/share/multi" ] && ok "Ctrl-C during installation rolls back cleanly, no journal left"
grep -q "transaction rolled back: interrupted" "$ROOT/var/log/yone.log" && ok "  ...and the rollback is logged"

echo "== build helpers"
"$YONE" keygen "$T/newdir/sub/key" >/dev/null && [ -s "$T/newdir/sub/key.key" ] && ok "keygen creates the key's directory"
recipe r/needs <<'EOF'
name = needs
version = 1.0
makedepends = nosuchtool
@package
install -Dm644 /dev/null "$PKGDIR/usr/share/needs"
EOF
out=$("$YONE" --root "$ROOT" build r/needs --out "$T/repo" --compress "$COMP" --color never 2>&1)
grep -q "makedepends not installed: nosuchtool" <<<"$out" && ok "build warns about missing makedepends"
rm -f "$T"/repo/needs-*

echo "== file owners (names mapped to the target's own ids)"
if [ "$(id -u)" = 0 ] && getent group tty >/dev/null && getent group disk >/dev/null && getent passwd nobody >/dev/null; then
  mkdir -p "$ROOT/etc"
  cp "$ROOT/etc/passwd" "$T/passwd.orig" 2>/dev/null || : > "$T/passwd.orig"
  cp "$ROOT/etc/group" "$T/group.orig" 2>/dev/null || : > "$T/group.orig"
  # same names, other ids than the build machine; no "disk" group at all
  printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:99:99:nobody:/:/bin/false\n' > "$ROOT/etc/passwd"
  printf 'root:x:0:\ntty:x:77:\nnogroup:x:99:\n' > "$ROOT/etc/group"
  recipe r/owned <<'EOF2'
name = owned
version = 1.0
@package
install -Dm2755 -g tty /dev/null "$PKGDIR/usr/bin/wall"
install -Dm644 -o nobody -g disk /dev/null "$PKGDIR/var/lib/owned/data"
install -d -m 750 -g tty "$PKGDIR/var/lib/ttydir"
install -Dm755 /dev/null "$PKGDIR/usr/bin/plain"
EOF2
  build r/owned; publish; "${Y[@]}" update >/dev/null
  pkg=$(ls "$T"/repo/owned-1.0-1-*.yon)
  listing=$(tar -tvf "$pkg")
  grep -Eq '^-rwxr-sr-x root/tty .* usr/bin/wall$' <<<"$listing" && grep -Eq '^-rwxr-xr-x root/root .* usr/bin/plain$' <<<"$listing" \
    && ok "the package records owners by name (root/tty), root's files as root"
  "${Y[@]}" install owned > "$T/owned.log" 2>&1
  [ "$(stat -c '%u:%g %a' "$ROOT/usr/bin/wall")" = "0:77 2755" ] \
    && ok "installed with the target's id for tty (77), setgid kept after chown"
  [ "$(stat -c '%u:%g %a' "$ROOT/var/lib/ttydir")" = "0:77 750" ] && ok "  ...directories too"
  [ "$(stat -c %u "$ROOT/var/lib/owned/data")" = 99 ] && [ "$(stat -c %g "$ROOT/var/lib/owned/data")" = "$(getent group disk | cut -d: -f3)" ] \
    && grep -q "group disk is unknown on the target system" "$T/owned.log" \
    && ok "a user is mapped by name, an unknown group falls back to its id with a warning"
  grep -q "^f	2755/root:tty	" "$ROOT/var/lib/yone/local/owned/files" && grep -q "^f	755	" "$ROOT/var/lib/yone/local/owned/files" \
    && ok "the database records the owner of files that are not root's"
  "${Y[@]}" verify owned >/dev/null && chgrp 0 "$ROOT/usr/bin/wall" && fails "${Y[@]}" verify owned
  grep -q "usr/bin/wall — belongs to root:root (expected root:tty)" "$T/last.log" && ok "verify reports a changed owner"
  "${Y[@]}" remove owned >/dev/null
  # built by an ordinary user: what that user created is root's in the package
  if command -v setpriv >/dev/null; then
    # its own directory: $T is private to root
    U=$(mktemp -d); chmod 755 "$U"
    cp -r r/owned "$U/"; sed -i '/-g tty\|-o nobody/d' "$U/owned/YONEBUILD"
    chown -R nobody "$U"
    setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups \
      "$YONE" build "$U/owned" --out "$U/out" --compress "$COMP" --color never >/dev/null 2>&1
    l=$(tar -tvf "$U"/out/owned-*.yon)
    grep -Eq '^-rwxr-xr-x root/root .* usr/bin/plain$' <<<"$l" && ! grep -q nobody <<<"$l" \
      && ok "built by another user, its files are root's in the package"
    rm -rf "${U:?}"
  else
    echo "  - skipped (no setpriv)"; n=$((n + 1))
  fi
  rm -f "$T"/repo/owned-*; publish
  cp "$T/passwd.orig" "$ROOT/etc/passwd"; cp "$T/group.orig" "$ROOT/etc/group"
else
  echo "  - skipped (needs root and the groups tty and disk)"; n=$((n + 7))
fi

echo "== noextract: archives the recipe unpacks itself"
mkdir -p "$T/nx/docs-1"; echo doc > "$T/nx/docs-1/index.html"
tar -C "$T/nx" -czf "$T/nx/docs-1.tar.gz" docs-1
recipe r/nx <<EOF2
name = nx
version = 1.0
source = docs-1.tar.gz::$T/nx/docs-1.tar.gz
sha256 = $(sha "$T/nx/docs-1.tar.gz")
noextract = docs-1.tar.gz
@package
test -f docs-1.tar.gz && test ! -d docs-1
install -d "\$PKGDIR/usr/share/doc/nx"
tar -xf docs-1.tar.gz -C "\$PKGDIR/usr/share/doc/nx" --strip-components=1
EOF2
build r/nx && tar -tf "$T"/repo/nx-1.0-1-*.yon | grep -qx usr/share/doc/nx/index.html \
  && ok "a noextract archive is handed to the recipe as it is"
recipe r/nxbad <<EOF2
name = nxbad
version = 1.0
noextract = missing.tar.gz
@package
true
EOF2
fails "$YONE" build r/nxbad --out "$T/repo" --color never
grep -q "noextract: missing.tar.gz is not one of the sources" "$T/last.log" && ok "noextract must name one of the sources"
rm -f "$T"/repo/nx-*; publish

echo "== backup = etc/: every configuration file of the package"
recipe r/confdir <<'EOF2'
name = confdir
version = 1.0
backup = etc/
backup = usr/share/confdir/extra.conf
@package
install -Dm644 /dev/null "$PKGDIR/etc/confdir/a.conf"
install -Dm644 /dev/null "$PKGDIR/etc/confdir/sub/b.conf"
ln -s a.conf "$PKGDIR/etc/confdir/link.conf"
install -Dm644 /dev/null "$PKGDIR/usr/share/confdir/extra.conf"
install -Dm644 /dev/null "$PKGDIR/usr/share/confdir/data"
EOF2
build r/confdir
backups=$(tar -xOf "$T"/repo/confdir-1.0-1-*.yon .YONEINFO | sed -n 's/^backup = //p' | tr ' ' '\n' | sort | tr '\n' ' ')
[ "$backups" = "etc/confdir/a.conf etc/confdir/sub/b.conf usr/share/confdir/extra.conf " ] \
  && ok "backup = etc/ lists every regular file under etc/ (not links), next to explicit entries"
rm -f "$T"/repo/confdir-*; publish

echo "== hooks (run in the root through chroot)"
if [ "$(id -u)" = 0 ] && file -L "$(command -v busybox 2>/dev/null || echo /nonexistent)" 2>/dev/null | grep -q 'statically linked'; then
  cp "$(command -v busybox)" "$T/busybox"
  recipe r/shell <<EOF
name = shell
version = 1.0
source = busybox::$T/busybox
sha256 = $(sha "$T/busybox")
@package
install -Dm755 busybox "\$PKGDIR/bin/busybox"
ln -s busybox "\$PKGDIR/bin/sh"
EOF
  recipe r/stamper <<'EOF'
name = stamper
version = 1.0
@package
mkdir -p "$PKGDIR/usr/share/yone/hooks" "$PKGDIR/usr/share/stamp"
cat > "$PKGDIR/usr/share/yone/hooks/50-stamp.hook" <<'HOOK'
desc = Counting stamps
paths = usr/share/stamp/
run = /bin/busybox sh -c "/bin/busybox ls /usr/share/stamp | /bin/busybox wc -l > /var/stamps"
HOOK
touch "$PKGDIR/usr/share/stamp/a"
EOF
  recipe r/stamp2 <<'EOF'
name = stamp2
version = 1.0
@package
install -Dm644 /dev/null "$PKGDIR/usr/share/stamp/b"
EOF
  for p in shell stamper stamp2; do build r/$p; done; publish; "${Y[@]}" update >/dev/null
  "${Y[@]}" install shell stamper > "$T/hook.log" 2>&1
  [ "$(tr -d ' ' < "$ROOT/var/stamps")" = 1 ] && grep -q "hook: Counting stamps" "$T/hook.log" \
    && ok "a hook shipped by a package runs when its paths change, inside the root"
  ! grep -q "ldconfig" "$T/hook.log" && ok "a hook whose program is not in the root is skipped"
  "${Y[@]}" install stamp2 >/dev/null 2>&1; [ "$(tr -d ' ' < "$ROOT/var/stamps")" = 2 ] && ok "another package's files trigger it"
  "${Y[@]}" remove stamp2 >/dev/null 2>&1; [ "$(tr -d ' ' < "$ROOT/var/stamps")" = 1 ] && ok "removals trigger it too"
  mkdir -p "$ROOT/etc/yone/hooks" && : > "$ROOT/etc/yone/hooks/50-stamp.hook"
  "${Y[@]}" install stamp2 >/dev/null 2>&1; [ "$(tr -d ' ' < "$ROOT/var/stamps")" = 1 ] && ok "an empty /etc/yone/hooks file disables it"
  rm "$ROOT/etc/yone/hooks/50-stamp.hook"
  "${Y[@]}" remove stamp2 stamper shell >/dev/null 2>&1
else
  echo "  - skipped (needs root and a static busybox)"; n=$((n + 5))
fi

echo "== locking"
exec 9>"$ROOT/var/lib/yone/db.lck"; flock -n 9
fails "${Y[@]}" install multi; grep -q "locked" last.log && ok "concurrent transactions blocked by the lock"
exec 9>&-
"${Y[@]}" install multi >/dev/null && ok "a leftover lock file (crashed yone) does not block"
"${Y[@]}" remove multi >/dev/null

"${Y[@]}" verify >/dev/null && ok "final verify"
# "cond && ok msg" silently skips a failed check under set -e: make sure
# every check written in this file actually ran and passed.
want=$(grep -cE '(^|[;&|] *)ok "' "$SELF")
[ "$n" -eq "$want" ] || die "only $n of $want checks passed (a check failed silently)"
echo
echo "all $n checks passed ($COMP)"
