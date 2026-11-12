# 7.15: only the in-chroot part. Unmounting and the backup tarball are host
# steps; lfs/build.sh does them (umount, pack).
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name \*.la -delete
rm -rf /tools
