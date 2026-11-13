# Chapter 9 the YVIS way. The book's chapter configures one machine (its
# network card, its keyboard, its name); a distribution ships defaults and
# lets the installer ask. The files are in system/rootfs/, each citing the
# section of the book it comes from.

# --- block 1: the files (owned by root, 644, directories 755)
# (loops, not `find -exec`: find hides the failure of the command it runs)
cd /.yvis/files/system/rootfs
for d in $(find . -type d); do install -d -m 755 "/$d"; done
for f in $(find . -type f); do install -m 644 "$f" "/$f"; done
cd /

# --- block 2: os-release (book 11.1) with this build's identifier
sed -i "s/@BUILD_ID@/$(cat /.yvis/files/build-id)/" /usr/lib/os-release
ln -sfn ../usr/lib/os-release /etc/os-release

# --- block 3: services (book 9.2.1: networkd and resolved are enabled by
# default; not waiting for the network at boot)
systemctl preset-all
systemctl disable systemd-networkd-wait-online.service

# --- block 4: one image, many machines. The identifier written in chapter 8
# (systemd-machine-id-setup) would be shared by every installation: an empty
# file makes systemd create one per machine at its first boot.
: > /etc/machine-id
