# 10.3 Linux, the book's steps with GraveyardOS's configuration in place of the
# menu (`make menuconfig` configures a kernel for the machine in front of
# the reader; this one must boot unknown hardware).

# --- block 1
make mrproper

# --- block 2: kernel/base.config + kernel/graveyard.config, completed for this
# compiler, then checked against kernel/required
cp /.graveyard/files/kernel/base.config .config
scripts/kconfig/merge_config.sh -m .config /.graveyard/files/kernel/graveyard.config
make olddefconfig
bash /.graveyard/files/kernel/check-config.sh .config /.graveyard/files/kernel/required

# --- block 3: the same kernel whoever builds it, and whenever
export KBUILD_BUILD_USER=graveyard KBUILD_BUILD_HOST=graveyard
export KBUILD_BUILD_TIMESTAMP="$(date -Ru -r Makefile)"
make

# --- block 4
make INSTALL_MOD_STRIP=1 modules_install

# --- block 5: the book's files in /boot, named after the kernel release
kver=$(make -s kernelrelease)
install -Dm644 arch/x86/boot/bzImage "/boot/vmlinuz-$kver"
install -m644 System.map "/boot/System.map-$kver"
install -m644 .config "/boot/config-$kver"

# --- block 6: where kernel-install and initramfs generators look for the
# image; and what is needed to rebuild this kernel's build tree for
# out-of-tree modules, instead of a link to sources that are removed
install -m644 arch/x86/boot/bzImage "/usr/lib/modules/$kver/vmlinuz"
rm -f "/usr/lib/modules/$kver/build" "/usr/lib/modules/$kver/source"
install -Dm644 -t "/usr/lib/modules/$kver/build" .config Module.symvers System.map
echo "$kver" > /.graveyard/kernel-release
