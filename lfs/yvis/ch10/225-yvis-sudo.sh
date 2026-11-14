# sudo (BLFS 13.1-systemd, postlfs/sudo): administration by the members of
# the wheel group (DECISIONS.md). Without Linux-PAM (not in the base yet),
# sudo checks passwords against /etc/shadow itself; the book's /etc/pam.d/sudo
# is for systems with PAM and is left out.

# --- block 1: the book's fix for OpenSSL 3.x
sed -e 's/\([->.a-zA-Z_]*\)->length/ASN1_STRING_length(\1)/' \
    -i lib/iolog/hostcheck.c

# --- block 2
./configure --prefix=/usr         \
            --libexecdir=/usr/lib \
            --with-secure-path    \
            --with-env-editor     \
            --docdir=/usr/share/doc/sudo-1.9.17p2 \
            --with-passprompt="[sudo] password for %p: " &&
make

# --- block 3
make install

# --- block 4: the wheel group administers (the installer adds the user to it)
cat > /etc/sudoers.d/00-sudo << "EOF2"
Defaults secure_path="/usr/sbin:/usr/bin"
%wheel ALL=(ALL) ALL
EOF2
chmod 440 /etc/sudoers.d/00-sudo
