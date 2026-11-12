# Roadmap

Status legend: ✅ done and tested · 🔨 in progress · ⏳ not started

## v0.1.0 — "it boots"

| # | Milestone | Status |
|---|---|---|
| 1 | Repository structure, architecture document | ✅ |
| 2 | Yone core: format, signatures, resolver, transactions, rollback, CLI | ✅ (local tests) |
| 3 | Yone CI on GitHub Actions | ✅ (fmt, clippy, unit, e2e xz+zstd, static binary) |
| 4 | Measure GitHub runner limits (CPU, RAM, disk, time) | ✅ 4 threads, 1 SBU ≈ 1 min |
| 5 | LFS 13.1-systemd: commands extracted from the book (`lfs/book/`), sources pinned by SHA-256, cross-toolchain (chapters 5–6) in CI | 🔨 |
| 6 | LFS base system (chapters 7–8) in CI, then packaged as `.yon` | 🔨 |
| 7 | Kernel build + initramfs | ⏳ |
| 8 | Console ISO (UEFI) booting in QEMU, Yone inside | ⏳ |

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
