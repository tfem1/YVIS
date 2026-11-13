#!/usr/bin/env bash
# Build LFS from the commands extracted from the book (lfs/book/).
#
#   sudo lfs/build.sh host              prepare the host and $LFS (chapter 4)
#   sudo lfs/build.sh run ch05 [ch06 …] run chapters, resuming where they stopped
#   sudo lfs/build.sh mount | umount    virtual kernel file systems (chapter 7.3)
#   sudo lfs/build.sh pack FILE         archive $LFS (no sources) for the next job
#   sudo lfs/build.sh unpack FILE
#
# Every section runs with `bash -e` in the context the book expects:
#   ch05, ch06       as the unprivileged user `lfs`, with the book's environment
#   ch07 (two steps) as root on the host: changing ownership, kernel file systems
#   ch07, ch08       as root inside the chroot
# Sections with a source tarball run in its freshly extracted directory, which
# is removed afterwards, exactly as the book's general instructions say.
#
# lfs/overrides/<section-id>.sh   replaces the extracted commands
# lfs/overrides/<section-id>.post runs after them (same shell, same directory)
# lfs/skip                        sections never run (one id per line), or
#                                 single blocks of a section: <id>#<block>
# $LFS/.yvis/done/<section-id>    marks a finished section
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lfs/config
. "$HERE/config"
export LFS=${LFS:-/mnt/lfs}
JOBS=${JOBS:-$(nproc)}
# a section that hangs fails after this long instead of eating the whole job
SECTION_TIMEOUT=${YVIS_SECTION_TIMEOUT:-60m}
STATE=$LFS/.yvis
BOOK=${YVIS_LFS_BOOK:-$HERE/book}

log() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"

skipped() { grep -qxF "$1" "$HERE/skip" 2>/dev/null; }

# The book's commands minus the blocks listed as <id>#<n> in lfs/skip.
book_commands() { # id file
  local blocks
  blocks=$(sed -n "s/^$1#\([0-9]*\)\s*$/\1/p" "$HERE/skip" 2>/dev/null | tr '\n' ' ')
  awk -v skip=" $blocks" '
    /^# --- block [0-9]+/ { n = $4; sub(/:.*/, "", n); off = index(skip, " " n " ") > 0
                           if (off) print "# --- block " n ": SKIPPED (lfs/skip)" }
    !off { print }
  ' "$2"
}

# ------------------------------------------------------------------ host

host() {
  log "host requirements"
  # The book requires /bin/sh to be bash (Ubuntu ships dash).
  ln -sf bash /bin/sh
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      bison gawk texinfo m4 patch python3 xz-utils zstd >/dev/null
  fi
  log "creating $LFS (chapter 4)"
  mkdir -pv "$LFS"/{etc,var,tools,sources} "$LFS"/usr/{bin,lib,sbin} "$STATE/done"
  for i in bin lib sbin; do ln -sfnv usr/$i "$LFS/$i"; done
  mkdir -pv "$LFS/lib64"
  chmod -v a+wt "$LFS/sources"
  getent group lfs >/dev/null || groupadd lfs
  id lfs >/dev/null 2>&1 || useradd -s /bin/bash -g lfs -m -k /dev/null lfs
  chown -v lfs "$LFS"/{usr{,/*},var,etc,tools,lib64}
  # The book's ~/.bashrc for lfs, minus the interactive parts.
  cat > /home/lfs/.yvis-env <<EOF
set +h
umask 022
LFS=$LFS
LC_ALL=POSIX
LFS_TGT=$LFS_TGT
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:\$PATH; fi
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
MAKEFLAGS=-j$JOBS
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS
EOF
  chown lfs:lfs /home/lfs/.yvis-env
}

# --------------------------------------------------- kernel file systems

do_mount() {
  mkdir -pv "$LFS"/{dev,proc,sys,run}
  mountpoint -q "$LFS/dev" || mount -v --bind /dev "$LFS/dev"
  mountpoint -q "$LFS/dev/pts" || mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
  mountpoint -q "$LFS/proc" || mount -vt proc proc "$LFS/proc"
  mountpoint -q "$LFS/sys" || mount -vt sysfs sysfs "$LFS/sys"
  mountpoint -q "$LFS/run" || mount -vt tmpfs tmpfs "$LFS/run"
  if [ -h "$LFS/dev/shm" ]; then
    install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
  else
    mountpoint -q "$LFS/dev/shm" || mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
  fi
}

do_umount() {
  for m in dev/shm dev/pts dev sys proc run; do
    mountpoint -q "$LFS/$m" && umount -l "$LFS/$m" || true
  done
}

# ---------------------------------------------------------------- sections

# How a section runs: lfs | host | chroot | skip
context() { # chapter id
  case "$1:$2" in
    ch05:* | ch06:*) echo lfs ;;
    ch07:ch-tools-changingowner) echo host ;;
    # mounted by do_mount; entering the chroot and the backup are done by this script
    ch07:ch-tools-kernfs | ch07:ch-tools-chroot | ch07:ch-tools-stripping | ch07:ch-tools-backup) echo skip ;;
    ch07:* | ch08:*) echo chroot ;;
    *) echo skip ;;
  esac
}

# Write the script of one section: extraction, commands (or override), cleanup.
script_for() { # chapter id tarball file srcdir
  local ch=$1 id=$2 tb=$3 file=$4 src=$5
  {
    echo "set -e"
    echo "trap 'echo \"!! section $id failed at line \$LINENO\" >&2' ERR"
    if [ "$tb" != - ]; then
      local top
      # head closes the pipe early: tar then fails, which pipefail would report
      top=$(set +o pipefail; tar -tf "$LFS/sources/$tb" 2>/dev/null | head -n 1 | cut -d/ -f1)
      [ -n "$top" ] || die "$tb: cannot list the archive"
      # one command per line: set -e ignores failures inside && lists
      printf '%s\n' "cd $src" "rm -rf '$top'" "tar -xf '$tb'" "cd '$top'"
    else
      echo "cd /"
    fi
    if [ -f "$HERE/overrides/$id.sh" ]; then
      echo "# override: lfs/overrides/$id.sh"
      cat "$HERE/overrides/$id.sh"
    else
      book_commands "$id" "$file"
    fi
    if [ -f "$HERE/overrides/$id.post" ]; then
      echo "# lfs/overrides/$id.post"
      cat "$HERE/overrides/$id.post"
    fi
    [ "$tb" != - ] && printf '%s\n' "cd $src" "rm -rf '$top'"
    echo "true"
  }
}

run_section() { # chapter order id tarball
  local ch=$1 order=$2 id=$3 tb=$4
  local file=$BOOK/$ch/$order-$id.sh ctx
  ctx=$(context "$ch" "$id")
  if [ -e "$STATE/done/$id" ]; then return; fi
  if [ "$ctx" = skip ] || skipped "$id"; then
    echo "-- skip $id"; return
  fi
  local start=$SECONDS
  log "$ch $order $id ($ctx${tb:+, $tb})"
  # stdin is the list of sections being read by run(): a command reading
  # stdin (Expect's pty check does) would swallow the rest of the list.
  case $ctx in
    lfs)
      script_for "$ch" "$id" "$tb" "$file" "$LFS/sources" > /home/lfs/.yvis-step.sh
      chown lfs /home/lfs/.yvis-step.sh
      timeout --kill-after=1m "$SECTION_TIMEOUT" su - lfs -c "env -i HOME=/home/lfs TERM=${TERM:-xterm} bash -c '. ~/.yvis-env && bash -e ~/.yvis-step.sh'" </dev/null
      ;;
    host)
      script_for "$ch" "$id" "$tb" "$file" "$LFS/sources" > "$STATE/step.sh"
      LFS=$LFS timeout --kill-after=1m "$SECTION_TIMEOUT" bash -e "$STATE/step.sh" </dev/null
      ;;
    chroot)
      do_mount >/dev/null
      script_for "$ch" "$id" "$tb" "$file" /sources > "$LFS/.yvis/step.sh"
      timeout --kill-after=1m "$SECTION_TIMEOUT" chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/usr/sbin MAKEFLAGS="-j$JOBS" TESTSUITEFLAGS="-j$JOBS" \
        /bin/bash -e /.yvis/step.sh </dev/null
      ;;
  esac
  touch "$STATE/done/$id"
  echo "   done in $((SECONDS - start)) s"
}

run() {
  [ $# -gt 0 ] || die "run which chapters?"
  [ -f "$BOOK/sections.tsv" ] || die "lfs/book/ missing (run the lfs-book workflow and commit its output)"
  mkdir -p "$STATE/done"
  for ch in "$@"; do
    while IFS=$'\t' read -r c order id tb _title; do
      [ "$c" = "$ch" ] || continue
      run_section "$c" "$order" "$id" "$tb"
    done < <(grep -v '^#' "$BOOK/sections.tsv")
  done
}

case ${1:-} in
  host) host ;;
  run) shift; run "$@" ;;
  mount) do_mount ;;
  umount) do_umount ;;
  pack)
    do_umount
    tar --zstd -cpf "${2:?file}" -C "$LFS" --exclude=./sources .
    ls -lh "$2"
    ;;
  unpack)
    mkdir -p "$LFS"
    tar --zstd -xpf "${2:?file}" -C "$LFS"
    ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
