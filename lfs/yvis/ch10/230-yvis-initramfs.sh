# The initramfs: the book boots without one, with the driver of the reader's
# disk built into the kernel. YVIS's kernel has those drivers as modules
# (it boots unknown hardware), so the first thing it runs must load them:
# system/initramfs/.

# --- block 1: the tool, the init script and the live session's files
install -Dm755 /.yvis/files/system/initramfs/yvis-mkinitramfs /usr/sbin/yvis-mkinitramfs
install -Dm755 /.yvis/files/system/initramfs/init /usr/share/yvis/initramfs/init
rm -rf /usr/share/yvis/initramfs/live
cp -R /.yvis/files/system/initramfs/live /usr/share/yvis/initramfs/live
chown -R root:root /usr/share/yvis
find /usr/share/yvis/initramfs/live -type d -exec chmod 755 {} +
find /usr/share/yvis/initramfs/live -type f -exec chmod 644 {} +
# finds the ISO file Ventoy booted with a BIOS (reads low memory)
install -d /usr/lib/yvis
gcc -O2 -Wall -o /usr/lib/yvis/vtoy-param /.yvis/files/system/initramfs/vtoy-param.c
strip --strip-unneeded /usr/lib/yvis/vtoy-param

# --- block 2: the image for the kernel built in the previous section
yvis-mkinitramfs "$(cat /.yvis/kernel-release)"
