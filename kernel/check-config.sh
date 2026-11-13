#!/bin/bash
# kernel/check-config.sh <.config> <required list>: every option of the list
# has the expected value in the configuration, or the build stops.
set -euo pipefail
config=${1:?.config} list=${2:?required list}
bad=0 n=0
while read -r opt want _; do
  case $opt in '' | '#'*) continue ;; esac
  n=$((n + 1))
  line=$(grep -E "^CONFIG_$opt=" "$config" || true)
  got=${line#*=}
  [ -n "$line" ] || got=n
  case $want in
    'y|m') [ "$got" = y ] || [ "$got" = m ] ;;
    *) [ "$got" = "$want" ] ;;
  esac || { echo "kernel config: CONFIG_$opt is $got, expected $want" >&2; bad=$((bad + 1)); }
done < "$list"
[ "$n" -gt 0 ] || { echo "kernel config: $list lists no option" >&2; exit 1; }
[ "$bad" -eq 0 ] || { echo "kernel config: $bad of $n required options are wrong" >&2; exit 1; }
echo "kernel config: $n required options checked"
