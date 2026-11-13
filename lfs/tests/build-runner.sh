#!/usr/bin/env bash
# Local test of lfs/build.sh with a fake two-chapter book (needs root, no
# network): the lfs-user context, host context, tarball handling, overrides,
# skip list, resume markers, failure reporting, isolation from the terminal
# and the hang timeout.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "needs root"; exit 77; }
T=$(mktemp -d); chmod 755 "$T"
cp "$HERE/skip" "$T/skip.orig"
trap 'cp "$T/skip.orig" "$HERE/skip"; rm -rf "$T"; userdel -r lfs >/dev/null 2>&1 || true' EXIT
export LFS=$T/lfs YVIS_LFS_BOOK=$T/book
n=0; ok() { n=$((n + 1)); echo "  ✓ $*"; }; die() { echo "  ✗ $*"; exit 1; }

mkdir -p "$T/pkg/hello-1.0" "$YVIS_LFS_BOOK"/{ch05,ch07}
echo 'echo built > "$1"' > "$T/pkg/hello-1.0/build.sh"
tar -C "$T/pkg" -czf "$T/hello-1.0.tar.gz" hello-1.0
cat > "$YVIS_LFS_BOOK/sections.tsv" <<'TSV'
# chapter	order	section	tarball	title
ch05	000	ch-tools-badcd	missing-1.0.tar.gz	5.0 Missing tarball
ch05	001	ch-tools-hello	hello-1.0.tar.gz	5.1 Hello-1.0
ch05	002	ch-tools-env	-	5.2 Environment
ch05	003	ch-tools-boom	-	5.3 Fails
ch05	005	ch-tools-tty	-	5.5 Terminal
ch05	006	ch-tools-hang	-	5.6 Hangs
ch05	007	ch-tools-after	-	5.7 After the hang
ch07	004	ch-tools-changingowner	-	7.2 Changing Ownership
TSV
cat > "$YVIS_LFS_BOOK/ch05/001-ch-tools-hello.sh" <<'SH'
# --- block 1
bash build.sh "$LFS/tools/hello.out"
pwd > "$LFS/tools/hello.pwd"
SH
cat > "$YVIS_LFS_BOOK/ch05/002-ch-tools-env.sh" <<'SH'
# --- block 1
echo "$(id -un) $LFS_TGT $LC_ALL $MAKEFLAGS" > "$LFS/tools/env.out"

# --- block 2
echo "must be skipped" > "$LFS/tools/block2.out"

# --- block 3
echo kept > "$LFS/tools/block3.out"
cat > /dev/null   # reads stdin, as Expect's pty check does
SH
echo 'false' > "$YVIS_LFS_BOOK/ch05/003-ch-tools-boom.sh"
cat > "$YVIS_LFS_BOOK/ch05/000-ch-tools-badcd.sh" <<'SH'
echo "must not run" > "$LFS/tools/badcd.out"
SH
cat > "$YVIS_LFS_BOOK/ch05/005-ch-tools-tty.sh" <<'SH'
echo "to the log file"
SH
echo 'sleep 600' > "$YVIS_LFS_BOOK/ch05/006-ch-tools-hang.sh"
echo 'echo after > "$LFS/tools/after.out"' > "$YVIS_LFS_BOOK/ch05/007-ch-tools-after.sh"
cat > "$YVIS_LFS_BOOK/ch07/004-ch-tools-changingowner.sh" <<'SH'
chown -R root:root $LFS/tools && echo owned > $LFS/owner.out
if (: < /dev/tty) 2>/dev/null; then echo terminal; else echo none; fi > "$LFS/tty.out"
SH

bash "$HERE/build.sh" host >/dev/null 2>&1 || die "host step failed"
echo "ch-tools-env#2" >> "$HERE/skip"
cp "$T/hello-1.0.tar.gz" "$LFS/sources/"
[ -L "$LFS/bin" ] && id lfs >/dev/null && ok "host: layout and lfs user"

if bash "$HERE/build.sh" run ch05 >"$T/log" 2>&1; then cat "$T/log"; die "a failing section must fail the run"; fi
grep -q "missing-1.0.tar.gz: cannot list the archive" "$T/log" && [ ! -e "$LFS/tools/badcd.out" ] \
  && ok "a missing tarball stops the run before any command"
echo ch-tools-badcd >> "$HERE/skip"
if bash "$HERE/build.sh" run ch05 >"$T/log" 2>&1; then sed -i '$d' "$HERE/skip"; die "a failing section must fail the run"; fi
sed -i '$d' "$HERE/skip"
grep -q "skip ch-tools-badcd" "$T/log" && ok "lfs/skip is honoured"
grep -q "section ch-tools-boom failed" "$T/log" && ok "a failing command stops the run and names the section"
[ "$(cat "$LFS/tools/hello.out")" = built ] && ok "tarball extracted, commands run in its directory"
[ "$(cat "$LFS/tools/hello.pwd")" = "$LFS/sources/hello-1.0" ] && [ ! -e "$LFS/sources/hello-1.0" ] \
  && ok "the source directory is removed afterwards"
read -r who tgt lc mf < "$LFS/tools/env.out"
[ "$who" = lfs ] && [ "$tgt" = x86_64-lfs-linux-gnu ] && [ "$lc" = POSIX ] && [ "${mf#-j}" -ge 1 ] \
  && ok "chapter 5 runs as lfs with the book's environment"
[ "$(stat -c %U "$LFS/tools/hello.out")" = lfs ] && ok "files built in chapter 5 belong to lfs"
grep -q "ch05 003 ch-tools-boom" "$T/log" && ok "a section reading stdin does not swallow the following ones"
[ ! -e "$LFS/tools/block2.out" ] && [ "$(cat "$LFS/tools/block3.out")" = kept ] && ok "<id>#<block> in lfs/skip drops only that block"

echo 'echo replaced > "$LFS/tools/boom.out"' > "$T/override.sh"
mkdir -p "$HERE/overrides"; cp "$T/override.sh" "$HERE/overrides/ch-tools-boom.sh"
rm -f "$LFS/tools/hello.out"
echo ch-tools-badcd >> "$HERE/skip"
YVIS_UNTIL=ch-tools-tty bash "$HERE/build.sh" run ch05 >"$T/log" 2>&1 \
  || { sed -i '$d' "$HERE/skip"; rm -f "$HERE/overrides/ch-tools-boom.sh"; cat "$T/log"; die "override run failed"; }
rm -f "$HERE/overrides/ch-tools-boom.sh"
grep -q "to the log file" "$LFS/.yvis/logs/ch-tools-tty.log" && ! grep -q "to the log file" "$T/log" \
  && ok "a section's output goes to .yvis/logs/<id>.log, not to the console"
[ ! -e "$LFS/.yvis/done/ch-tools-hang" ] && ok "YVIS_UNTIL stops the run after that section"
start=$SECONDS
if YVIS_SECTION_TIMEOUT=2s bash "$HERE/build.sh" run ch05 >"$T/log" 2>&1; then sed -i '$d' "$HERE/skip"; die "a hung section must fail the run"; fi
sed -i '$d' "$HERE/skip"
grep -q "ch-tools-hang: no end after 2s, killed" "$T/log" && [ $((SECONDS - start)) -lt 60 ] && [ ! -e "$LFS/tools/after.out" ] \
  && ok "a section that hangs is killed after YVIS_SECTION_TIMEOUT and stops the run"
[ "$(cat "$LFS/tools/boom.out")" = replaced ] && ok "lfs/overrides/<id>.sh replaces the book's commands"
[ ! -e "$LFS/tools/hello.out" ] && ok "finished sections are not run again (resume)"

script -qec "bash '$HERE/build.sh' run ch07" /dev/null >/dev/null 2>&1 || die "ch07 failed"
[ "$(cat "$LFS/tty.out")" = none ] && ok "a section has no controlling terminal, even when the runner has one"
[ "$(cat "$LFS/owner.out")" = owned ] && [ "$(stat -c %U "$LFS/tools/env.out")" = root ] && ok "7.2 runs as root on the host"

want=$(grep -cE '(^|[;&|] *)ok "' "$0"); [ "$n" -eq "$want" ] || die "only $n of $want checks passed"
echo "all $n checks passed"
