# Building

## Yone

Requirements: Rust ≥ 1.75 (no crates are downloaded), and at runtime
`openssl`, `xz` and/or `zstd`, `tar`, `curl`.

```sh
cd yone
cargo build --release          # target/release/yone
cargo test                     # unit tests
cargo build && ./tests/e2e.sh  # end-to-end suite (needs a debug build)
YONE_TEST_COMPRESSION=zstd ./tests/e2e.sh
```

The e2e suite builds real signed packages, publishes a signed repository over
`file://` and runs install, upgrade, conflict detection, fault-injected
rollback, removal, verification, tampering and path-escape tests inside a
temporary root. It never touches the host system.

Fault injection (`YONE_TEST_FAIL_AFTER=N`) exists only in debug builds.

## The distribution

The LFS/ISO build runs in GitHub Actions; nothing has to be built locally.
Those workflows are added in milestone 5 (see ROADMAP.md).

## LFS base system

The base system follows LFS 13.1-systemd (pinned in `lfs/config`), using the
book's own commands rather than a rewrite of them:

1. `lfs-book` workflow (manual): `lfs/extract.py` reads the book and writes
   one script per section to `lfs/book/` (test suites, interactive commands
   and placeholders stay visible but commented out, with the reason);
   `lfs/fetch-sources.sh` downloads every source, checks the book's MD5 and
   records SHA-256s. The result is pushed to the branch
   `lfs-book/<version>`, reviewed, then merged.
2. `lfs` workflow (manual): `lfs/build.sh` runs chapters 5-7 (job
   `toolchain`) then chapter 8 (job `system`), each section in the context
   the book expects (user `lfs`, root on the host, or the chroot).

YVIS-specific choices live outside the generated files:

| File | Purpose |
|---|---|
| `lfs/values` | values for the book's placeholders (timezone UTC, paper size A4) |
| `lfs/skip` | sections or single blocks that are never run |
| `lfs/edits` | `sed` edits of a section's commands; an edit that no longer matches stops the build |
| `lfs/tests-enabled` | the test suites that are run (GMP, MPFR, MPC) |
| `lfs/overrides/<section>.sh`, `.post` | replacement commands, or commands run after the book's |

### How a section runs

Like the tools that build packages for a living (jhalfs, Debian's sbuild,
Arch's makechrootpkg), a section runs **detached from the terminal**: in its
own session with no controlling terminal, stdin on `/dev/null`, all output
in `$LFS/.yvis/logs/<section>.log`. The console shows one line per section
and the end of the log if it fails; the logs are uploaded as the
`lfs-system-logs` artifact. A section that does not end within
`YVIS_SECTION_TIMEOUT` (60 minutes) is killed and fails the build.

An unattended build must never wait for a person. The book is written for
a reader at a keyboard and a few of its commands are interactive
(`passwd root`, `tzselect`, `vim -c ':options'`): `lfs/extract.py` comments
them out, and the timeout turns any that slips through into a failure with
its log instead of a job that hangs for hours.

### A system for other machines

The book builds a system for the machine it is built on. YVIS is built in
CI and installed elsewhere, so the cases the book flags for that
(section 8.2.3) are applied through `lfs/edits`: GMP is configured with
`--host=none-linux-gnu` and Libffi with `--with-gcc-arch=x86-64`. Without
them both libraries use the build machine's CPU extensions and die with
"Illegal instruction" on older processors. The baseline is plain x86-64.

### Verification

`sudo lfs/build.sh verify` (last step of the `lfs` workflow, or the
`lfs-verify` workflow on the artifact of an earlier run) checks that every
section of the book was built, then runs `lfs/verify.sh` inside the system:

- the toolchain sanity checks the book asks the reader to compare by eye at
  the end of the GCC section (interpreter, start files, header and linker
  search paths, libc, dynamic linker);
- nothing left of the temporary toolchain;
- no program or library with a missing shared library;
- the main programs start, Python can load its C modules;
- GMP, MPFR, MPC and Libffi contain no instruction beyond the x86-64
  baseline;
- owners and modes that must survive the archive handed between CI jobs
  (stored with numeric ids, xattrs and ACLs).

Not covered yet: the long test suites the book calls critical (Glibc,
Binutils, GCC). They take hours and have known failures to compare against
the book's list, so they belong to a separate verification run (ROADMAP).

### YVIS base: chapters 9 and 10

The book's chapters 9 and 10 configure and boot the reader's machine (its
network card, its disk, a kernel for its hardware). YVIS's own sections, in
`lfs/yvis/` and run by `lfs/build.sh` like the book's, do it for a system
installed elsewhere. The `yvis-base` workflow starts from the `lfs-system`
artifact of an `lfs` run:

- **System configuration** (`system/rootfs/`, each file citing its section
  of the book): wired network by DHCP on any Ethernet card, hostname,
  locale and console defaults the installer will change, the book's
  `/etc/profile`, `inputrc` and `shells` verbatim, `os-release` for YVIS,
  service presets, an empty `machine-id` so that every installation gets
  its own.
- **Kernel** (`kernel/`): Linux 7.1.8 configured from `kernel/base.config`
  (Arch Linux's configuration for the same version, fetched by the
  `kernel-config` workflow and pinned by SHA-256) plus `kernel/yvis.config`
  (six differences). `kernel/required` lists the options the book says the
  system needs to boot (10.3.1) and the ones YVIS needs; the build stops if
  the final `.config` lacks one. About two hours on a CI runner
  (`lfs/timeouts`).
- **Checks**: `lfs/verify-yvis.sh` from inside the system, then
  `kernel/boot-test.sh` boots a copy of it in QEMU on a plain emulated
  x86-64 CPU and requires systemd to be `running` with no failed unit,
  modules to load, and the network to get its address by DHCP.

Left to the installer, because they depend on the target disk: `/etc/fstab`
(10.2) and GRUB (10.4).

### Initramfs and live ISO

The book boots without an initramfs, the reader's disk driver built into
the kernel. YVIS's drivers are modules, so the kernel first runs
`system/initramfs/init`: udev loads the drivers of the storage present,
then the script mounts either the installed root (`root=UUID=…`) or the
live medium (`yvis.live=<label>`: `/yvis/rootfs.sfs` read-only under a
writable layer kept in memory), and hands over to systemd. If something is
missing it says what, lists the storage it found and opens a shell.
`yvis-mkinitramfs` builds the image from the installed system's own
programs and refuses to write one in which udev cannot load modules.

The `yvis-iso` workflow builds the ISO from a `yvis-base` artifact
(`iso/build.sh`): the system as a zstd squashfs, the kernel, the initramfs,
and GRUB for BIOS and UEFI made by the system's own GRUB. The host only
lends tools (mksquashfs, xorriso, mtools). `iso/boot-test.sh` then boots
the ISO itself, through its menu, as a disc and as a USB stick with both
firmwares; the test unit is handed to the virtual machine as systemd
credentials, so the ISO that is tested is the one that is published.

Not covered: real hardware. No firmware is installed yet, so on a real PC
Wi-Fi and some graphics cards will not work; the console uses the
firmware's display.

The `lfs-debug` workflow reruns one section on a saved `$LFS` the old way
(on sudo's terminal) under `strace` and reports what stopped; it exists to
confirm the cause of a hang, not to build.

Local checks (root, no network):

```bash
python3 -m unittest discover -s lfs/tests
sudo YVIS_LFS_NO_APT=1 bash lfs/tests/build-runner.sh
sh tools/tests/gpu-detect.sh
```

## The site

One static page (`site/`), published by Cloudflare Pages at every
push to `main` (no build step): https://yvis.pages.dev

Cloudflare settings (Workers & Pages > yvis > Settings > Build):
framework preset None, build command empty, build output directory `site`.

`yvis-icon.svg` is a copy of `branding/yvis-icon.svg`: Cloudflare publishes
this directory only.
