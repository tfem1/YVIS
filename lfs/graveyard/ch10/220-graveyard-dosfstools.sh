# dosfstools (BLFS 13.1-systemd, postlfs/dosfstools): mkfs.vfat, which the
# installer needs to create the EFI system partition of a UEFI computer.

# --- block 1
./configure --prefix=/usr            \
            --enable-compat-symlinks \
            --mandir=/usr/share/man  \
            --docdir=/usr/share/doc/dosfstools-4.2 &&
make

# --- block 2
make install
