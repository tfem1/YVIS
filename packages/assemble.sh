#!/usr/bin/env bash
# Set up a system installed from packages: what the book does once for the
# whole machine, not as part of a package.
#
#   sudo packages/assemble.sh <root>
#
#   8.27 Shadow    accounts in /etc/shadow and /etc/gshadow (pwconv, grpconv)
#   8.77 Systemd   services enabled per the presets, including YVIS's
#   9  (YVIS)      no waiting for the network at boot
# The shared library cache and the Info directory are rebuilt by Yone's
# hooks as packages are installed; the machine id is created at first boot.
set -euo pipefail
root=${1:?root}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$root/usr/bin/bash" ] || { echo "$root holds no system" >&2; exit 1; }
chroot "$root" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /usr/bin/bash -e -c '
  pwconv
  grpconv
  systemctl preset-all
  systemctl disable systemd-networkd-wait-online.service
' < /dev/null
echo "assembled $root"
