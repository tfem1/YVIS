# Roadmap

Status legend: ✅ done and tested · 🔨 in progress · ⏳ not started

## v0.1.0 — "it boots"

| # | Milestone | Status |
|---|---|---|
| 1 | Repository structure, architecture document | ✅ |
| 2 | Yone core: format, signatures, resolver, transactions, rollback, CLI | ✅ (local tests) |
| 3 | Yone CI on GitHub Actions | ✅ (fmt, clippy, unit, e2e xz+zstd, static binary) |
| 4 | Measure GitHub runner limits (CPU, RAM, disk, time) | ✅ 4 threads, 1 SBU ≈ 1 min |
| 5 | LFS 13.1-systemd: commands extracted from the book (`lfs/book/`), sources pinned by SHA-256, cross-toolchain (chapters 5–6) in CI | ✅ |
| 6 | LFS base system (chapters 7–8) in CI, generic x86-64 (GMP, Libffi), checked by `lfs/verify.sh` | 🔨 chapter 7 ✅, chapter 8 building |
| 6a | Long critical test suites (Glibc, Binutils, GCC) as a separate verification run, compared with the book's known failures | ⏳ |
| 6b | Security patches from the LFS advisories for 13.1 | ⏳ |
| 6c | Base system rebuilt as `.yon` packages (see "Packaging the base" below) | ⏳ |
| 7 | Kernel build + initramfs | ⏳ |
| 8 | Console ISO (UEFI) booting in QEMU, Yone inside | ⏳ |

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

| # | Milestone | Status |
|---|---|---|
| 9 | Mesa, Wayland, PipeWire, NetworkManager | ⏳ |
| 10 | KDE Plasma (Wayland) + SDDM with YVIS theme | ⏳ |
| 10b | Hyprland + Quickshell + user dotfiles (`yvis-hyprland-config`), selectable in SDDM | 🔨 dotfiles support YVIS (branch `yvis` of tfem1/dotfiles: install via Yone, updates via `yone check-updates`, YVIS themes) |
| 11 | Flatpak + Flathub preconfigured + portals (KDE and Hyprland) | ⏳ |
| 12 | Logo approved and branding integrated (Fastfetch, SDDM, boot, KDE) | 🔨 Fastfetch ASCII supplied by the user |
| 13 | Live ISO ≤ 2 GiB, measured in CI, boot menu: default / NVIDIA / safe graphics | ⏳ |

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
