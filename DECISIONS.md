# Decisions

Choices made by the project owner on 2026-11-13. They orient the roadmap;
changing one is a decision of the same kind, recorded here.

| Topic | Decision |
|---|---|
| Audience | Advanced users (Arch-like), not beginners |
| Updates | Rolling release, two channels: `testing` first, `stable` after a test period |
| Packages | Prebuilt binaries only; recipes written for GraveyardOS or converted from Arch Linux's PKGBUILDs (0BSD), each built, tested and signed by GraveyardOS (2026-11-14); no community recipe repository, ever |
| Catalogue | At least 6000 packages in Yone's repositories, the most used first |
| Yone front end | Command line only |
| CPU baseline | Any 64-bit PC (plain x86-64) |
| Non-free software | Firmware only by default; codecs and NVIDIA are the user's choice |
| Default desktop | KDE Plasma preselected, Hyprland in the list |
| KDE | Plasma on Wayland, the standard desktop (Arch's plasma group), not a minimal one (changed 2026-11-14) |
| Hyprland | The owner's dotfiles (tfem1/dotfiles) as they are, for every user |
| Terminal | kitty on both desktops |
| Browser | Firefox as a Flatpak |
| Language | English and US keyboard by default |
| File system | ext4 by default |
| Disk encryption | Offered by the installer, off by default |
| Secure Boot | Later; first versions require it disabled |
| Administration | sudo |
| Gaming | A profile (Steam, Proton, GameMode, MangoHud) after the desktops work |
| NVIDIA | Open kernel modules (GTX 1650 and later); older cards use nouveau |
| ISO size | One ISO, at most 5 GB (2026-11-14); over 2 GiB it is hosted on SourceForge, GitHub Releases taking files up to 2 GiB |
| Hosting | Packages on GitHub; ISOs on SourceForge (no per-file limit), GitHub Releases for files under 2 GiB; a minimal site of its own on Cloudflare Pages (`site/`, graveyardos.pages.dev) |
| Publication | Public development ISOs as soon as a desktop boots; the console ISO published as a preview at the owner's request (2026-11-14) |
| Name | GraveyardOS (2026-11-14), renamed from YVIS, a name already in use; the logo is a pixel-art tombstone in plain white; the installer and the site are black with a white interface |
| Code name | None |
| License | GNU GPL v3 or later; the name and logo reserved (TRADEMARKS.md); © tfem1 |
| Extras wanted | zram, a welcome screen at first start, the gaming profile |
| Extras declined | Firewall on by default, copy-to-RAM boot entry, `yone rollback`, backup LTS kernel, update robot, btrfs snapshots |

Test hardware: an NVIDIA RTX card (open modules apply).

## What follows from them

- A rolling release with prebuilt binaries means every upstream release of
  about 400 packages has to be rebuilt, tested and published. No update
  robot was chosen, so this is manual work: the number of packages kept
  current is the real limit of the project, and security fixes depend on it.
- ext4 without snapshots and without `yone rollback`: a bad update is
  repaired by hand. The `testing` channel is the only safety net.
- The owner's test machine has an RTX card: the NVIDIA image moves up in
  the order of work, right after the first desktop boots.
