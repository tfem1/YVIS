#!/bin/sh
# Tests kernel/check-config.sh and the files it is used with.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
n=0; ok() { n=$((n + 1)); echo "  ✓ $*"; }; die() { echo "  ✗ $*"; exit 1; }

printf 'A y\nB m\nC n\nD y|m\nE "text"\n# comment\n\nF y|m\n' > "$T/required"
printf 'CONFIG_A=y\nCONFIG_B=m\n# CONFIG_C is not set\nCONFIG_D=m\nCONFIG_E="text"\nCONFIG_F=y\n' > "$T/good"
bash "$HERE/check-config.sh" "$T/good" "$T/required" | grep -q "6 required options checked" && ok "a matching configuration passes"

printf 'CONFIG_A=m\nCONFIG_B=m\nCONFIG_C=y\nCONFIG_E="other"\nCONFIG_F=y\n' > "$T/bad"
if bash "$HERE/check-config.sh" "$T/bad" "$T/required" > "$T/out" 2>&1; then die "a wrong configuration must fail"; fi
grep -q "CONFIG_A is m, expected y" "$T/out" && grep -q "CONFIG_C is y, expected n" "$T/out" \
  && grep -q "CONFIG_D is n, expected y|m" "$T/out" && grep -q 'CONFIG_E is "other", expected "text"' "$T/out" \
  && grep -q "4 of 6 required options are wrong" "$T/out" && ok "each wrong, missing or unexpected option is reported"

: > "$T/empty"
if bash "$HERE/check-config.sh" "$T/good" "$T/empty" > /dev/null 2>&1; then die "an empty list must fail"; fi
ok "an empty list is an error, not a pass"

# The pinned base configuration is the file recorded in base.config.source.
want=$(sed -n 's/^sha256 *= *//p' "$HERE/base.config.source")
[ "$(sha256sum "$HERE/base.config" | cut -d' ' -f1)" = "$want" ] && ok "kernel/base.config matches its recorded SHA-256"

# Every option of the fragment is spelled like an option of the base (a typo
# would be dropped silently by olddefconfig), and base + fragment satisfy
# what the fragment is responsible for.
for o in $(sed -n 's/^CONFIG_\([A-Z0-9_]*\)=.*/\1/p; s/^# CONFIG_\([A-Z0-9_]*\) is not set$/\1/p' "$HERE/graveyard.config"); do
  grep -Eq "^(# )?CONFIG_$o[= ]" "$HERE/base.config" || die "kernel/graveyard.config: CONFIG_$o is unknown to kernel/base.config"
done
ok "every option of kernel/graveyard.config exists in the base configuration"

if bash "$HERE/check-config.sh" "$HERE/base.config" "$HERE/required" > "$T/out" 2>&1; then die "the base alone must not satisfy kernel/required"; fi
[ "$(grep -c expected "$T/out")" = 6 ] && ok "the base differs from kernel/required by exactly the six options the fragment sets"

[ "$n" = 6 ] || die "only $n of 6 checks passed"
echo "all $n checks passed"
