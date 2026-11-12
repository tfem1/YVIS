# Roadmap

Status legend: ✅ done and tested · 🔨 in progress · ⏳ not started

## v0.1.0 — "it boots"

| # | Milestone | Status |
|---|---|---|
| 1 | Repository structure, architecture document | ✅ |
| 2 | Yone core: format, signatures, resolver, transactions, rollback, CLI | ✅ (local tests) |
| 3 | Yone CI on GitHub Actions | 🔨 workflow written, not yet run |
| 4 | Measure GitHub runner limits (CPU, RAM, disk, time) | 🔨 probe workflow written |
| 5 | Reproducible LFS cross-toolchain (chapters 5–6) in CI | ⏳ |
| 6 | LFS base system (chapters 7–8) packaged as `.yon` | ⏳ |
| 7 | Kernel build + initramfs | ⏳ |
| 8 | Console ISO (UEFI) booting in QEMU, Yone inside | ⏳ |

## v0.2.0 — "desktop"

| # | Milestone | Status |
|---|---|---|
| 9 | Mesa, Wayland, PipeWire, NetworkManager | ⏳ |
| 10 | KDE Plasma (Wayland) + SDDM with YVIS theme | ⏳ |
| 11 | Flatpak + Flathub + portals | ⏳ |
| 12 | Logo approved and branding integrated (Fastfetch, SDDM, boot, KDE) | 🔨 Fastfetch ASCII supplied by the user |
| 13 | Live ISO ≤ 2 GiB, measured in CI | ⏳ |

## v0.3.0 — "installable"

| # | Milestone | Status |
|---|---|---|
| 14 | YVIS Installer (graphical, Minimal/Desktop/Gaming profiles) | ⏳ |
| 15 | Automated install + reboot test in QEMU (UEFI/OVMF) | ⏳ |
| 16 | AMD GPU stack; NVIDIA proprietary option with module signing | ⏳ |

## v0.4.0+ 

Hyprland and COSMIC packages, gaming profile (Steam, Proton, Gamescope,
GameMode, MangoHud), testing/stable channels, Secure Boot, upgrade tests.

## v1.0.0

Only after install/upgrade/rollback have been tested release after release on
real hardware, with the tested hardware list published.
