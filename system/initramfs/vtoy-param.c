/*
 * vtoy-param: print the boot record Ventoy leaves in memory when it boots a
 * "Ventoy compatible" ISO with a BIOS (https://www.ventoy.net/en/
 * doc_compatible_format.html), as 1024 hex digits. Exit 1 if there is none.
 *
 * The record is 512 bytes, 16-byte aligned, in 0x80000-0xa0000, starts with
 * "  www.ventoy.net" and its bytes add up to 0. The kernel shows the RAM of
 * the first megabyte as zeros to read() on /dev/mem; mmap() sees it, which
 * is why this is a program and not a line of the initramfs script (UEFI
 * firmware passes the record in an EFI variable, read there directly).
 * Same search as Ventoy's own vtoydump.
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define START 0x80000
#define LEN 0x20000
#define SIZE 512

int main(void)
{
    static const unsigned char sig[16] = {
        0x20, 0x20, 0x77, 0x77, 0x77, 0x2e, 0x76, 0x65,
        0x6e, 0x74, 0x6f, 0x79, 0x2e, 0x6e, 0x65, 0x74,
    };
    int fd = open("/dev/mem", O_RDONLY);
    if (fd < 0)
        return 2;
    const unsigned char *m = mmap(NULL, LEN, PROT_READ, MAP_PRIVATE, fd, START);
    if (m == MAP_FAILED) {
        close(fd);
        return 2;
    }
    int found = 0;
    for (size_t i = 0; i + SIZE <= LEN && !found; i += 16) {
        if (memcmp(m + i, sig, sizeof sig) != 0)
            continue;
        unsigned char sum = 0;
        for (int k = 0; k < SIZE; k++)
            sum += m[i + k];
        if (sum != 0)
            continue;
        for (int k = 0; k < SIZE; k++)
            printf("%02x", m[i + k]);
        putchar('\n');
        found = 1;
    }
    munmap((void *)m, LEN);
    close(fd);
    return found ? 0 : 1;
}
