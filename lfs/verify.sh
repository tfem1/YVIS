#!/bin/bash
# Checks a finished chapter 8 system from the inside (run by
# `lfs/build.sh verify` in the chroot). The build runs the book's commands;
# this asserts what the book only asks the reader to look at, plus what a
# system meant for other machines needs. Exit status: 0 if every check passes.
set -uo pipefail

fail=0
ok() { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }
is() { # description, actual, expected
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"
    printf '        expected: %s\n        got:      %s\n' "$3" "$2"
  fi
}
elf() { [ "$(head -c 4 "$1" 2>/dev/null | tr -d '\0')" = $'\177ELF' ]; }

work=$(mktemp -d) && cd "$work" || exit 1
trap 'cd /; rm -rf "$work"' EXIT
triplet=$(gcc -dumpmachine)

echo "== toolchain sanity checks (book, end of the GCC section)"
if echo 'int main(){}' | cc -x c - -v -Wl,--verbose > dummy.log 2>&1; then
  ok "cc compiles and links a program"
else
  bad "cc compiles and links a program"
fi
is "program interpreter" "$(readelf -l a.out 2>/dev/null | grep ': /lib' | tr -s ' ' | sed 's/^ //')" \
  "[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]"
is "start files come from /usr/lib" \
  "$(grep -E -o '/usr/lib.*/S?crt[1in].*succeeded' dummy.log | sed 's|.*/\.\./lib/||' | tr '\n' ' ')" \
  "Scrt1.o succeeded crti.o succeeded crtn.o succeeded "
is "header search path" "$(grep -B4 '^ /usr/include' dummy.log | sed "s|/usr/lib/gcc/$triplet/[0-9.]*|GCC|" | tr '\n' '|')" \
  "#include <...> search starts here:| GCC/include| /usr/local/include| GCC/include-fixed| /usr/include|"
is "linker search path (besides the -linux-gnu ones)" \
  "$(grep 'SEARCH.*/usr/lib' dummy.log | sed 's|; |\n|g' | grep -v -- '-linux-gnu' | tr '\n' ' ')" \
  'SEARCH_DIR("/usr/lib"); '
is "libc" "$(grep '/lib.*/libc.so.6 ' dummy.log)" "attempt to open /usr/lib/libc.so.6 succeeded"
is "dynamic linker" "$(grep found dummy.log)" "found ld-linux-x86-64.so.2 at /usr/lib/ld-linux-x86-64.so.2"
if ./a.out; then ok "the program runs"; else bad "the program runs"; fi
printf '#include <iostream>\nint main(){ std::cout << "c++ ok" << std::endl; }\n' > t.cc
is "g++ builds and runs a C++ program" "$(g++ t.cc -o t 2>&1 && ./t)" "c++ ok"

echo "== nothing left of the temporary toolchain (book 7.13 and 8.85)"
if [ ! -e /tools ]; then ok "/tools is gone"; else bad "/tools is gone"; fi
is "no $(uname -m)-lfs-linux-gnu file under /usr" "$(find /usr -depth -name "$(uname -m)-lfs-linux-gnu*" | head -n 3)" ""
is "no libtool archive in /usr/lib and /usr/libexec" "$(find /usr/lib /usr/libexec -name '*.la' | head -n 3)" ""
is "the tester account is removed" "$(grep -c '^tester:' /etc/passwd)" "0"

echo "== owners and modes (they cross CI jobs in an archive)"
is "no file with an unknown owner or group" \
  "$(find / -xdev \( -nouser -o -nogroup \) -not -path '/sources/*' -not -path '/.yvis/*' 2>/dev/null | head -n 5)" ""
is "/var/log/lastlog (book 7.6)" "$(stat -c '%U:%G %a' /var/log/lastlog 2>&1)" "root:utmp 664"
is "/usr/bin/wall is setgid tty" "$(stat -c '%U:%G %a' /usr/bin/wall 2>&1)" "root:tty 2755"
is "/usr/bin/su is setuid root" "$(stat -c '%U:%G %a' /usr/bin/su 2>&1)" "root:root 4755"

echo "== every program and library finds its libraries"
missing=$(
  find /usr/bin /usr/sbin /usr/libexec /usr/lib -xdev -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null |
    while read -r f; do
      elf "$f" || continue
      out=$(ldd "$f" 2>&1) || continue
      case $out in *"not found"*) echo "$f: $(grep 'not found' <<<"$out" | tr -s ' \t' ' ' | head -n 2 | tr '\n' ';')" ;; esac
    done | head -n 10
)
is "ldd reports no missing library" "$missing" ""
badpath=$(
  find /usr/bin /usr/sbin /usr/libexec /usr/lib -xdev -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null |
    while read -r f; do
      elf "$f" || continue
      readelf -d -l "$f" 2>/dev/null | grep -E 'interpreter|RPATH|RUNPATH' | grep -E '/tools|/mnt/' | sed "s|^|$f:|"
    done | head -n 10
)
is "no interpreter or run path points to /tools or the build directory" "$badpath" ""

echo "== programs start"
for cmd in "bash --version" "gcc --version" "g++ --version" "ld --version" "as --version" \
  "make --version" "python3 --version" "perl -v" "systemctl --version" "udevadm --version" \
  "grub-install --version" "vim --version" "openssl version" "meson --version" "ninja --version" \
  "tar --version" "xz --version" "zstd --version" "ip -V" "mount --version" "mke2fs -V" \
  "dbus-daemon --version" "man --version" "pkgconf --version" "locale -a"; do
  if $cmd > /dev/null 2>&1; then ok "$cmd"; else bad "$cmd"; fi
done
is "python: ssl, ctypes (libffi), sqlite3, lzma, bz2, zlib, curses, readline, expat" \
  "$(python3 -c 'import ssl, ctypes, sqlite3, lzma, bz2, zlib, curses, readline, hashlib, xml.parsers.expat
print(ctypes.CDLL(None).abs(-42))' 2>&1)" "42"

echo "== GMP, MPFR, MPC and Libffi run on any x86-64 CPU (book 8.2.3)"
# Instructions that are not in the x86-64 baseline: AVX, BMI, ADX, SSE4, ...
# (not tzcnt: GCC emits it as `rep bsf`, which older CPUs run as bsf.)
beyond='^\s+[0-9a-f]+:\s+(v[a-uw-z][a-z0-9]*|mulx|adcx|adox|pdep|pext|sarx|shlx|shrx|andn|bzhi|rorx|blsr|blsi|blsmsk|popcnt|lzcnt|movbe|pshufb|palignr|pmulld|pcmpeqq|crc32[bwlq]?)\s'
for lib in libgmp.so libgmpxx.so libmpfr.so libmpc.so libffi.so; do
  f=$(readlink -f "/usr/lib/$lib")
  if [ ! -f "$f" ]; then bad "$lib exists"; continue; fi
  n=$(objdump -d --no-show-raw-insn "$f" | grep -cE "$beyond")
  is "$lib uses no instruction beyond the x86-64 baseline" "$n" "0"
done

echo
if [ "$fail" -eq 0 ]; then echo "verify: all checks passed"; else echo "verify: $fail check(s) FAILED"; fi
[ "$fail" -eq 0 ]
