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
# the installer, in the live session only (installer/); it asks the live
# system for the graphics card (tools/yvis-gpu-detect)
live=/usr/share/yvis/initramfs/live
install -d $live/usr/lib/yvis/installer $live/usr/bin
cp -R /.yvis/files/installer/yvis-installer /.yvis/files/installer/yvis_install.py \
  /.yvis/files/installer/web $live/usr/lib/yvis/installer/
chmod 755 $live/usr/lib/yvis/installer/yvis-installer
find $live/usr/lib/yvis/installer -type d -exec chmod 755 {} +
ln -sfn ../lib/yvis/installer/yvis-installer $live/usr/bin/yvis-installer
install -m 755 /.yvis/files/tools/yvis-gpu-detect $live/usr/bin/yvis-gpu-detect
# finds the ISO file Ventoy booted with a BIOS (reads low memory)
install -d /usr/lib/yvis
gcc -O2 -Wall -o /usr/lib/yvis/vtoy-param /.yvis/files/system/initramfs/vtoy-param.c
strip --strip-unneeded /usr/lib/yvis/vtoy-param

# --- block 2: the image for the kernel built in the previous section
yvis-mkinitramfs "$(cat /.yvis/kernel-release)"
