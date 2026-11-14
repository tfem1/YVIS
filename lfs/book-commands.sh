# shellcheck shell=bash
# The book's commands for one section as YVIS runs them, shared by
# lfs/build.sh and packages/gen-base.py. Expects HERE (the lfs/ directory)
# and a die function.

# The book's commands minus the blocks listed as <id>#<n> in lfs/skip, plus
# the test blocks listed in lfs/tests-enabled, with the edits of lfs/edits
# applied. An edit that changes nothing stops the
# build: the book changed and the edit must be reviewed.
book_commands() { # id file [extra skip file]
  local blocks tests n text new sec expr
  # $3: more <id>#<n> lines to skip (the packages leave out more than the build)
  blocks=$(sed -n "s/^$1#\([0-9]*\)\s*$/\1/p" "$HERE/skip" ${3:+"$3"} 2>/dev/null | tr '\n' ' ')
  tests=$(sed -n "s/^$1#\([0-9]*\)\s*$/\1/p" "$HERE/tests-enabled" 2>/dev/null | tr '\n' ' ')
  for n in $tests; do
    grep -q "^# --- block $n: SKIPPED (test suite)" "$2" \
      || die "lfs/tests-enabled: $1#$n is not a skipped test block (did the book change?)"
  done
  text=$(awk -v skip=" $blocks" -v tests=" $tests" '
    /^# --- block [0-9]+/ { n = $4; sub(/:.*/, "", n); off = index(skip, " " n " ") > 0
                           on = !off && index(tests, " " n " ") > 0
                           if (off) print "# --- block " n ": SKIPPED (lfs/skip)"
                           if (on) { print "# --- block " n ": test suite, run (lfs/tests-enabled)"; next } }
    on && /^# / { sub(/^# /, ""); print; next }
    !off { print }
  ' "$2")
  while IFS=$'\t' read -r sec expr; do
    [ "$sec" = "$1" ] || continue
    new=$(sed -E "$expr" <<<"$text")
    [ "$new" != "$text" ] || die "lfs/edits: '$expr' changes nothing in $1 (did the book change?)"
    text=$new
  done < <(grep -v '^#' "$HERE/edits" 2>/dev/null || true)
  printf '%s\n' "$text"
}
