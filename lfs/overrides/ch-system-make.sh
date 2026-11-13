# 8.70 Make, the book's commands under a watchdog. Twice on GitHub Actions
# (runs 43311808077, 43335433619) `make` stopped forever right after
# "make[3]: Leaving directory '.../lib'", even with -j1. If a step stalls,
# dump every process (procps is not installed yet: read /proc) and fail.
# The runner froze both times (it ignored cancellation), so memory is capped
# too: a runaway allocation then fails here instead of taking the machine.
yvis_ps() {
  for d in /proc/[0-9]*; do
    [ -r "$d/stat" ] || continue
    read -r pid comm state ppid _ < "$d/stat" 2>/dev/null || continue
    printf '%6s %6s %s %-22s %s\n' "$pid" "$ppid" "$state" \
      "$(cat "$d/wchan" 2>/dev/null)" "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | cut -c1-150)"
  done
}
yvis_watch() { # seconds command...
  local limit=$1; shift
  ( ulimit -v 4194304; exec "$@" ) & local job=$! t=0
  while kill -0 "$job" 2>/dev/null; do
    sleep 5; t=$((t + 5))
    if [ "$t" -ge "$limit" ]; then
      echo "!! '$*' stalled after ${limit}s; processes (pid ppid state wchan cmd):" >&2
      yvis_ps >&2
      for d in /proc/[0-9]*; do
        case $(cat "$d/comm" 2>/dev/null) in make|sh|bash)
          echo "--- $d $(cat "$d/comm"): $(grep -E '^(State|SigBlk|SigIgn|SigPnd|ShdPnd)' "$d/status" | tr '\n' ' ')" >&2
          ls -l "$d/fd" 2>/dev/null | sed 's/^/      /' >&2;;
        esac
      done
      kill -KILL "$job" 2>/dev/null
      return 1
    fi
  done
  wait "$job"
}
./configure --prefix=/usr
yvis_watch 300 make
yvis_watch 300 make install
