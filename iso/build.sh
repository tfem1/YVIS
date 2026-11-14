#!/usr/bin/env bash
# Build the YVIS live ISO from a built system.
#
#   sudo iso/build.sh <output directory>          needs $LFS (default /mnt/lfs)
#
# The medium holds the system as one compressed read-only image
# (/yvis/rootfs.sfs), the kernel, the initramfs and GRUB for BIOS and UEFI.
# Everything that ends up on it comes from the system itself: the boot
# images are made by its own GRUB, run in a chroot. The host only provides
# tools: mksquashfs, xorriso, mtools and dosfstools.
#
# The ISO is marked "Ventoy compatible" (a /ventoy.dat file and the words
# VENTOY COMPATIBLE in the application id): Ventoy then boots it as it is,
# without patching its initramfs, and the initramfs finds the ISO file on
# the stick itself (system/initramfs/init).
#
#   YVIS_ISO_CMDLINE   extra kernel parameters for the live entries
#                      (e.g. "console=ttyS0,115200" for a serial console)
#   YVIS_SFS_LEVEL     zstd level of the system image (default 19)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LFS=${LFS:-/mnt/lfs}
out=${1:?output directory}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for tool in mksquashfs xorriso mkfs.vfat mmd mcopy; do
  command -v "$tool" > /dev/null || { echo "$tool is not installed" >&2; exit 1; }
done
log() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }

kver=${YVIS_KERNEL_RELEASE:-$(cat "$LFS/.yvis/kernel-release")}
version=$(. "$LFS/usr/lib/os-release" && echo "$VERSION_ID")
label=YVIS_$(echo "$version" | tr -c 'A-Za-z0-9\n' '_' | tr a-z A-Z)
iso=$out/yvis-$version-x86_64.iso
tree=$out/tree
grub=$LFS/usr/lib/grub
[ -s "$LFS/boot/vmlinuz-$kver" ] || { echo "no kernel $kver in $LFS/boot" >&2; exit 1; }
[ -s "$LFS/boot/initramfs-$kver.img" ] || { echo "no initramfs for $kver (yvis-mkinitramfs)" >&2; exit 1; }
if mountpoint -q "$LFS/proc"; then echo "$LFS/proc is mounted (lfs/build.sh umount)" >&2; exit 1; fi

rm -rf "$tree"
mkdir -p "$tree"/{yvis,boot/grub/i386-pc,boot/grub/x86_64-efi,EFI/BOOT}

log "system image (zstd, level ${YVIS_SFS_LEVEL:-19})"
mksquashfs "$LFS" "$tree/yvis/rootfs.sfs" -noappend -no-progress \
  -comp zstd -Xcompression-level "${YVIS_SFS_LEVEL:-19}" -b 1M \
  -wildcards -e sources .yvis 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' > "$out/mksquashfs.log"
grep -E 'Filesystem size|inodes' "$out/mksquashfs.log" | sed 's/^/   /'

log "kernel $kver and initramfs"
install -m 644 "$LFS/boot/vmlinuz-$kver" "$tree/boot/vmlinuz"
install -m 644 "$LFS/boot/initramfs-$kver.img" "$tree/boot/initramfs.img"

log "GRUB (the system's own, for BIOS and UEFI)"
stage=$LFS/.yvis/iso
rm -rf "$stage"; mkdir -p "$stage"
# BIOS: the image the firmware loads from the disc (El Torito); GRUB then
# reads its modules and its menu from /boot/grub on the medium.
chroot "$LFS" /usr/bin/grub-mkimage -O i386-pc-eltorito -d /usr/lib/grub/i386-pc \
  -p /boot/grub -o /.yvis/iso/eltorito.img biosdisk iso9660
# UEFI: started from the small FAT partition below, where its first
# configuration file sends it to the medium.
chroot "$LFS" /usr/bin/grub-mkimage -O x86_64-efi -d /usr/lib/grub/x86_64-efi \
  -p /boot/grub -o /.yvis/iso/BOOTX64.EFI \
  part_gpt part_msdos fat iso9660 normal configfile search search_label echo
install -m 644 "$stage/eltorito.img" "$tree/boot/grub/i386-pc/eltorito.img"
install -m 644 "$stage/BOOTX64.EFI" "$tree/EFI/BOOT/BOOTX64.EFI"
for platform in i386-pc x86_64-efi; do
  cp "$grub/$platform"/*.mod "$grub/$platform"/*.lst "$tree/boot/grub/$platform/"
done
cat > "$stage/esp.cfg" <<CFG
search --no-floppy --set=root --label $label
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
CFG
esp=$tree/boot/grub/efi.img
truncate -s "$(( ($(stat -c %s "$stage/BOOTX64.EFI") / 1048576 + 2) ))M" "$esp"
mkfs.vfat -n YVIS_EFI "$esp" > /dev/null
mmd -i "$esp" ::/EFI ::/EFI/BOOT ::/boot ::/boot/grub
mcopy -i "$esp" "$stage/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$esp" "$stage/esp.cfg" ::/boot/grub/grub.cfg
cat > "$tree/ventoy.dat" << DAT
YVIS live medium: Ventoy compatible. Ventoy boots it without hooks; the
initramfs reads Ventoy's boot record to find this ISO file on the stick.
https://www.ventoy.net/en/compatible.html
DAT
sed -e "s/@LABEL@/$label/g" -e "s/@VERSION@/$version/g" -e "s|@CMDLINE@|${YVIS_ISO_CMDLINE:-}|g" \
  -e 's/ *$//' "$HERE/grub.cfg" > "$tree/boot/grub/grub.cfg"

log "ISO (bootable from disc or USB stick, BIOS or UEFI)"
# The options grub-mkrescue passes to xorriso.
xorriso -as mkisofs -graft-points -r -V "$label" \
  -appid "YVIS $version live (VENTOY COMPATIBLE)" -publisher "YVIS" \
  -b boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  --grub2-mbr "$grub/i386-pc/boot_hybrid.img" \
  --efi-boot boot/grub/efi.img -efi-boot-part --efi-boot-image \
  --protective-msdos-label \
  -o "$iso" "$tree" > "$out/xorriso.log" 2>&1 || { cat "$out/xorriso.log"; exit 1; }
rm -rf "$stage"
(cd "$out" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")

size=$(stat -c %s "$iso")
# DECISIONS.md: one ISO of at most 5 GB (over 2 GiB, it goes to SourceForge:
# GitHub Releases refuse larger files).
limit=5000000000
printf '   %s\n   label %s, %d MiB (limit: 5 GB%s)\n' "$iso" "$label" "$((size / 1048576))" \
  "$([ "$size" -le $((2 * 1024 * 1024 * 1024)) ] || echo '; over 2 GiB: SourceForge, not GitHub Releases')"
printf '   system image %d MiB, kernel %d MiB, initramfs %d MiB\n' \
  "$(($(stat -c %s "$tree/yvis/rootfs.sfs") / 1048576))" \
  "$(($(stat -c %s "$tree/boot/vmlinuz") / 1048576))" \
  "$(($(stat -c %s "$tree/boot/initramfs.img") / 1048576))"
[ "$size" -le "$limit" ] || { echo "the ISO is larger than 5 GB (DECISIONS.md)" >&2; exit 1; }
