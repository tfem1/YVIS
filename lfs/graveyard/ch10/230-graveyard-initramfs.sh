# The initramfs: the book boots without one, with the driver of the reader's
# disk built into the kernel. GraveyardOS's kernel has those drivers as modules
# (it boots unknown hardware), so the first thing it runs must load them:
# system/initramfs/.

# --- block 1: the tool, the init script and the live session's files
install -Dm755 /.graveyard/files/system/initramfs/graveyard-mkinitramfs /usr/sbin/graveyard-mkinitramfs
install -Dm755 /.graveyard/files/system/initramfs/init /usr/share/graveyard/initramfs/init
rm -rf /usr/share/graveyard/initramfs/live
cp -R /.graveyard/files/system/initramfs/live /usr/share/graveyard/initramfs/live
chown -R root:root /usr/share/graveyard
find /usr/share/graveyard/initramfs/live -type d -exec chmod 755 {} +
find /usr/share/graveyard/initramfs/live -type f -exec chmod 644 {} +
# the installer, in the live session only (installer/); it asks the live
# system for the graphics card (tools/graveyard-gpu-detect)
live=/usr/share/graveyard/initramfs/live
install -d $live/usr/lib/graveyard/installer $live/usr/bin
cp -R /.graveyard/files/installer/graveyard-installer /.graveyard/files/installer/graveyard_install.py \
  /.graveyard/files/installer/web $live/usr/lib/graveyard/installer/
chmod 755 $live/usr/lib/graveyard/installer/graveyard-installer
find $live/usr/lib/graveyard/installer -type d -exec chmod 755 {} +
ln -sfn ../lib/graveyard/installer/graveyard-installer $live/usr/bin/graveyard-installer
install -m 755 /.graveyard/files/tools/graveyard-gpu-detect $live/usr/bin/graveyard-gpu-detect
# finds the ISO file Ventoy booted with a BIOS (reads low memory)
install -d /usr/lib/graveyard
gcc -O2 -Wall -o /usr/lib/graveyard/vtoy-param /.graveyard/files/system/initramfs/vtoy-param.c
strip --strip-unneeded /usr/lib/graveyard/vtoy-param

# --- block 2: the image for the kernel built in the previous section
graveyard-mkinitramfs "$(cat /.graveyard/kernel-release)"
