# Roadmap

Orientation (audience, update model, defaults): see DECISIONS.md.

Status legend: ✅ done and tested · 🔨 in progress · ⏳ not started

## v0.1.0 — "it boots"

| # | Milestone | Status |
|---|---|---|
| 1 | Repository structure, architecture document | ✅ |
| 2 | Yone core: format, signatures, resolver, transactions, rollback, CLI | ✅ (local tests) |
| 3 | Yone CI on GitHub Actions | ✅ (fmt, clippy, unit, e2e xz+zstd, static binary) |
| 4 | Measure GitHub runner limits (CPU, RAM, disk, time) | ✅ 4 threads, 1 SBU ≈ 1 min |
| 5 | LFS 13.1-systemd: commands extracted from the book (`lfs/book/`), sources pinned by SHA-256, cross-toolchain (chapters 5–6) in CI | ✅ |
| 6 | LFS base system (chapters 7–8) in CI, generic x86-64 (GMP, Libffi), checked by `lfs/verify.sh` | ✅ run 43360126564, verified by run 43386299956 (434 MiB archive) |
| 6a | Long critical test suites (Glibc, Binutils, GCC) as a separate verification run, compared with the book's known failures | ⏳ |
| 6b | Security patches from the LFS advisories for 13.1 | ⏳ |
| 6c | Base system rebuilt as `.yon` packages (see "Packaging the base" below) | ⏳ |
| 7 | System configuration (chapter 9) and kernel 7.1.8 (chapter 10), `yvis-base` workflow | ✅ run 43388175924 (kernel built in 2 h 02), checks and QEMU boot in run 43425563873 |
| 7a | Initramfs (`system/initramfs/`: installed root or live medium, rescue shell) | ✅ |
| 7b | Kernel build tree for out-of-tree modules (NVIDIA) | ⏳ |
| 8 | Console live ISO, BIOS and UEFI, disc and USB stick, booted in QEMU by `iso/boot-test.sh` | ✅ run 43478718718: 553 MiB, the four boots pass |
| 8a | Yone inside the ISO; first boot on real hardware | ⏳ |
| 8b | Ventoy: the ISO file on a Ventoy stick | 🔨 BIOS ✅ (run 43589068755: Ventoy 1.1.18, found by Ventoy's record on exFAT, every check passes); UEFI: Ventoy's GRUB 2.04 cannot load the kernel ("cannot load image"), under study |
| 8c | Installer (`installer/`): local web page, unattended mode, install test in QEMU (UEFI and BIOS) | 🔨 written and unit-tested; first install test in run 43590896889 |

### Packaging the base (6c)

The chapter 8 system is installed with `make install`: no file belongs to a
package yet. The book's "Creating Package Archives" technique (8.2.2.6) is
what Yone implements, and jhalfs shows how to apply it to the book: every
chapter 8 page becomes a `DESTDIR` install into a staging directory, which
is then packed and installed through the package manager. Plan:

1. Generate one Yone recipe per chapter 8 package from `lfs/book/ch08/`
   (`make install` → `make DESTDIR="$PKGDIR" install`, absolute paths
   prefixed with `$PKGDIR`), reviewed by hand where the book writes to `/`
   directly; configuration files declared as such.
2. Build them inside the chapter 8 system, sign the repository.
3. Assemble the root of the ISO with `yone install --root` into an empty
   directory: the image then holds only packaged files, and this is the
   first real-size test of Yone (ownership, hooks, capabilities, upgrades).
4. Compare that root with the chapter 8 system (same files, same modes).

## v0.2.0 — "desktop"

How: the BLFS book, like the LFS book for the base. `blfs/resolve.py` reads
the pages of the targets (`blfs/targets`), follows their required and
recommended dependencies, and writes the build order (`blfs/order.tsv`);
`blfs/choices` records every dependency YVIS drops or adds, and why. For
BLFS 13.1-systemd, KDE Plasma, SDDM, NetworkManager, PipeWire, Bluetooth,
Xwayland and the portals come to 209 pages, with no cycle left. Next: one
Yone recipe per page (the base's DESTDIR generator), then Hyprland,
Quickshell, Flatpak and kitty as YVIS recipes (not in BLFS).

| # | Milestone | Status |
|---|---|---|
| 9 | Mesa, Wayland, PipeWire, NetworkManager | ⏳ |
| 10 | KDE Plasma (Wayland) + SDDM with YVIS theme | ⏳ |
| 10b | Hyprland + Quickshell + user dotfiles (`yvis-hyprland-config`), selectable in SDDM | 🔨 dotfiles support YVIS (branch `yvis` of tfem1/dotfiles: install via Yone, updates via `yone check-updates`, YVIS themes) |
| 11 | Flatpak + Flathub preconfigured + portals (KDE and Hyprland) | ⏳ |
| 12 | Logo approved and branding integrated (Fastfetch, SDDM, boot, KDE) | 🔨 Fastfetch ASCII supplied by the user |
| 13 | Live ISO (over 2 GiB allowed: hosted on SourceForge), measured in CI, boot menu: default / NVIDIA / safe graphics | ⏳ |

## v0.3.0 — "installable"

| # | Milestone | Status |
|---|---|---|
| 14 | YVIS Installer (graphical): KDE / Hyprland / both, NVIDIA option pre-selected by `yvis-gpu-detect`, Minimal/Desktop/Gaming profiles | ⏳ (GPU detection ✅) |
| 15 | Automated install + reboot test in QEMU (UEFI/OVMF) | ⏳ |
| 16 | AMD GPU stack; NVIDIA open kernel modules (`nvidia.sfs` boot entry) with module signing | ⏳ |

## v0.4.0+ 

COSMIC packages, gaming profile (Steam, Proton, Gamescope,
GameMode, MangoHud), testing/stable channels, Secure Boot, upgrade tests.

## v1.0.0

Only after install/upgrade/rollback have been tested release after release on
real hardware, with the tested hardware list published.
